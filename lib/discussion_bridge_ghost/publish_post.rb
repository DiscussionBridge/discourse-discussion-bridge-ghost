# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"

module DiscussionBridgeGhost
  class PublishPost
    STORE = "discussionbridge-ghost-r7-post"


    def self.call(connection_id:, topic_id:, admin_url:, admin_key:, url_label: nil)
      connection, descriptor = ConnectionCheck.receiver(connection_id)
      ghost = GhostSite.new(admin_url, admin_key)
      new(connection, descriptor, ghost, topic_id, url_label).call
    end

    def initialize(connection, descriptor, ghost, topic_id, url_label)
      @connection = connection
      @descriptor = descriptor
      @ghost = ghost
      @topic_id = ::DiscussionBridge::CmsSourceLifecycle.native_id!(topic_id)
      @url_label = url_label
      @key = "#{connection.public_id}:#{@topic_id}"
      @mapping_service = ::DiscussionBridge::CmsMappingService.new(connection)
      @work = ::DiscussionBridge::CmsWorkCoordinator.new(connection)
    end

    def call
      policy = @descriptor.fetch("policy")
      unless @descriptor.fetch("directions").include?("from_discourse") && policy.fetch("enabled") &&
             policy.fetch("presentation_mode") == "simple" && policy.fetch("author_ids").empty? &&
             policy.fetch("taxonomy_ids").empty? && @descriptor.dig("native_capabilities", "complete_content_supported")
        raise Error.new("ghost_simple_publish_policy_required")
      end
      site_url = @ghost.site.fetch("url")
      ConnectionCheck.check_site!(@connection, @descriptor, site_url)
      raise Error.new("ghost_default_root_routing_required") unless ["", "/"].include?(URI.parse(site_url).path)

      with_lock do
        refresh = ::DiscussionBridge::CmsSourceLifecycle.refresh(@connection, @topic_id)
        intent = refresh.source_intent
        raise Error.new("receiver_#{refresh.error_code || 'source_ineligible'}") unless !refresh.error_code && intent&.state == "active"

        @source = intent.source_revisions.find_by!(source_revision: intent.current_source_revision).source_metadata
        @revision = @source.fetch("source_revision")
        @state = PluginStore.get(STORE, @key) || initialize_ownership
        @mapping = mapping
        if @mapping["publicly_verified_source_revision"] == @revision
          verify_settled!
          next result
        end

        operation = current_operation
        @lease = lease_for(operation)
        prepare_native(operation)
        acknowledge(operation)
        result
      end
    end

    private

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
        "owner" => SecureRandom.uuid, "slug" => slug, "url" => "#{origin}/#{slug}/",
        "external_id" => "ghost-post:#{Digest::SHA256.hexdigest(@key)}",
      }
    end

    def save!
      PluginStore.set(STORE, @key, @state)
    end

    def mapping
      if (id = @state["mapping_id"])
        item = receiver("V4-11") { @mapping_service.show(id).body }
      else
        input = @state["reservation"] ||= {
          "mutation_id" => SecureRandom.uuid, "source_id" => @source.fetch("source_id"),
          "source_revision" => @revision, "policy_revision" => @descriptor.fetch("policy").fetch("policy_revision"),
          "external_id" => @state.fetch("external_id"), "canonical_url" => @state.fetch("url"),
        }
        save!
        item = receiver("V4-09") { @mapping_service.prepare(input).body }
        @state["mapping_id"] = item.fetch("mapping_id")
        @state.delete("reservation")
        save!
      end

      unless item.fetch("source_id") == @source.fetch("source_id") && item.fetch("canonical_url") == @state.fetch("url") &&
             item.fetch("external_id") == @state.fetch("external_id") && item.fetch("presentation_mode") == "simple" &&
             (!item["destination_native_id"] || item["destination_native_id"] == @state["native_id"])
        raise Error.new("native_ownership_conflict")
      end
      item
    end

    def current_operation
      previous = @state["operation"]
      return previous if previous && previous.fetch("revision") == @revision
      if previous && previous.fetch("revision") != @mapping["publicly_verified_source_revision"]
        raise Error.new("ghost_prior_publication_unresolved")
      end

      @state["operation"] = { "revision" => @revision }
      save!
      @state.fetch("operation")
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
      unless work.fetch("action") == "publish_revision" && work.fetch("source_revision") == @revision
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

    def native_post
      slug = @state.fetch("slug")
      if (id = @state["native_id"])
        post = @ghost.post(id)
      elsif @state["draft_dispatch_started"]
        post = @ghost.post_by_slug(slug)
      else
        status, = @ghost.public_article(@state.fetch("url"))
        if status == 200 || @ghost.post_by_slug(slug) || @ghost.page_at_slug?(slug)
          raise Error.new("native_ownership_conflict")
        end
        refresh_lease!
        @state["draft_dispatch_started"] = true
        save!
        marker = %(<section data-db-owner="#{@state.fetch('owner')}"></section>)
        post = @ghost.create_draft(slug: slug, title: @source.fetch("title"), marker: marker)
      end

      assert_owned!(post)
      unless @state["native_id"]
        raise Error.new("native_ownership_conflict") unless post.fetch("status") == "draft"
        @state["native_id"] = post.fetch("id")
        save!
      end
      post
    end

    def assert_owned!(post)
      unless post && post["id"].is_a?(String) && post["id"].match?(/\A[0-9a-f]{24}\z/) &&
             (!@state["native_id"] || @state["native_id"] == post["id"]) &&
             post["slug"] == @state.fetch("slug") && post["html"].is_a?(String) &&
             Nokogiri::HTML5.fragment(post["html"]).css("section[data-db-owner]")
               .count { |element| element["data-db-owner"] == @state.fetch("owner") } == 1
        raise Error.new("native_ownership_conflict")
      end
    end

    def prepare_native(operation)
      article = article_bytes unless operation["html"]
      post = native_post
      unless operation["html"]
        operation["html"] = PostPresentation.render(
          @source, article, owner: @state.fetch("owner"), resource: @mapping.fetch("resource_id"), native_id: post.fetch("id"),
        )
        save!
      end
      expected = fragment_digest(operation.fetch("html"))
      unless target_post?(post, expected)
        assert_baseline!(post)
        refresh_lease!
        @ghost.publish(post, title: @source.fetch("title"), html: operation.fetch("html"))
        post = @ghost.post(post.fetch("id"))
        assert_owned!(post)
        raise Error.new("public_verification_failed") unless target_post?(post, expected)
      end
      operation["native_revision"] = post.fetch("updated_at")
      operation["digest"] = expected
      save!
    end

    def assert_baseline!(post)
      if (baseline = @state["verified"])
        valid = post["status"] == "published" && post["url"] == @state.fetch("url") &&
          post["title"] == baseline.fetch("title") &&
          fragment_digest(post.fetch("html"), source_url: baseline.fetch("source_url")) == baseline.fetch("digest")
      else
        marker = %(<section data-db-owner="#{@state.fetch('owner')}"></section>)
        html = Nokogiri::HTML5.fragment(post.fetch("html"))
        html.xpath("./comment()").each do |comment|
          comment.remove if ["kg-card-begin: html", "kg-card-end: html"].include?(comment.content.strip)
        end
        valid = post["status"] == "draft" && html.to_html.strip == marker
      end
      raise Error.new("native_ownership_conflict") unless valid
    end

    def target_post?(post, digest)
      post["status"] == "published" && post["url"] == @state.fetch("url") && post["title"] == @source.fetch("title") &&
        fragment_digest(post.fetch("html")) == digest
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

    def acknowledge(operation)
      work_id = authority.fetch("work_id")
      lease_generation = authority.fetch("lease_generation")
      representation = { "kind" => "full", "source_content_sha256" => @source.fetch("content_sha256") }
      receipt = {
        "schema_version" => "db-native-ownership-1",
        "forum_origin" => ::DiscussionBridge::CmsProtocol.url_authority(@source.fetch("topic_url")).comparison_origin,
        "connection_id" => @connection.public_id, "mapping_id" => @mapping.fetch("mapping_id"),
        "resource_id" => @mapping.fetch("resource_id"), "source_id" => @source.fetch("source_id"),
        "external_id" => @state.fetch("external_id"), "native_id" => @state.fetch("native_id"),
        "canonical_url" => @state.fetch("url"), "source_revision" => @revision,
        "last_lease_generation" => lease_generation, "move_id" => nil, "proof_nonce" => nil,
      }
      ::DiscussionBridge::CmsProtocol.validate!("NativeOwnershipReceipt", receipt)
      operation["receipt"] = receipt
      save!

      status = receiver("V4-14") { @work.query(work_id).body.fetch("work").fetch("state") }
      if status == "leased"
        hash = Digest::SHA256.new
        receipt.each_value do |value|
          if value.nil?
            hash.update([0xffffffff].pack("N"))
          else
            bytes = value.to_s.b
            hash.update([bytes.bytesize].pack("N")).update(bytes)
          end
        end
        native = receipt.slice("native_id", "external_id", "canonical_url").merge(
          "kind" => "publish_revision", "native_revision" => operation.fetch("native_revision"),
          "ownership_receipt_sha256" => hash.hexdigest, "representation" => representation,
        )
        send_ack(work_id, "synchronized", "native_result", native)
      elsif status != "synchronized"
        raise Error.new("receiver_unexpected_work_state")
      end

      digest = operation.fetch("digest")
      public_proof!(digest)
      verification = receipt.slice("native_id", "source_revision").merge(
        "kind" => "published", "url" => @state.fetch("url"), "source_content_sha256" => @source.fetch("content_sha256"),
        "native_publication_sha256" => digest, "verification_profile" => PostPresentation::PROFILE,
        "checked_at" => Time.now.utc.iso8601(3), "representation" => representation,
      )
      @state["verified"] = {
        "title" => @source.fetch("title"), "source_url" => @source.fetch("topic_url"),
        "digest" => digest, "revision" => @revision,
      }
      save!
      @mapping = send_ack(work_id, "verified", "verification", verification).fetch("mapping")
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
      verified = @state.fetch("verified")
      raise Error.new("native_ownership_conflict") unless verified.fetch("revision") == @revision
      post = @ghost.post(@state.fetch("native_id"))
      assert_owned!(post)
      digest = verified.fetch("digest")
      raise Error.new("native_ownership_conflict") unless target_post?(post, digest)
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
end
