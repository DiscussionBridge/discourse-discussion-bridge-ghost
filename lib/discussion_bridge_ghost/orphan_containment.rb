# frozen_string_literal: true

module DiscussionBridgeGhost
  # Operator-only Ghost containment. This never claims, acknowledges, or writes
  # receiver work: an unrecorded native identity cannot receive R7 withdrawal work.
  class OrphanContainment < Publication
    def self.plan(**target)
      build(**target).plan
    end

    def self.call(native_revision:, confirm:, **target)
      build(**target).call(native_revision: native_revision, confirm: confirm)
    end

    def self.build(kind:, connection_id:, topic_id:, admin_url:, admin_key:, native_id:, canonical_url:)
      unless admin_key.is_a?(String) && !admin_key.empty?
        raise Error.new("ghost_containment_admin_key_required")
      end
      connection, descriptor = ConnectionCheck.receiver(connection_id)
      ghost = GhostSite.new(admin_url, admin_key)
      new(connection, descriptor, ghost, topic_id, kind, native_id: native_id, canonical_url: canonical_url)
    end
    private_class_method :build

    def initialize(connection, descriptor, ghost, topic_id, kind, native_id:, canonical_url:)
      super(connection, descriptor, ghost, topic_id, nil, kind)
      unless native_id.is_a?(String) && native_id.match?(/\A[0-9a-f]{24}\z/) &&
             canonical_url.is_a?(String) && !canonical_url.empty?
        raise Error.new("ghost_containment_target_required")
      end
      @native_id = native_id
      @canonical_url = canonical_url
    end

    def plan
      with_target do |article, proof, status|
        result(article, proof, status, "planned")
      end
    end

    def call(native_revision:, confirm:)
      unless confirm == "revert-to-draft:#{@native_id}" &&
             native_revision.is_a?(String) && !native_revision.empty?
        raise Error.new("ghost_containment_confirmation_required")
      end
      with_target do |article, proof, status|
        unless article.fetch("updated_at") == native_revision
          raise Error.new("ghost_containment_revision_changed")
        end
        if article.fetch("status") == "draft"
          next result(article, proof, status, "already_draft")
        end

        @ghost.withdraw(@kind, article)
        draft = @ghost.article(@kind, @native_id)
        assert_draft!(draft, proof)
        result(draft, proof, public_absence!, "contained")
      end
    end

    private

    def with_target
      with_lock do
        @connection.with_lock do
          @descriptor = receiver("V4-01") { ::DiscussionBridge::CmsAuthorityStore.new(@connection).descriptor.body }
          unless @descriptor.fetch("profile") == "ghost" &&
                 @descriptor.dig("native_capabilities", "publication_kind") == "dynamic"
            raise Error.new("ghost_dynamic_connection_required")
          end
          @state = PluginStore.get(STORE, @key)
          validate_journal!
          mapping_row = retained_mapping!
          validate_revocation!(mapping_row)
          Publication.validate_destination!(@connection, @descriptor, @ghost)

          article = @ghost.article(@kind, @native_id)
          assert_owned!(article)
          proof = retained_dispatch!(mapping_row, article)
          status = if article.fetch("status") == "published" && article.fetch("url") == @canonical_url
            prove_public_target!(proof)
          else
            assert_draft!(article, proof)
            public_absence!
          end
          yield(article, proof, status)
        end
      end
    rescue ActiveRecord::LockWaitTimeout
      raise Error.new("ghost_publication_busy"), cause: nil
    end

    def validate_journal!
      unless @state.is_a?(Hash) && @state["kind"] == @kind && @state["native_id"] == @native_id &&
             @state["url"] == @canonical_url && @state["mapping_id"].is_a?(String) &&
             @state["owner"].is_a?(String) && @state["operation"].is_a?(Hash)
        raise Error.new("ghost_containment_journal_unavailable")
      end
    end

    def retained_mapping!
      @mapping = mapping
      unless @mapping.fetch("mapping_state") == "attention" && !@mapping["destination_native_id"]
        raise Error.new("ghost_containment_receiver_state_changed")
      end
      row = DiscussionBridgeCmsMapping.find_by(content_connection_id: @connection.id, mapping_id: @mapping.fetch("mapping_id"))
      record = row&.content_binding&.bridge_record
      unless record && (record.topic_id.nil? || record.topic_id == @topic_id) &&
             !row.work_items.where.not(state: DiscussionBridgeCmsWork::TERMINAL_STATES).exists?
        raise Error.new("ghost_containment_receiver_state_changed")
      end
      row
    end

    def validate_revocation!(mapping_row)
      stream = DiscussionBridgeCmsSourceStream.find_by(
        content_connection_id: @connection.id, publication_lane: @descriptor.fetch("publication_lane"),
      )
      intent = stream && DiscussionBridgeCmsSourceIntent.find_by(
        cms_source_stream_id: stream.id, source_id: mapping_row.source_id, topic_id: @topic_id,
      )
      unless intent&.state == "revoked"
        raise Error.new("ghost_containment_receiver_state_changed")
      end

      topic = Topic.unscoped.lock("FOR UPDATE NOWAIT").find_by(id: @topic_id)
      Post.unscoped.lock("FOR UPDATE NOWAIT").find_by(topic_id: @topic_id, post_number: 1) if topic
      if (topic && mapping_row.content_binding.bridge_record.topic_id != topic.id) ||
         ::DiscussionBridge::CmsConfiguration.eligible?(topic, @descriptor.fetch("policy"))
        raise Error.new("ghost_containment_receiver_state_changed")
      end
    end

    def retained_dispatch!(mapping_row, article)
      operation = @state.fetch("operation")
      [operation, operation["prior"]].each do |candidate|
        next unless candidate.is_a?(Hash) && candidate["publish_started"] && candidate["html"].is_a?(String)
        work_id = recorded_work_id(candidate)
        next unless work_id
        work = mapping_row.work_items.find_by(work_id: work_id)
        next unless work && %w[cancelled superseded].include?(work.state) &&
          work.action == "publish_revision" && work.source_revision == candidate["revision"]

        source = work.source_snapshot || {}
        source_url = candidate["source_url"] || source["topic_url"]
        title = candidate["title"] || source["title"]
        next unless source_url.is_a?(String) && source_url == source["topic_url"] &&
          title.is_a?(String) && title == source["title"] && title == article["title"]
        next unless managed_article?(candidate.fetch("html"), work.source_revision) &&
          managed_article?(article.fetch("html"), work.source_revision)

        digest = fragment_digest(candidate.fetch("html"), source_url: source_url)
        next unless matching_fragment?(article.fetch("html"), digest, source_url)

        return { work_id: work_id, revision: work.source_revision, title: title, source_url: source_url, digest: digest }
      end
      raise Error.new("ghost_containment_native_proof_missing")
    end

    def managed_article?(html, revision)
      fragment = Nokogiri::HTML5.fragment(html)
      nodes = fragment.children.reject do |node|
        (node.text? && node.text.strip.empty?) ||
          (node.comment? && ["kg-card-begin: html", "kg-card-end: html"].include?(node.content.strip))
      end
      return false unless nodes.one? && nodes.first.element?

      section = nodes.first
      section.name == "section" && section["data-db-owner"] == @state.fetch("owner") &&
        section["data-db-resource"] == @mapping.fetch("resource_id") &&
        section["data-db-native"] == @native_id && section["data-db-revision"] == revision
    end

    def prove_public_target!(proof)
      status, body = @ghost.public_article(@canonical_url)
      unless status == 200 && matching_fragment?(body, proof.fetch(:digest), proof.fetch(:source_url))
        raise Error.new("ghost_containment_native_proof_missing", status: status)
      end
      status
    end

    def assert_draft!(article, proof)
      assert_owned!(article)
      uuid = article["uuid"]
      origin = @descriptor.fetch("destination_origin").delete_suffix("/")
      unless article["status"] == "draft" && uuid.is_a?(String) &&
             uuid.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/) &&
             article["url"] == "#{origin}/p/#{uuid}/" && article["title"] == proof.fetch(:title) &&
             managed_article?(article.fetch("html"), proof.fetch(:revision)) &&
             matching_fragment?(article.fetch("html"), proof.fetch(:digest), proof.fetch(:source_url))
        raise Error.new("ghost_containment_native_proof_missing")
      end
    end

    def result(article, proof, public_status, outcome)
      {
        outcome: outcome, connection_id: @connection.public_id, mapping_id: @mapping.fetch("mapping_id"),
        receiver_work_id: proof.fetch(:work_id), topic_id: @topic_id, native_id: @native_id, canonical_url: @canonical_url,
        native_revision: article.fetch("updated_at"), native_status: article.fetch("status"), public_status: public_status,
        receiver_mapping_state: @mapping.fetch("mapping_state"),
      }
    end
  end
end
