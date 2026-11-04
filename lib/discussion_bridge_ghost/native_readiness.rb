# frozen_string_literal: true

require_relative "source_intake"
require_relative "native_publication"
require_relative "native_ownership_journal"

module DiscussionBridgeGhost
  # A fresh, current desired-state check, separate from physical ownership.
  # It cannot write Ghost or send an ACK. Historical observations are readable
  # but only capture() enrolls process-local evidence for a new stage request.
  class NativeReadiness
    include ProtectedDiagnostics

    ENTRY = "native_readiness"
    FIELDS = %w[
      format
      binding
      operation
      work
      mapping
      ownership_key
      ownership_sha256
      baseline_command_id
      baseline_sha256
      native_revision
      source
      native_result
      fragment_sha256
      source_event_id
      scope_revision
    ].sort.freeze

    class Observation
      include ProtectedDiagnostics
      attr_reader :key, :value

      def initialize(key:, value:)
        @key, @value = key.freeze, value
        EvidenceRegistry.prepare(self)
        freeze
      end
    end

    def initialize(
      context:,
      commands:,
      authority:,
      api_key:,
      operation: :mutate,
      factory: nil
    )
      valid_operation = %i[mutate verify].include?(operation)
      unless context.is_a?(ExecutionContext) &&
               commands.is_a?(NativeCommandJournal) &&
               commands.context.equal?(context) &&
               authority.is_a?(WorkAuthority) && authority.bound_to?(context) &&
               valid_operation
        raise Error.new("identity_conflict")
      end
      @context, @commands, @authority, @api_key, @operation, @factory =
        context,
        commands,
        authority,
        api_key,
        operation,
        factory
      @installation, @protocol = context.installation, context.protocol
      @baselines =
        NativeBaselineJournal.new(context: context, journal: commands)
      @ownership =
        NativeOwnershipJournal.new(
          context: context,
          commands: commands,
          authority: authority,
          api_key: api_key,
          factory: factory
        )
      @evidence = EvidenceRegistry.new
    end

    def capture(event_id: nil, prior_ownership_key: nil)
      @context.outside_transaction!
      @context.assert!
      if @operation == :mutate
        raise Error.new("identity_conflict") unless prior_ownership_key.nil?
        ownership = @ownership.capture
      else
        unless prior_ownership_key.is_a?(String)
          raise Error.new("identity_conflict")
        end
        ownership = @ownership.retained(prior_ownership_key)
      end
      @native_id = ownership.receipt.value.fetch("native_id")
      state = current!
      work, mapping = state.values_at("work", "mapping")
      unless ownership.value.fetch("work").slice(*WorkAuthority::WORK_FIELDS) ==
               work.slice(*WorkAuthority::WORK_FIELDS)
        raise Error.new("identity_conflict")
      end
      connection = @context.read("V4-01")
      unless connection.status == 200
        raise Error.new("work_authority_unavailable")
      end
      @management =
        NativeManagement.for_policy(
          protocol: @protocol,
          policy: connection.value.fetch("policy"),
          stage: work.fetch("action") == "withdraw" ? "withdraw" : "publish"
        )
      current!
      baseline = @baselines.current(mapping.fetch("mapping_id"))
      unless baseline &&
               baseline.sha256 == ownership.value.fetch("baseline_sha256") &&
               baseline.value.fetch("command_id") ==
                 ownership.value.fetch("baseline_command_id")
        raise Error.new("identity_conflict")
      end
      command =
        @commands.retained(baseline.value.fetch("command_id")).fetch("command")
      maximum = command.dig("request", "maximum_bytes")
      client =
        GhostAdminClient.new(
          http:
            GhostHttp.new(
              protocol: @protocol,
              origin: @context.binding.fetch("admin_origin"),
              guard: -> { current! },
              api_key: @api_key,
              factory: @factory
            )
        )
      native =
        client.get(
          @native_id,
          kind: baseline.value.dig("identity", "kind"),
          maximum_bytes: maximum
        )
      if @operation == :mutate &&
           native.fetch("updated_at") !=
             ownership.value.fetch("native_revision")
        raise Error.new("identity_conflict")
      end
      baseline.assert_current!(
        native,
        management: @management,
        released_relations:
          baseline.released_relations(
            journal: @commands,
            through_generation: work.fetch("lease_generation")
          )
      )
      # Fresh unique resource lookup, not just a copied public marker or one
      # Admin GET. Both native types must still resolve this same object.
      matches =
        client.find_by_resource(
          mapping.fetch("resource_id"),
          maximum_bytes: maximum
        )
      unless matches.length == 1 && matches.first == native
        raise Error.new("identity_conflict")
      end
      source = nil
      if work.fetch("action") == "publish_revision"
        intake = SourceIntake.new(context: @context)
        source = intake.source(event_id)
        html =
          intake.content(event_id, maximum_bytes: SourceIntake::MAXIMUM_CONTENT)
        article =
          NativeArticle.new(
            protocol: @protocol,
            forum_origin: @context.binding.fetch("forum_origin"),
            source: source,
            html: html,
            maximum_bytes: SourceIntake::MAXIMUM_CONTENT
          )
        qualify_publication!(
          native,
          baseline,
          article,
          mapping,
          work,
          connection.value,
          maximum
        )
      else
        unless event_id.nil? && native.fetch("status") == "draft" &&
                 baseline.value.dig("management", "stage") == "withdraw"
          raise Error.new("native_state_not_ready")
        end
      end
      final = current!
      unless final.fetch("work").slice(*WorkAuthority::WORK_FIELDS) ==
               work.slice(*WorkAuthority::WORK_FIELDS) &&
               final.fetch("mapping").slice(*WorkAuthority::MAPPING_FIELDS) ==
                 mapping.slice(*WorkAuthority::MAPPING_FIELDS) &&
               @baselines.current(mapping.fetch("mapping_id"))&.sha256 ==
                 baseline.sha256
        raise Error.new("work_authority_unavailable")
      end
      native_result = {
        "kind" => work.fetch("action"),
        "native_id" => @native_id,
        "external_id" => mapping.fetch("external_id"),
        "canonical_url" => mapping.fetch("canonical_url"),
        "native_revision" => native.fetch("updated_at"),
        "ownership_receipt_sha256" => ownership.receipt.sha256
      }
      if source
        native_result["representation"] = {
          "kind" => "full",
          "source_content_sha256" => source.fetch("content_sha256")
        }
      end
      @protocol.validate!("SyncResult", native_result)
      value =
        snapshot(
          "format" => "ghost-native-readiness-1",
          "binding" => @context.binding,
          "operation" => @operation.to_s,
          "work" => work,
          "mapping" => mapping,
          "ownership_key" => ownership.key,
          "ownership_sha256" => ownership.receipt.sha256,
          "baseline_command_id" => baseline.value.fetch("command_id"),
          "baseline_sha256" => baseline.sha256,
          "native_revision" => native.fetch("updated_at"),
          "source" => source,
          "source_event_id" => event_id,
          "native_result" => native_result,
          "scope_revision" => connection.value.fetch("scope_revision"),
          "fragment_sha256" => baseline.value.dig("fragment", "sha256")
        )
      key = Digest::SHA256.hexdigest(JSON.generate(value))
      @context.commit do
        existing = row(key)
        if existing
          unless existing.mapping_public_id == mapping.fetch("mapping_id") &&
                   existing.private_payload == value
            raise Error.new("identity_conflict")
          end
        else
          @installation.operational_records.create!(
            kind: ENTRY,
            record_key: key,
            mapping_public_id: mapping.fetch("mapping_id"),
            encrypted_payload:
              @installation.envelope.encrypt(
                "operational_record",
                value,
                binding: JSON.generate([ENTRY, key])
              )
          )
        end
      end
      result = retained(key)
      @evidence.retain(result, result.value)
      result
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    ensure
      @native_id = @management = nil
    end

    def actual_evidence(observation)
      @evidence[observation]
    end

    def retained(key)
      @context.outside_transaction!
      @context.assert!
      unless key.is_a?(String) && /\A[a-f0-9]{64}\z/.match?(key)
        raise Error.new("identity_conflict")
      end
      saved = row(key)
      value = saved && snapshot(saved.private_payload)
      unless value && value.keys.sort == FIELDS &&
               value["format"] == "ghost-native-readiness-1" &&
               value["binding"] == @context.binding &&
               Digest::SHA256.hexdigest(JSON.generate(value)) == key &&
               %w[mutate verify].include?(value["operation"]) &&
               saved.mapping_public_id == value.dig("mapping", "mapping_id")
        raise Error.new("identity_conflict")
      end
      @protocol.validate!("Work", value.fetch("work"))
      @protocol.validate!("Mapping", value.fetch("mapping"))
      @protocol.validate!("SyncResult", value.fetch("native_result"))
      @protocol.validate!("Revision", value.fetch("native_revision"))
      @protocol.validate!("Revision", value.fetch("scope_revision"))
      ownership = @ownership.retained(value.fetch("ownership_key"))
      baseline = @baselines.retained(value.fetch("baseline_command_id"))
      receipt = ownership.receipt.value
      unless ownership.receipt.sha256 == value["ownership_sha256"] &&
               baseline.sha256 == value["baseline_sha256"] &&
               baseline.sha256 == ownership.value["baseline_sha256"] &&
               baseline.value.dig("fragment", "sha256") ==
                 value["fragment_sha256"] &&
               value.fetch("work").slice(*WorkAuthority::WORK_FIELDS) ==
                 ownership
                   .value
                   .fetch("work")
                   .slice(*WorkAuthority::WORK_FIELDS) &&
               value.dig("native_result", "kind") ==
                 value.dig("work", "action") &&
               value.dig("native_result", "native_id") ==
                 receipt.fetch("native_id") &&
               value.dig("native_result", "ownership_receipt_sha256") ==
                 ownership.receipt.sha256 &&
               value.dig("native_result", "canonical_url") ==
                 receipt.fetch("canonical_url") &&
               value.dig("native_result", "external_id") ==
                 receipt.fetch("external_id") &&
               value.dig("mapping", "mapping_id") ==
                 receipt.fetch("mapping_id") &&
               value.dig("mapping", "resource_id") ==
                 receipt.fetch("resource_id") &&
               value.dig("mapping", "source_id") ==
                 receipt.fetch("source_id") &&
               value.dig("mapping", "connection_id") ==
                 @installation.connection_public_id &&
               value.dig("mapping", "external_id") ==
                 receipt.fetch("external_id") &&
               value.dig("mapping", "canonical_url") ==
                 receipt.fetch("canonical_url") &&
               value.dig("work", "mapping_id") == receipt.fetch("mapping_id") &&
               value.dig("work", "source_id") == receipt.fetch("source_id") &&
               value.dig("work", "state") ==
                 (value["operation"] == "mutate" ? "leased" : "synchronized") &&
               value["native_revision"] ==
                 value.dig("native_result", "native_revision")
        raise Error.new("identity_conflict")
      end
      source = value.fetch("source")
      if source
        @protocol.validate!("Source", source)
        unless SourceIntake.new(context: @context).source(
                 value.fetch("source_event_id")
               ) == source &&
                 source.fetch("source_id") == value.dig("work", "source_id") &&
                 source.fetch("source_revision") ==
                   value.dig("work", "source_revision") &&
                 source.fetch("source_revision") ==
                   baseline.value.dig("fragment", "source_revision") &&
                 value.dig("native_result", "representation") ==
                   {
                     "kind" => "full",
                     "source_content_sha256" => source.fetch("content_sha256")
                   }
          raise Error.new("identity_conflict")
        end
      elsif value.dig("work", "action") != "withdraw" ||
            !value.fetch("source_event_id").nil?
        raise Error.new("identity_conflict")
      end
      Observation.new(key: key.dup, value: value)
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def current!
      @authority.guard!(
        operation: @operation,
        native_id:
          @operation == :mutate ? @authority.initial_native_id : @native_id,
        management: @management
      )
    end

    def row(key)
      @installation.operational_records.find_by(kind: ENTRY, record_key: key)
    end

    def qualify_publication!(
      native,
      baseline,
      article,
      mapping,
      work,
      connection,
      maximum
    )
      fragment_state = baseline.value.fetch("fragment")
      fragment =
        OwnedFragment.new(
          resource_id: mapping.fetch("resource_id"),
          kind: baseline.value.dig("identity", "kind"),
          native_id: @native_id,
          nonce: fragment_state.fetch("nonce"),
          maximum_bytes: maximum
        )
      expected =
        NativePublication.new(
          protocol: @protocol,
          article: article,
          fragment: fragment,
          mapping: mapping,
          work: work,
          forum_name: connection.fetch("forum_name"),
          command_id: baseline.value.fetch("content_command_id"),
          purpose: :compare
        )
      expected_span = fragment.extract(expected.html)
      actual_span = fragment.extract(native.fetch("html"))
      ready =
        native.fetch("title") == expected.title &&
          native.fetch("status") == "published" &&
          native.fetch("visibility") == "public" &&
          native.fetch("url") == mapping.fetch("canonical_url") &&
          Time.iso8601(native.fetch("published_at")) ==
            Time.iso8601(expected.publication_date) &&
          expected_span.sha256 == actual_span.sha256 &&
          actual_span.sha256 == fragment_state.fetch("sha256")
      raise Error.new("native_state_not_ready") unless ready
      selected_authors, selected_tags =
        @management.value.values_at("author_ids", "taxonomy_ids")
      unless selected_authors.nil? ||
               native.fetch("authors").map { |author| author.fetch("id") } ==
                 selected_authors
        raise Error.new("native_state_not_ready")
      end
      tags = native.fetch("tags")
      internal = ->(tag) do
        tag.fetch("name").start_with?("#discussionbridge-resource-") ||
          NativeManagement::INTERNAL_TAGS.include?(tag.fetch("name"))
      end
      editorial =
        tags.reject { |tag| internal.call(tag) }.map { |tag| tag.fetch("id") }
      unless selected_tags.nil? || editorial == selected_tags
        raise Error.new("native_state_not_ready")
      end
      names = tags.map { |tag| tag.fetch("name") }
      ready_tags =
        names.include?("#discussionbridge-source") &&
          names.include?(
            "#discussionbridge-#{mapping.fetch("presentation_mode")}"
          )
      raise Error.new("native_state_not_ready") unless ready_tags
    end

    def snapshot(value)
      parsed =
        NativeDocument.parse(
          JSON.generate(value),
          maximum_bytes: WireProtocol::RESPONSE_MAXIMUM
        )
      freeze_value(parsed)
    end

    def freeze_value(value)
      case value
      when Hash
        value.each do |key, member|
          key.freeze
          freeze_value(member)
        end
      when Array
        value.each { |member| freeze_value(member) }
      end
      value.freeze
    end
  end
end
