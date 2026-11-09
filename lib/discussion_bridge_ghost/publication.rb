# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"
require_relative "publication_attention"

module DiscussionBridgeGhost
  class Publication
    include PublicationAttention
    # Retain the original namespace so an existing post keeps its ownership record.
    STORE = "discussionbridge-ghost-r7-post"
    RECOVERY_HISTORY = "#{STORE}-recovery-history"

    def self.validate_policy!(descriptor)
      policy = descriptor.fetch("policy")
      unless descriptor.fetch("directions").include?("from_discourse") && policy.fetch("enabled") &&
             policy.fetch("presentation_mode") == "simple" && policy.fetch("author_ids").empty? &&
             policy.fetch("taxonomy_ids").empty? && descriptor.dig("native_capabilities", "complete_content_supported")
        raise Error.new("ghost_simple_publish_policy_required")
      end
    end

    def self.validate_destination!(connection, descriptor, ghost)
      site_url = ghost.site.fetch("url")
      ConnectionCheck.check_site!(connection, descriptor, site_url)
      raise Error.new("ghost_default_root_routing_required") unless ["/", ""].include?(URI.parse(site_url).path)
    end

    def self.call(kind:, connection_id:, topic_id:, admin_url:, admin_key:, url_label: nil, supervised: false, withdraw_only: false)
      connection, descriptor = ConnectionCheck.receiver(connection_id)
      ghost = GhostSite.new(admin_url, admin_key)
      new(connection, descriptor, ghost, topic_id, url_label, kind, supervised: supervised, withdraw_only: withdraw_only).call
    end

    def self.inspect_attention(kind:, connection_id:, topic_id:, admin_url:, admin_key:, inspection_id:, supervised: false)
      connection, descriptor = ConnectionCheck.receiver(connection_id)
      ghost = GhostSite.new(admin_url, admin_key)
      new(connection, descriptor, ghost, topic_id, nil, kind, supervised: supervised).inspect_attention(inspection_id)
    end

    def initialize(connection, descriptor, ghost, topic_id, url_label, kind, supervised: false, withdraw_only: false)
      raise Error.new("ghost_kind_invalid") unless GhostSite::COLLECTIONS.key?(kind)
      @connection = connection
      @descriptor = descriptor
      @ghost = ghost
      @topic_id = ::DiscussionBridge::CmsSourceLifecycle.native_id!(topic_id)
      @source_id = "topic:#{@topic_id}"
      @kind = kind
      @url_label = url_label
      @supervised = supervised
      @withdraw_only = withdraw_only
      @key = "#{connection.public_id}:#{@topic_id}"
      @mapping_service = ::DiscussionBridge::CmsMappingService.new(connection)
      @work = ::DiscussionBridge::CmsWorkCoordinator.new(connection)
    end

    def call
      Publication.validate_policy!(@descriptor)
      Publication.validate_destination!(@connection, @descriptor, @ghost)

      with_lock do
        @state = PluginStore.get(STORE, @key)
        check_supervised_scope!(allow_owned_withdrawal: @withdraw_only)
        if @state && @state.fetch("kind", "post") != @kind
          raise Error.new("native_ownership_conflict")
        end
        refresh = ::DiscussionBridge::CmsSourceLifecycle.refresh(@connection, @topic_id)
        intent = refresh.source_intent
        raise Error.new("receiver_#{refresh.error_code}") if refresh.error_code

        if intent&.state == "active"
          raise Error.new("ghost_supervised_scope_denied") if @withdraw_only

          @action = "publish_revision"
          @source = intent.source_revisions.find_by!(source_revision: intent.current_source_revision).source_metadata
          @revision = @source.fetch("source_revision")
          @state ||= initialize_ownership
        elsif intent&.state == "revoked" && @state&.fetch("mapping_id", nil)
          @action = "withdraw"
        else
          raise Error.new("receiver_source_ineligible")
        end
        check_supervised_scope!
        @mapping = mapping
        if @withdraw_only && @state.dig("supervised_publication", "resource_id") != @mapping["resource_id"]
          raise Error.new("ghost_supervised_scope_denied")
        end
        if withdrawing? && !@mapping["destination_native_id"]
          # R7 has no withdraw work for an unacknowledged native identity.
          # Keep the journal and the receiver's attention state for reconciliation.
          operation = @state["operation"] || {}
          if operation["publish_started"] || operation.dig("prior", "publish_started")
            raise Error.new("ghost_unacknowledged_publication")
          end
          raise Error.new("receiver_source_ineligible")
        end
        if settled?
          verify_settled!
          next result
        end

        operation = current_operation
        @lease = lease_for(operation)
        replay_pending_failure!(operation)
        begin
          reconcile_pending!(operation)
          if withdrawing?
            prepare_withdrawal(operation)
          else
            prepare_native(operation)
          end
          acknowledge(operation)
        rescue Error => error
          report_failure(operation, error)
          raise
        end
        result
      end
    end

    private

    def withdrawing?
      @action == "withdraw"
    end

    def check_supervised_scope!(allow_owned_withdrawal: @withdraw_only && withdrawing?)
      return unless @supervised

      scope = SupervisedScope::CURRENT
      category_id = Topic.where(id: @topic_id).pick(:category_id)
      return if scope.outbound?(@connection.public_id, category_id)
      return if allow_owned_withdrawal && scope.owned_withdrawal?(@connection.public_id, @topic_id, @state)

      raise Error.new("ghost_supervised_scope_denied")
    end

    def settled?
      if withdrawing?
        @mapping.fetch("mapping_state") == "withdrawn"
      else
        @mapping.fetch("mapping_state") == "active" && @mapping["publicly_verified_source_revision"] == @revision
      end
    end

    def with_lock
      id = Digest::SHA256.digest("#{STORE}:#{@key}").unpack1("q>")
      ActiveRecord::Base.connection_pool.with_connection do |database|
        if database.transaction_open? || !database.select_value("SELECT pg_try_advisory_lock(#{id})")
          raise Error.new("ghost_publication_busy")
        end
        begin
          yield
        ensure
          database.select_value("SELECT pg_advisory_unlock(#{id})")
        end
      end
    end

    def initialize_ownership
      slug = [@url_label, @source.fetch("title")].compact.join(" ").parameterize
      unless slug.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) && slug.bytesize <= 191
        raise Error.new("ghost_initial_slug_invalid")
      end
      origin = @descriptor.fetch("destination_origin").delete_suffix("/")
      {
        "owner" => SecureRandom.uuid, "kind" => @kind, "slug" => slug, "url" => "#{origin}/#{slug}/",
        "external_id" => "ghost-#{@kind}:#{Digest::SHA256.hexdigest(@key)}",
      }
    end

    def save!
      raise Error.new("ghost_publication_storage_failed") unless PluginStore.set(STORE, @key, @state)
    end

    def mapping
      if (id = @state["mapping_id"])
        item = receiver("V4-11") { @mapping_service.show(id).body }
      else
        raise Error.new("native_ownership_conflict") if withdrawing?
        item = prepare_mapping
      end

      unless item.fetch("source_id") == @source_id && item.fetch("canonical_url") == @state.fetch("url") &&
             item.fetch("external_id") == @state.fetch("external_id") && item.fetch("presentation_mode") == "simple" &&
             (!item["destination_native_id"] || item["destination_native_id"] == @state["native_id"])
        raise Error.new("native_ownership_conflict")
      end
      unless id
        @state["mapping_id"] = item.fetch("mapping_id")
        @state.delete("reservation")
        save!
      end
      item
    end

    def prepare_mapping
      policy_revision = @descriptor.fetch("policy").fetch("policy_revision")
      if (previous = @state["reservation"])
        begin
          # R7 consults an accepted receipt before checking source and policy
          # revisions. Replay the original input even when a newer intent exists.
          return receiver("V4-09") { @mapping_service.prepare(previous).body }
        rescue Error => error
          stale_source = error.code == "V4-09 revision_conflict" && previous.fetch("source_revision") != @revision
          stale_policy = error.code == "V4-09 policy_changed" && previous.fetch("policy_revision") != policy_revision
          raise unless stale_source || stale_policy
        end
      end

      input = {
        "mutation_id" => SecureRandom.uuid, "source_id" => @source_id,
        "source_revision" => @revision, "policy_revision" => policy_revision,
        "external_id" => @state.fetch("external_id"), "canonical_url" => @state.fetch("url"),
      }
      @state["reservation"] = input
      save!
      receiver("V4-09") { @mapping_service.prepare(input).body }
    end

    def current_operation
      mapping = DiscussionBridgeCmsMapping.find_by!(
        content_connection_id: @connection.id, mapping_id: @mapping.fetch("mapping_id"),
      )
      @current_work = mapping.work_items.where(
        action: @action, source_revision: @revision,
        policy_revision: @descriptor.fetch("policy").fetch("policy_revision"),
      ).order(created_at: :desc, id: :desc).first
      raise Error.new("receiver_work_unavailable", status: 204) unless @current_work

      previous = @state["operation"]
      if previous
        prior_id = recorded_work_id(previous)
        if prior_id == @current_work.work_id || (prior_id.nil? &&
            previous.fetch("action", "publish_revision") == @action && previous["revision"] == @revision)
          previous["work_id"] = @current_work.work_id
          return previous
        end
      end

      @state["operation"] = {
        "action" => @action, "revision" => @revision, "work_id" => @current_work.work_id,
        "restore" => native_baseline&.fetch("status", nil) == "draft",
      }
      if previous
        @state.fetch("operation")["prior"] = previous["prior"] || previous
      end
      save!
      @state.fetch("operation")
    end

    def recorded_work_id(operation)
      return operation["work_id"] if operation["work_id"]
      return unless operation["lease"]

      ::DiscussionBridge::CmsReceiptCipher.decrypt(operation.fetch("lease")).fetch("work").fetch("work_id")
    end

    def reconcile_pending!(operation)
      return unless (previous = operation["prior"])

      prior_id = recorded_work_id(previous)
      prior = @current_work.cms_mapping.work_items.find_by(work_id: prior_id) if prior_id
      if prior_id && (!prior || !DiscussionBridgeCmsWork::TERMINAL_STATES.include?(prior.state))
        raise Error.new("ghost_prior_publication_unresolved")
      end
      reconcile_prior!(previous, prior)
      retain_recovery_history!(previous, prior_id) if prior_id && @current_work.retry_of_work_id
      operation["restore"] = native_baseline&.fetch("status", nil) == "draft"
      operation.delete("prior")
      save!
    end

    def retain_recovery_history!(operation, work_id)
      key = "#{@key}:#{work_id}"
      existing = PluginStore.get(RECOVERY_HISTORY, key)
      return if existing == operation

      if existing || !PluginStore.set(RECOVERY_HISTORY, key, operation)
        raise Error.new("ghost_publication_storage_failed")
      end
    end

    def reconcile_prior!(operation, work)
      return unless operation["publish_started"] || operation["withdraw_started"]

      article = @ghost.article(@kind, @state.fetch("native_id"))
      assert_owned!(article)
      if operation["publish_started"]
        source = work&.source_snapshot
        source_url = operation["source_url"] || source&.fetch("topic_url")
        title = operation["title"] || source&.fetch("title")
        if source_url && title && operation["html"]
          expected = fragment_digest(operation.fetch("html"), source_url: source_url)
          if article["status"] == "published" && article["url"] == @state.fetch("url") &&
             article["title"] == title && matching_fragment?(article.fetch("html"), expected, source_url)
            remember_reconciled_dispatch!(operation, work, article, expected)
            remember_native!(article, source_url: source_url, digest: expected, revision: operation.fetch("revision"))
            return
          end
        end
      elsif article["status"] == "draft"
        assert_withdrawn!(article)
        baseline = native_baseline
        remember_native!(article, source_url: baseline.fetch("source_url"), digest: baseline.fetch("digest"),
                         revision: baseline.fetch("revision"))
        return
      end

      # The earlier request may have failed before its native write. Prove the
      # old baseline as well; an ownership marker alone does not prove content.
      if native_baseline&.fetch("status", nil) == "draft"
        assert_withdrawn!(article)
      else
        assert_baseline!(article)
      end
    end

    def matching_fragment?(html, digest, source_url)
      fragment_digest(html, source_url: source_url) == digest
    rescue Error => error
      raise unless error.code == "public_verification_failed"

      false
    end

    def lease_for(operation)
      if (encrypted = operation["lease"])
        lease = ::DiscussionBridge::CmsReceiptCipher.decrypt(encrypted)
        if DiscussionBridgeCmsWork::LIVE_STATES.include?(@current_work.state) &&
           lease.fetch("work").fetch("work_id") == @current_work.work_id &&
           @current_work.lease_generation == lease.fetch("lease_generation") &&
           Time.iso8601(lease.fetch("expires_at")) > Time.now
          return lease
        end
        operation.delete("lease")
        operation.delete("claim_id")
      end

      id = operation["claim_id"] ||= SecureRandom.uuid
      save!
      response = claim_current_work(id)
      if response.status == 204
        operation.delete("claim_id")
        save!
        raise Error.new("receiver_work_unavailable", status: 204)
      end
      lease = response.body
      work = lease.fetch("work")
      unless work.fetch("work_id") == @current_work.work_id && work.fetch("action") == @action &&
             work.fetch("source_revision") == @revision
        raise Error.new("receiver_unexpected_work")
      end
      operation["lease"] = ::DiscussionBridge::CmsReceiptCipher.encrypt(lease)
      save!
      lease
    end

    def claim_current_work(mutation_id)
      if @current_work.retry_of_work_id
        # The in-process connector reads the immutable positive recovery
        # handoff for this successor directly. The receiver still fences claim.
        recovery = DiscussionBridgeCmsAttentionRecovery.find_by!(
          content_connection_id: @connection.id, cms_mapping_id: @current_work.cms_mapping_id,
          successor_work_id: @current_work.id,
        )
        receiver("V4-36") do
          ::DiscussionBridge::CmsAttentionRecovery.new(@connection).claim(
            recovery.recovery_id, { "mutation_id" => mutation_id, "work_id" => @current_work.work_id },
          )
        end
      else
        receiver("V4-13") do
          # Constrain selection in the receiver transaction and bind the
          # idempotency receipt to that same ordinary Work.
          @work.claim(
            { "mutation_id" => mutation_id, "mapping_id" => @mapping.fetch("mapping_id") },
            expected_work_id: @current_work.work_id,
            receipt_path: @current_work.work_id,
          )
        end
      end
    end

    def authority
      @lease.fetch("work").slice("work_id", "source_revision", "policy_revision")
        .merge(@lease.slice("lease_token", "lease_generation"))
    end

    def refresh_lease!
      check_supervised_scope!
      payload = { "mutation_id" => SecureRandom.uuid, "authority" => authority }
      @lease = receiver("V4-15") { @work.renew(authority.fetch("work_id"), payload).body }
      @state.fetch("operation")["lease"] = ::DiscussionBridge::CmsReceiptCipher.encrypt(@lease)
      save!
    end

    def article_bytes
      source_id = @source.fetch("source_id")
      store = ::DiscussionBridge::CmsSourceStore.new(@connection)
      bytes = +"".b
      loop do
        chunk = receiver("V4-07") { store.content(source_id, @revision, "offset" => bytes.bytesize).body }
        bytes << Base64.strict_decode64(chunk.fetch("content_base64"))
        break if chunk.fetch("next_offset").nil?
      end
      bytes.force_encoding(Encoding::UTF_8)
      unless bytes.valid_encoding? && bytes.bytesize == @source.fetch("content_bytes") &&
             Digest::SHA256.hexdigest(bytes) == @source.fetch("content_sha256")
        raise Error.new("content_hash_mismatch")
      end
      bytes
    end

    def native_article
      slug = @state.fetch("slug")
      if (id = @state["native_id"])
        article = @ghost.article(@kind, id)
      elsif @state["draft_dispatch_started"]
        article = @ghost.article_by_slug(@kind, slug)
      else
        status, = @ghost.public_article(@state.fetch("url"))
        if status == 200 || GhostSite::COLLECTIONS.keys.any? { |kind| @ghost.article_by_slug(kind, slug) }
          raise Error.new("native_ownership_conflict")
        end
        refresh_lease!
        @state["draft_dispatch_started"] = true
        save!
        marker = %(<section data-db-owner="#{@state.fetch('owner')}"></section>)
        article = @ghost.create_draft(@kind, slug: slug, title: @source.fetch("title"), marker: marker)
      end

      assert_owned!(article)
      unless @state["native_id"]
        raise Error.new("native_ownership_conflict") unless article.fetch("status") == "draft"
        @state["native_id"] = article.fetch("id")
        save!
      end
      article
    end

    def assert_owned!(article)
      unless article && article["id"].is_a?(String) && article["id"].match?(/\A[0-9a-f]{24}\z/) &&
             (!@state["native_id"] || @state["native_id"] == article["id"]) &&
             article["slug"] == @state.fetch("slug") && article["html"].is_a?(String) &&
             Nokogiri::HTML5.fragment(article["html"]).css("section[data-db-owner]")
               .count { |element| element["data-db-owner"] == @state.fetch("owner") } == 1
        raise Error.new("native_ownership_conflict")
      end
    end

    def prepare_native(operation)
      if operation["html"] && !current_page?(operation.fetch("html"), @state.fetch("native_id"))
        # Never dispatch a journaled legacy representation that saved replies.
        # An earlier native write still needs its original digest for recovery.
        raise Error.new("native_restore_required") if operation["publish_started"]
        operation.delete("html")
      end
      source_html = article_bytes unless operation["html"]
      article = native_article
      unless operation["html"]
        operation["html"] = PostPresentation.render(
          @source, source_html, owner: @state.fetch("owner"), resource: @mapping.fetch("resource_id"), native_id: article.fetch("id"),
        )
        operation["source_url"] = @source.fetch("topic_url")
        operation["title"] = @source.fetch("title")
        save!
      end
      raise Error.new("public_verification_failed") unless current_page?(operation.fetch("html"), article.fetch("id"))
      expected = fragment_digest(operation.fetch("html"))
      if target_article?(article, expected)
        if operation["restore"] && !operation["publish_started"]
          raise Error.new("native_ownership_conflict")
        end
      else
        if operation["restore"]
          assert_withdrawn!(article)
          public_absence!
        else
          assert_baseline!(article)
        end
        publish_native!(operation, article, expected)
        return
      end
      if (scope = scoped_dispatch_identity)
        reconcile_scoped_publication!(operation, expected, scope)
      else
        remember_publication!(operation, article, expected)
      end
    end

    def current_page?(html, native_id)
      PostPresentation.current_page?(
        html, owner: @state.fetch("owner"), resource: @mapping.fetch("resource_id"),
        native_id: native_id, revision: @revision,
      )
    end

    def publish_native!(operation, article, expected)
      # Write the intent before dispatch, even if the lock transaction below
      # later rolls back. A replacement must still reconcile the native result.
      refresh_lease!
      operation["publish_started"] = true
      scope = scoped_dispatch_identity
      if scope
        operation["supervised_dispatch"] = scope
      else
        operation.delete("supervised_dispatch")
      end
      save!
      if @mapping["destination_native_id"] && !scope
        apply_publication!(operation, article, expected)
      else
        # Keep the source in scope while recording the supervised publication.
        # For a first write, keep receiver invalidation fenced through synchronization.
        with_publication_fence do
          refresh_lease!
          apply_publication!(operation, article, expected, scope: scope)
          synchronize(operation)
        end
      end
    end

    def with_publication_fence(allow_missing_source: false)
      # NOWAIT keeps a concurrent edit from becoming a lock-order deadlock.
      @connection.with_lock do
        topic = Topic.unscoped.lock("FOR UPDATE NOWAIT").find_by(id: @topic_id)
        post = Post.unscoped.lock("FOR UPDATE NOWAIT").find_by(topic_id: @topic_id, post_number: 1) if topic
        raise Error.new("source_ineligible") unless allow_missing_source || (topic && post)

        yield(topic)
      end
    rescue ActiveRecord::LockWaitTimeout
      raise Error.new("ghost_publication_busy"), cause: nil
    end

    def scoped_dispatch_identity
      category_id = SupervisedScope::CURRENT.category("outbound") if @supervised
      return unless category_id

      @state.slice("mapping_id", "native_id", "owner", "url", "external_id").merge(
        "connection_id" => @connection.public_id, "topic_id" => @topic_id.to_i,
        "category_id" => category_id, "resource_id" => @mapping.fetch("resource_id"),
      )
    end

    def reconcile_scoped_publication!(operation, expected, scope)
      unless operation["publish_started"] && operation["supervised_dispatch"] == scope
        raise Error.new("native_restore_required")
      end

      with_publication_fence do
        refresh_lease!
        article = @ghost.article(@kind, @state.fetch("native_id"))
        assert_owned!(article)
        raise Error.new("public_verification_failed") unless target_article?(article, expected)

        remember_scoped_publication!(article, expected, scope)
        remember_publication!(operation, article, expected)
        synchronize(operation)
      end
    end

    def remember_reconciled_dispatch!(operation, work, article, digest)
      recorded = work&.action == "publish_revision" && work.source_revision == operation.fetch("revision")
      if (scope = scoped_dispatch_identity)
        if recorded && operation["supervised_dispatch"] == scope
          remember_scoped_publication!(article, digest, scope, revision: work.source_revision)
        elsif @withdraw_only
          raise Error.new("native_restore_required")
        end
      end
      if recorded && !@mapping["destination_native_id"]
        # Keep only the exact dispatch that produced the current native baseline.
        @state["unrecorded_dispatch"] = operation.slice("publish_started", "revision", "source_url", "title")
          .merge("work_id" => work.work_id, "digest" => digest)
      end
    end

    def apply_publication!(operation, article, expected, scope: nil)
      operation["write_dispatched"] = true
      @ghost.publish(@kind, article, title: @source.fetch("title"), html: operation.fetch("html"))
      article = @ghost.article(@kind, article.fetch("id"))
      assert_owned!(article)
      raise Error.new("public_verification_failed") unless target_article?(article, expected)

      remember_scoped_publication!(article, expected, scope) if scope
      remember_publication!(operation, article, expected)
    end

    def remember_scoped_publication!(article, digest, scope, revision: @revision)
      @state["supervised_publication"] = scope.merge(
        "digest" => digest, "revision" => revision, "native_revision" => article.fetch("updated_at"),
      )
    end

    def remember_publication!(operation, article, digest)
      operation["native_revision"] = article.fetch("updated_at")
      operation["digest"] = digest
      remember_native!(article, source_url: @source.fetch("topic_url"), digest: digest, revision: @revision)
    end

    def remember_native!(article, source_url:, digest:, revision:)
      @state["native_baseline"] = {
        "status" => article.fetch("status"), "title" => article.fetch("title"), "source_url" => source_url,
        "digest" => digest, "revision" => revision, "native_revision" => article.fetch("updated_at"),
      }
      save!
    end

    def prepare_withdrawal(operation)
      return apply_withdrawal!(operation) unless @withdraw_only

      with_publication_fence(allow_missing_source: true) do |topic|
        configuration = receiver("V4-01") { ::DiscussionBridge::CmsConfiguration.current!(@connection) }
        policy = configuration.fetch("policy")
        if policy.fetch("enabled") && ::DiscussionBridge::CmsConfiguration.eligible?(topic, policy)
          raise Error.new("ghost_supervised_scope_denied")
        end
        apply_withdrawal!(operation)
        synchronize(operation)
      end
    end

    def apply_withdrawal!(operation)
      article = @ghost.article(@kind, @state.fetch("native_id"))
      assert_owned!(article)
      if article["status"] == "draft"
        unless operation["withdraw_started"] || native_baseline&.fetch("status", nil) == "draft"
          raise Error.new("native_ownership_conflict")
        end
      else
        assert_baseline!(article)
        if @withdraw_only && article["updated_at"] != @state.dig("supervised_publication", "native_revision")
          raise Error.new("native_ownership_conflict")
        end
        refresh_lease!
        operation["withdraw_started"] = true
        save!
        @ghost.withdraw(@kind, article)
        article = @ghost.article(@kind, article.fetch("id"))
        assert_owned!(article)
      end
      assert_withdrawn!(article)
      operation["native_revision"] = article.fetch("updated_at")
      baseline = native_baseline
      remember_native!(article, source_url: baseline.fetch("source_url"), digest: baseline.fetch("digest"),
                       revision: baseline.fetch("revision"))
    end

    def assert_withdrawn!(article)
      uuid = article["uuid"]
      origin = @descriptor.fetch("destination_origin").delete_suffix("/")
      unless article["status"] == "draft" && uuid.is_a?(String) &&
             uuid.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/) &&
             article["url"] == "#{origin}/p/#{uuid}/" && retained_article?(article)
        raise Error.new("native_ownership_conflict")
      end
    end

    def retained_article?(article)
      baseline = native_baseline
      baseline && article["title"] == baseline.fetch("title") &&
        fragment_digest(article.fetch("html"), source_url: baseline.fetch("source_url")) == baseline.fetch("digest")
    end

    def native_baseline
      @state["native_baseline"] || @state["verified"]&.merge(
        "status" => @mapping["mapping_state"] == "withdrawn" ? "draft" : "published",
      )
    end

    def assert_baseline!(article)
      if native_baseline
        valid = article["status"] == "published" && article["url"] == @state.fetch("url") && retained_article?(article)
      else
        marker = %(<section data-db-owner="#{@state.fetch('owner')}"></section>)
        html = Nokogiri::HTML5.fragment(article.fetch("html"))
        html.xpath("./comment()").each do |comment|
          comment.remove if ["kg-card-begin: html", "kg-card-end: html"].include?(comment.content.strip)
        end
        valid = article["status"] == "draft" && html.to_html.strip == marker
      end
      raise Error.new("native_ownership_conflict") unless valid
    end

    def target_article?(article, digest)
      article["status"] == "published" && article["url"] == @state.fetch("url") && article["title"] == @source.fetch("title") &&
        fragment_digest(article.fetch("html")) == digest
    end

    def fragment_digest(html, source_url: @source.fetch("topic_url"))
      PostPresentation.digest(html, owner: @state.fetch("owner"), source_url: source_url, ghost_url: @state.fetch("url"))
    end

    def public_proof!(digest)
      status, body = @ghost.public_article(@state.fetch("url"))
      unless status == 200 && fragment_digest(body) == digest
        raise Error.new("public_verification_failed", status: status)
      end
    end

    def public_absence!
      status, = @ghost.public_article(@state.fetch("url"))
      raise Error.new("public_verification_failed", status: status) unless [404, 410].include?(status)
      status
    end

    def synchronize(operation)
      work_id = authority.fetch("work_id")
      status = receiver("V4-14") { @work.query(work_id).body.fetch("work").fetch("state") }
      if status == "leased"
        receipt = ownership_receipt
        operation["receipt"] = receipt
        save!
        send_ack(work_id, "synchronized", "native_result", native_result(operation, receipt))
      elsif status != "synchronized"
        raise Error.new("receiver_unexpected_work_state")
      end
    end

    def acknowledge(operation)
      synchronize(operation)
      verification = public_verification(operation)
      @mapping = send_ack(authority.fetch("work_id"), "verified", "verification", verification).fetch("mapping")
    end

    def report_failure(operation, error)
      code = failure_code(error)
      return unless code

      # If a dispatch failed before readback, native state may have changed.
      # Keep that possibility visible and reconcile the journal before retry.
      generation = authority.fetch("lease_generation").to_s
      failures = operation["failures"] ||= {}
      request = if failures[generation]
        ::DiscussionBridge::CmsReceiptCipher.decrypt(failures.fetch(generation))
      else
        payload = {
          "mutation_id" => SecureRandom.uuid, "authority" => authority, "code" => code,
          "native_change_applied" => !!(operation["write_dispatched"] || operation["withdraw_started"] ||
            @state["draft_dispatch_started"] && !@mapping["destination_native_id"]),
          "safe_detail" => nil, "retry_after_seconds" => nil,
        }
        failures[generation] = ::DiscussionBridge::CmsReceiptCipher.encrypt(payload)
        save!
        payload
      end
      submit_failure(request)
    rescue Error => report_error
      # Stale authority must not turn into an unscoped failure report.
      Rails.logger.warn("DiscussionBridge Ghost work failure report code=#{report_error.code}")
    end

    def replay_pending_failure!(operation)
      request = operation.dig("failures", authority.fetch("lease_generation").to_s)
      return unless request

      submit_failure(::DiscussionBridge::CmsReceiptCipher.decrypt(request))
      raise Error.new("receiver_work_unavailable", status: 204)
    end

    def submit_failure(request)
      receiver("V4-17") { @work.fail(authority.fetch("work_id"), request) }
    end

    def failure_code(error)
      case error.code
      when "native_ownership_conflict", "native_restore_required", "public_verification_failed",
           "content_hash_mismatch", "source_ineligible"
        error.code
      when "ghost_prior_publication_unresolved"
        "native_restore_required"
      when "ghost_response_invalid", "ghost_response_too_large"
        "public_verification_failed"
      when "ghost_transport_failed"
        "transport_timeout"
      when "ghost_http_error"
        if error.status == 429
          "rate_limited"
        elsif error.status && error.status >= 500
          "native_service_unavailable"
        else
          "native_ownership_conflict"
        end
      end
    end

    def ownership_receipt
      baseline = native_baseline
      source_url = withdrawing? ? baseline.fetch("source_url") : @source.fetch("topic_url")
      receipt = {
        "schema_version" => "db-native-ownership-1",
        "forum_origin" => ::DiscussionBridge::CmsProtocol.url_authority(source_url).comparison_origin,
        "connection_id" => @connection.public_id, "mapping_id" => @mapping.fetch("mapping_id"),
        "resource_id" => @mapping.fetch("resource_id"), "source_id" => @source_id,
        "external_id" => @state.fetch("external_id"), "native_id" => @state.fetch("native_id"),
        "canonical_url" => @state.fetch("url"), "source_revision" => withdrawing? ? baseline.fetch("revision") : @revision,
        "last_lease_generation" => authority.fetch("lease_generation"), "move_id" => nil, "proof_nonce" => nil,
      }
      ::DiscussionBridge::CmsProtocol.validate!("NativeOwnershipReceipt", receipt)
      receipt
    end

    def native_result(operation, receipt)
      result = receipt.slice("native_id", "external_id", "canonical_url").merge(
        "kind" => @action, "native_revision" => operation.fetch("native_revision"),
        "ownership_receipt_sha256" => receipt_sha256(receipt),
      )
      result["representation"] = representation unless withdrawing?
      result
    end

    def receipt_sha256(receipt)
      hash = Digest::SHA256.new
      receipt.each_value do |value|
        if value.nil?
          hash.update([0xffffffff].pack("N"))
        else
          bytes = value.to_s.b
          hash.update([bytes.bytesize].pack("N")).update(bytes)
        end
      end
      hash.hexdigest
    end

    def representation
      { "kind" => "full", "source_content_sha256" => @source.fetch("content_sha256") }
    end

    def public_verification(operation)
      identity = { "native_id" => @state.fetch("native_id"), "url" => @state.fetch("url") }
      if withdrawing?
        status = public_absence!
        return identity.merge("kind" => "absent", "http_status" => status, "checked_at" => Time.now.utc.iso8601(3))
      end

      digest = operation.fetch("digest")
      public_proof!(digest)
      @state["verified"] = {
        "title" => @source.fetch("title"), "source_url" => @source.fetch("topic_url"),
        "digest" => digest, "revision" => @revision, "receipt" => operation.fetch("receipt"),
      }
      save!
      identity.merge(
        "kind" => "published", "source_revision" => @revision, "source_content_sha256" => @source.fetch("content_sha256"),
        "native_publication_sha256" => digest, "verification_profile" => "ghost-r7-#{@kind}-html-card-1",
        "checked_at" => Time.now.utc.iso8601(3), "representation" => representation,
      )
    end

    def send_ack(work_id, stage, field, value)
      requests = @state.fetch("operation")["acks"] ||= {}
      key = "#{authority.fetch('lease_generation')}:#{stage}"
      input = if requests[key]
        ::DiscussionBridge::CmsReceiptCipher.decrypt(requests.fetch(key))
      else
        tree = { "mutation_id" => SecureRandom.uuid, "authority" => authority, "stage" => stage, field => value }
        requests[key] = ::DiscussionBridge::CmsReceiptCipher.encrypt(tree)
        save!
        tree
      end
      receiver("V4-16") { @work.acknowledge(work_id, input).body }
    end

    def verify_settled!
      article = @ghost.article(@kind, @state.fetch("native_id"))
      assert_owned!(article)
      if withdrawing?
        assert_withdrawn!(article)
        return public_absence!
      end

      verified = @state.fetch("verified")
      raise Error.new("native_ownership_conflict") unless verified.fetch("revision") == @revision
      digest = verified.fetch("digest")
      raise Error.new("native_ownership_conflict") unless target_article?(article, digest)
      public_proof!(digest)
    end

    def receiver(route)
      yield
    rescue ::DiscussionBridge::CmsProtocol::Error => error
      status = ::DiscussionBridge::CmsProtocol::ERRORS.fetch(error.code).fetch("http")
      raise Error.new("#{route} #{error.code}", status: status), cause: nil
    end

    def result
      @mapping.slice("mapping_id", "resource_id", "canonical_url", "destination_native_id", "publicly_verified_source_revision", "mapping_state")
    end
  end

  class PublishPost < Publication
    def self.call(**options)
      super(**options, kind: "post")
    end
  end

  class PublishPage < Publication
    def self.call(**options)
      super(**options, kind: "page")
    end
  end
end
