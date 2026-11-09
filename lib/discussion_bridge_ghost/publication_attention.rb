# frozen_string_literal: true

module DiscussionBridgeGhost
  # Collects native facts for an administrator's receiver-issued Check.
  # Receiver classifies them; the check does not lease, publish, or repair.
  module PublicationAttention
    def inspect_attention(inspection_id)
      Publication.validate_policy!(@descriptor)
      Publication.validate_destination!(@connection, @descriptor, @ghost)
      with_lock do
        check_supervised_scope!
        row = DiscussionBridgeCmsAttentionInspection.find_by(
          inspection_id: inspection_id, content_connection_id: @connection.id, status: "waiting",
        )
        next unless row && row.cms_mapping.source_id == @source_id

        inspection = ::DiscussionBridge::CmsReceiptCipher.decrypt(row.payload_tree)
        @mapping = inspection.fetch("mapping")
        @state = PluginStore.get(Publication::STORE, @key)
        observation = observe_attention(inspection)
        check_supervised_scope!
        receiver("V4-34") do
          ::DiscussionBridge::CmsAttentionRecovery.new(@connection).report(
            inspection_id,
            { "mutation_id" => SecureRandom.uuid, "context_sha256" => row.context_sha256, "observation" => observation },
          )
        end
      end
    end

    private

    def observe_attention(inspection)
      empty = {
        "profile" => "ghost-dynamic-1", "observed_at" => Time.now.utc.iso8601(3),
        "native_state" => "unavailable", "issue" => "collector_unavailable",
        "native_command" => "none", "pending_mutation" => "uncertain",
        "object_exists" => nil, "native_id" => nil, "native_revision" => nil,
        "ownership" => nil, "native_result" => nil, "verification" => nil,
        "source_revision" => nil, "managed_content_sha256" => nil, "prepared_transaction_id" => nil,
        "journal_sha256" => nil, "baseline_sha256" => nil, "candidate_sha256" => nil,
        "current_sha256" => nil, "restoration_operation_id" => nil,
      }
      return empty unless @state && @state.fetch("kind", "post") == @kind &&
                          @state["mapping_id"] == @mapping.fetch("mapping_id") &&
                          @state["external_id"] == @mapping.fetch("external_id") &&
                          @state["url"] == @mapping.fetch("canonical_url")
      return empty if inspection["prepared_transaction"]

      facts = if @state["native_id"]
        article = @ghost.article(@kind, @state.fetch("native_id"))
        assert_owned!(article)
        attention_baseline(inspection, article) || attention_candidate(inspection, article)
      elsif !@state["draft_dispatch_started"] && @mapping["destination_native_id"].nil? &&
            inspection.fetch("work").fetch("action") == "publish_revision"
        slug = @state.fetch("slug")
        unless GhostSite::COLLECTIONS.keys.any? { |kind| @ghost.article_by_slug(kind, slug) }
          public_absence!
          { "native_state" => "never_applied", "object_exists" => false }
        end
      end
      return empty.merge("native_state" => "conflict", "issue" => "native_conflict") unless facts

      empty.merge(facts).merge(
        "observed_at" => Time.now.utc.iso8601(3), "issue" => "none", "pending_mutation" => "settled",
        "journal_sha256" => Digest::SHA256.hexdigest(JSON.generate(@state)),
      )
    rescue Error => error
      return empty.merge("issue" => "public_proof_unavailable") if error.code == "public_verification_failed"
      return empty.merge("native_state" => "conflict", "issue" => "native_conflict") if error.code == "native_ownership_conflict"

      empty
    end

    def attention_baseline(inspection, article)
      result = inspection["native_result"] || inspection["verified_native_result"]
      baseline = native_baseline
      return unless result && baseline && result["native_revision"] == article["updated_at"] && retained_article?(article)

      if result.fetch("kind") == "withdraw"
        assert_withdrawn!(article)
        revision = nil
      else
        return unless article["status"] == "published" && article["url"] == @state.fetch("url")

        revision = @mapping["synchronized_source_revision"] || @mapping["publicly_verified_source_revision"]
        return unless baseline["revision"] == revision
      end
      digest = baseline.fetch("digest")
      attention_facts(
        article, result, revision, digest, baseline.fetch("source_url"),
        { "native_state" => "baseline", "baseline_sha256" => digest },
      )
    end

    def attention_candidate(inspection, article)
      work = inspection.fetch("work")
      operation = @state["operation"]
      return unless operation && recorded_work_id(operation) == work.fetch("work_id") && operation["receipt"]

      @action = work.fetch("action")
      @source = inspection["source"]
      @revision = work["source_revision"]
      if withdrawing?
        return unless operation["withdraw_started"] && native_baseline

        assert_withdrawn!(article)
        digest = native_baseline.fetch("digest")
        source_url = native_baseline.fetch("source_url")
      else
        return unless @source && operation["publish_started"] && operation["html"]

        source_url = @source.fetch("topic_url")
        digest = fragment_digest(operation.fetch("html"), source_url: source_url)
        return unless target_article?(article, digest)
      end
      result = native_result({ "native_revision" => article.fetch("updated_at") }, operation.fetch("receipt"))
      attention_facts(
        article, result, @revision, digest, source_url,
        { "native_state" => "candidate_applied", "candidate_sha256" => digest },
      )
    end

    def attention_facts(article, result, revision, digest, source_url, facts)
      receipts = [@state.dig("operation", "receipt"), @state.dig("verified", "receipt")]
      receipt = receipts.compact.find { |candidate| receipt_sha256(candidate) == result["ownership_receipt_sha256"] }
      return unless receipt && receipt["native_id"] == article["id"] &&
                    receipt["resource_id"] == @mapping["resource_id"] &&
                    receipt["canonical_url"] == @mapping["canonical_url"] &&
                    receipt["external_id"] == @mapping["external_id"]

      facts.merge(
        "object_exists" => true, "native_id" => article.fetch("id"), "native_revision" => article.fetch("updated_at"),
        "ownership" => receipt.slice("resource_id", "external_id", "native_id", "canonical_url", "source_revision")
          .merge("ownership_receipt_sha256" => result.fetch("ownership_receipt_sha256")),
        "native_result" => result, "verification" => attention_public_proof(result, revision, digest, source_url),
        "source_revision" => revision, "managed_content_sha256" => digest, "current_sha256" => digest,
      )
    end

    def attention_public_proof(result, revision, digest, source_url)
      identity = { "native_id" => result.fetch("native_id"), "url" => @state.fetch("url") }
      if result.fetch("kind") == "withdraw"
        status = public_absence!
        return identity.merge("kind" => "absent", "http_status" => status, "checked_at" => Time.now.utc.iso8601(3))
      end

      status, body = @ghost.public_article(@state.fetch("url"))
      unless status == 200 && fragment_digest(body, source_url: source_url) == digest
        raise Error.new("public_verification_failed", status: status)
      end

      representation = result.fetch("representation")
      identity.merge(
        "kind" => "published", "source_revision" => revision, "source_content_sha256" => representation.fetch("source_content_sha256"),
        "native_publication_sha256" => digest, "verification_profile" => "ghost-r7-#{@kind}-html-card-1",
        "checked_at" => Time.now.utc.iso8601(3), "representation" => representation,
      )
    end
  end
end
