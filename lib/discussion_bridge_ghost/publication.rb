# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"

module DiscussionBridgeGhost
  class Publication
    # Retain the original namespace so an existing post keeps its ownership record.
    STORE = "discussionbridge-ghost-r7-post"

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

    def self.call(kind:, connection_id:, topic_id:, admin_url:, admin_key:, url_label: nil)
      connection, descriptor = ConnectionCheck.receiver(connection_id)
      ghost = GhostSite.new(admin_url, admin_key)
      new(connection, descriptor, ghost, topic_id, url_label, kind).call
    end

    def initialize(connection, descriptor, ghost, topic_id, url_label, kind)
      raise Error.new("ghost_kind_invalid") unless GhostSite::COLLECTIONS.key?(kind)
      @connection = connection
      @descriptor = descriptor
      @ghost = ghost
      @topic_id = ::DiscussionBridge::CmsSourceLifecycle.native_id!(topic_id)
      @source_id = "topic:#{@topic_id}"
      @kind = kind
      @url_label = url_label
      @key = "#{connection.public_id}:#{@topic_id}"
      @mapping_service = ::DiscussionBridge::CmsMappingService.new(connection)
      @work = ::DiscussionBridge::CmsWorkCoordinator.new(connection)
    end

    def call
      Publication.validate_policy!(@descriptor)
      Publication.validate_destination!(@connection, @descriptor, @ghost)

      with_lock do
        @state = PluginStore.get(STORE, @key)
        if @state && @state.fetch("kind", "post") != @kind
          raise Error.new("native_ownership_conflict")
        end
        refresh = ::DiscussionBridge::CmsSourceLifecycle.refresh(@connection, @topic_id)
        intent = refresh.source_intent
        raise Error.new("receiver_#{refresh.error_code}") if refresh.error_code

        if intent&.state == "active"
          @action = "publish_revision"
          @source = intent.source_revisions.find_by!(source_revision: intent.current_source_revision).source_metadata
          @revision = @source.fetch("source_revision")
          @state ||= initialize_ownership
        elsif intent&.state == "revoked" && @state&.fetch("verified", nil)
          @action = "withdraw"
        else
          raise Error.new("receiver_source_ineligible")
        end
        @mapping = mapping
        if settled?
          verify_settled!
          next result
        end

        operation = current_operation
        @lease = lease_for(operation)
        if withdrawing?
          prepare_withdrawal(operation)
        else
          prepare_native(operation)
        end
        acknowledge(operation)
        result
      end
    end

    private

    def withdrawing?
      @action == "withdraw"
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
      PluginStore.set(STORE, @key, @state)
    end

    def mapping
      if (id = @state["mapping_id"])
        item = receiver("V4-11") { @mapping_service.show(id).body }
      else
        raise Error.new("native_ownership_conflict") if withdrawing?
        input = @state["reservation"] ||= {
          "mutation_id" => SecureRandom.uuid, "source_id" => @source_id,
          "source_revision" => @revision, "policy_revision" => @descriptor.fetch("policy").fetch("policy_revision"),
          "external_id" => @state.fetch("external_id"), "canonical_url" => @state.fetch("url"),
        }
        save!
        item = receiver("V4-09") { @mapping_service.prepare(input).body }
        @state["mapping_id"] = item.fetch("mapping_id")
        @state.delete("reservation")
        save!
      end

      unless item.fetch("source_id") == @source_id && item.fetch("canonical_url") == @state.fetch("url") &&
             item.fetch("external_id") == @state.fetch("external_id") && item.fetch("presentation_mode") == "simple" &&
             (!item["destination_native_id"] || item["destination_native_id"] == @state["native_id"])
        raise Error.new("native_ownership_conflict")
      end
      item
    end

    def current_operation
      previous = @state["operation"]
      previous_action = previous&.fetch("action", "publish_revision")
      return previous if previous_action == @action && previous.fetch("revision") == @revision
      if previous && !completed_operation?(previous)
        raise Error.new("ghost_prior_publication_unresolved")
      end

      @state["operation"] = { "action" => @action, "revision" => @revision, "restore" => previous_action == "withdraw" }
      save!
      @state.fetch("operation")
    end

    def completed_operation?(operation)
      return false unless operation["lease"]
      prior = ::DiscussionBridge::CmsReceiptCipher.decrypt(operation.fetch("lease"))
      work_id = prior.fetch("work").fetch("work_id")
      receiver("V4-14") { @work.query(work_id).body.fetch("work").fetch("state") == "verified" }
    end

    def lease_for(operation)
      if (encrypted = operation["lease"])
        lease = ::DiscussionBridge::CmsReceiptCipher.decrypt(encrypted)
        return lease if Time.iso8601(lease.fetch("expires_at")) > Time.now
        operation.delete("lease")
        operation.delete("claim_id")
      end

      id = operation["claim_id"] ||= SecureRandom.uuid
      save!
      response = receiver("V4-13") { @work.claim({ "mutation_id" => id, "mapping_id" => @mapping.fetch("mapping_id") }) }
      if response.status == 204
        operation.delete("claim_id")
        save!
        raise Error.new("receiver_work_unavailable", status: 204)
      end
      lease = response.body
      work = lease.fetch("work")
      unless work.fetch("action") == @action && work.fetch("source_revision") == @revision
        raise Error.new("receiver_unexpected_work")
      end
      operation["lease"] = ::DiscussionBridge::CmsReceiptCipher.encrypt(lease)
      save!
      lease
    end

    def authority
      @lease.fetch("work").slice("work_id", "source_revision", "policy_revision")
        .merge(@lease.slice("lease_token", "lease_generation"))
    end

    def refresh_lease!
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
      source_html = article_bytes unless operation["html"]
      article = native_article
      unless operation["html"]
        operation["html"] = PostPresentation.render(
          @source, source_html, owner: @state.fetch("owner"), resource: @mapping.fetch("resource_id"), native_id: article.fetch("id"),
        )
        save!
      end
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
        refresh_lease!
        operation["publish_started"] = true
        save!
        @ghost.publish(@kind, article, title: @source.fetch("title"), html: operation.fetch("html"))
        article = @ghost.article(@kind, article.fetch("id"))
        assert_owned!(article)
        raise Error.new("public_verification_failed") unless target_article?(article, expected)
      end
      operation["native_revision"] = article.fetch("updated_at")
      operation["digest"] = expected
      save!
    end

    def prepare_withdrawal(operation)
      article = @ghost.article(@kind, @state.fetch("native_id"))
      assert_owned!(article)
      if article["status"] == "draft"
        raise Error.new("native_ownership_conflict") unless operation["withdraw_started"]
      else
        assert_baseline!(article)
        refresh_lease!
        operation["withdraw_started"] = true
        save!
        @ghost.withdraw(@kind, article)
        article = @ghost.article(@kind, article.fetch("id"))
        assert_owned!(article)
      end
      assert_withdrawn!(article)
      operation["native_revision"] = article.fetch("updated_at")
      save!
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
      baseline = @state.fetch("verified")
      article["title"] == baseline.fetch("title") &&
        fragment_digest(article.fetch("html"), source_url: baseline.fetch("source_url")) == baseline.fetch("digest")
    end

    def assert_baseline!(article)
      if @state["verified"]
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

    def acknowledge(operation)
      work_id = authority.fetch("work_id")
      receipt = ownership_receipt
      operation["receipt"] = receipt
      save!

      status = receiver("V4-14") { @work.query(work_id).body.fetch("work").fetch("state") }
      if status == "leased"
        send_ack(work_id, "synchronized", "native_result", native_result(operation, receipt))
      elsif status != "synchronized"
        raise Error.new("receiver_unexpected_work_state")
      end

      verification = public_verification(operation)
      @mapping = send_ack(work_id, "verified", "verification", verification).fetch("mapping")
    end

    def ownership_receipt
      baseline = @state["verified"]
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
      hash = Digest::SHA256.new
      receipt.each_value do |value|
        if value.nil?
          hash.update([0xffffffff].pack("N"))
        else
          bytes = value.to_s.b
          hash.update([bytes.bytesize].pack("N")).update(bytes)
        end
      end
      result = receipt.slice("native_id", "external_id", "canonical_url").merge(
        "kind" => @action, "native_revision" => operation.fetch("native_revision"),
        "ownership_receipt_sha256" => hash.hexdigest,
      )
      result["representation"] = representation unless withdrawing?
      result
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
