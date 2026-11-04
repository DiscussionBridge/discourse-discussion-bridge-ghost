# frozen_string_literal: true

module DiscussionBridgeGhost
  # Policy-control history, NOT a native completion/ownership/readiness grant.
  # A real current lease may release an editorial field without writing Ghost.
  # Immutable generation-bounded events let later explicit selection distinguish
  # an allowed Ghost edit from an edit made while the field was still managed.
  class NativeFieldControlJournal
    include ProtectedDiagnostics

    KIND = "native_field_release"
    RELATIONS = {
      "authors" => "author_ids",
      "taxonomy" => "taxonomy_ids"
    }.freeze
    FIELDS = %w[format binding mapping work policy relation].sort.freeze

    def initialize(context:, authority: nil)
      unless context.is_a?(ExecutionContext) &&
               (
                 authority.nil? ||
                   (
                     authority.is_a?(WorkAuthority) &&
                       authority.bound_to?(context)
                   )
               )
        raise Error.new("identity_conflict")
      end
      @context, @authority, @protocol = context, authority, context.protocol
      @installation = context.installation
    end

    def observe!(management)
      check!
      unless @authority && management.is_a?(NativeManagement)
        raise Error.new("work_authority_unavailable")
      end
      state =
        @authority.guard!(
          operation: :mutate,
          native_id: @authority.initial_native_id,
          management: management
        )
      released = management.released_relations
      return if released.empty?
      descriptor = management.value
      # Old draft/withdraw descriptors never declared these choices and cannot
      # retrospectively release them. Old publish descriptors did declare both.
      policy = {
        "policy_revision" => descriptor.fetch("policy_revision"),
        "author_ids" =>
          descriptor.fetch("policy_author_ids") do
            descriptor.fetch("author_ids") || []
          end,
        "taxonomy_ids" =>
          descriptor.fetch("policy_taxonomy_ids") do
            descriptor.fetch("taxonomy_ids") || []
          end
      }
      mapping = state.fetch("mapping").slice(*WorkAuthority::MAPPING_FIELDS)
      work = state.fetch("work").slice(*WorkAuthority::WORK_FIELDS)
      events =
        released.map do |relation|
          value = {
            "format" => "ghost-native-field-release-1",
            "binding" => @context.binding,
            "mapping" => mapping,
            "work" => work,
            "policy" => policy,
            "relation" => relation
          }
          key =
            key_for(
              mapping.fetch("mapping_id"),
              relation,
              work.fetch("lease_generation")
            )
          validate!(value, key: key, mapping_id: mapping.fetch("mapping_id"))
          [key, value]
        end
      @context.commit do
        events.each do |key, value|
          existing =
            @installation.operational_records.find_by(
              kind: KIND,
              record_key: key
            )
          if existing
            unless existing.mapping_public_id == mapping.fetch("mapping_id") &&
                     existing.private_payload == value
              raise Error.new("identity_conflict")
            end
          else
            @installation.operational_records.create!(
              kind: KIND,
              record_key: key,
              mapping_public_id: mapping.fetch("mapping_id"),
              encrypted_payload:
                @installation.envelope.encrypt(
                  "operational_record",
                  value,
                  binding: JSON.generate([KIND, key])
                )
            )
          end
        end
      end
      nil
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    # Historical facts only. Both ends are exact generations supplied by the
    # genuine content command and current command/work, not today's policy.
    # Fixed-width counter keys permit two bounded existing-index range lookups;
    # later releases cannot change reconstruction of an older physical effect.
    def released_relations(identity:, after_generation:, through_generation:)
      check!
      @protocol.validate!("UInt", after_generation)
      @protocol.validate!("PositiveUInt", through_generation)
      if after_generation > through_generation
        raise Error.new("identity_conflict")
      end
      mapping = identity.fetch("mapping_id")
      @protocol.validate!("UUID", mapping)
      RELATIONS
        .keys
        .select do |relation|
          lower = key_for(mapping, relation, after_generation)
          upper = key_for(mapping, relation, through_generation)
          row =
            @installation
              .operational_records
              .where(kind: KIND, mapping_public_id: mapping)
              .where("record_key > ? AND record_key <= ?", lower, upper)
              .order(record_key: :desc)
              .first
          next false unless row
          value = row.private_payload
          validate!(value, key: row.record_key, mapping_id: mapping)
          unless value.fetch("relation") == relation &&
                   value.fetch("mapping").slice(
                     "mapping_id",
                     "resource_id",
                     "external_id"
                   ) ==
                     identity.slice(
                       "mapping_id",
                       "resource_id",
                       "external_id"
                     ) &&
                   value.dig("work", "lease_generation") > after_generation &&
                   value.dig("work", "lease_generation") <= through_generation
            raise Error.new("identity_conflict")
          end
          true
        end
        .freeze
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def check!
      @context.outside_transaction!
      @context.assert!
    end

    def key_for(mapping, relation, generation)
      "#{mapping}:#{relation}:#{generation.to_s.rjust(16, "0")}"
    end

    def validate!(value, key:, mapping_id:)
      unless value.is_a?(Hash) && value.keys.sort == FIELDS &&
               value.fetch("format") == "ghost-native-field-release-1" &&
               value.fetch("binding") == @context.binding &&
               RELATIONS.key?(value.fetch("relation"))
        raise Error.new("identity_conflict")
      end
      mapping, work, policy = value.values_at("mapping", "work", "policy")
      unless mapping.is_a?(Hash) &&
               mapping.keys.sort == WorkAuthority::MAPPING_FIELDS.sort &&
               work.is_a?(Hash) &&
               work.keys.sort == WorkAuthority::WORK_FIELDS.sort &&
               policy.is_a?(Hash) &&
               policy.keys.sort == %w[author_ids policy_revision taxonomy_ids]
        raise Error.new("identity_conflict")
      end
      %w[mapping_id resource_id].each do |field|
        @protocol.validate!("UUID", mapping.fetch(field))
      end
      %w[work_id mapping_id attempt_cycle].each do |field|
        @protocol.validate!("UUID", work.fetch(field))
      end
      @protocol.validate!("PositiveUInt", work.fetch("lease_generation"))
      @protocol.validate!("PositiveUInt", work.fetch("attempt"))
      @protocol.validate!("Revision", work.fetch("policy_revision"))
      @protocol.validate!("OpaqueId", mapping.fetch("source_id"))
      @protocol.validate!("OpaqueId", mapping.fetch("external_id"))
      @protocol.validate!("Mode", mapping.fetch("presentation_mode"))
      case work.fetch("action")
      when "publish_revision"
        @protocol.validate!("Revision", work.fetch("source_revision"))
      when "withdraw"
        unless work.fetch("source_revision").nil?
          raise Error.new("identity_conflict")
        end
      else
        raise Error.new("identity_conflict")
      end
      RELATIONS.each_value do |field|
        ids = policy.fetch(field)
        @protocol.validate!("IdList", ids)
        unless ids.uniq == ids &&
                 ids.all? { |id| /\A[a-f0-9]{24}\z/.match?(id) }
          raise Error.new("identity_conflict")
        end
      end
      unless mapping.fetch("mapping_id") == mapping_id &&
               work.fetch("mapping_id") == mapping_id &&
               work.fetch("source_id") == mapping.fetch("source_id") &&
               work.fetch("attempt") <= 3 &&
               mapping.fetch("connection_id") ==
                 @installation.connection_public_id &&
               policy.fetch("policy_revision") ==
                 work.fetch("policy_revision") &&
               policy.fetch(RELATIONS.fetch(value.fetch("relation"))).empty? &&
               key ==
                 key_for(
                   mapping_id,
                   value.fetch("relation"),
                   work.fetch("lease_generation")
                 ) &&
               @protocol.url_origin_key(mapping.fetch("canonical_url")) ==
                 @protocol.origin_key(@context.binding.fetch("ghost_origin"))
        raise Error.new("identity_conflict")
      end
      true
    end
  end
end
