# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module DiscussionBridgeGhost
  # From-Discourse work only. A successful guard is short-lived authority, NOT
  # an instruction to write. Durable native intents still decide whether a
  # create/update happened and must reconcile unknown outcomes before another.
  class WorkAuthority
    include ProtectedDiagnostics

    WORK_FIELDS = %w[
      work_id
      mapping_id
      source_id
      source_revision
      policy_revision
      action
      attempt_cycle
      attempt
      lease_generation
    ].freeze
    MAPPING_FIELDS = %w[
      mapping_id
      resource_id
      connection_id
      source_id
      external_id
      canonical_url
      presentation_mode
    ].freeze
    MINIMUM_REMAINING_SECONDS = 15 # Ghost HTTP is bounded to 10 seconds.

    def bound_to?(context)
      @context.equal?(context)
    end

    # Exact ordinary From intent, not a generic callback granting arbitrary
    # native writes. URL moves have additional authority and are refused here.
    def guard_native!(command)
      owner = command.fetch("owner")
      expected_action =
        (
          if @identity.fetch("action") == "withdraw"
            ["withdraw"]
          else
            %w[create_draft publish]
          end
        )
      unless command.fetch("binding") == @context.binding &&
               command.dig("identity", "resource_id") ==
                 @mapping.fetch("resource_id") &&
               owner.fetch("direction") == "from_discourse" &&
               owner.fetch("mapping_id") == @identity.fetch("mapping_id") &&
               owner.fetch("work_id") == @identity.fetch("work_id") &&
               owner.fetch("generation") ==
                 @identity.fetch("lease_generation") &&
               owner.fetch("source_revision") ==
                 @identity.fetch("source_revision") &&
               owner.fetch("external_id") == @mapping.fetch("external_id") &&
               expected_action.include?(owner.fetch("action")) &&
               owner.fetch("move_id").nil? && owner.fetch("proof_nonce").nil?
        raise Error.new("work_authority_unavailable")
      end
      # The initial native binding is nil throughout the draft/real-ID phase.
      # A locally discovered draft ID must not impersonate a receiver binding.
      guard!(operation: :mutate, native_id: @initial_native_id)
    rescue KeyError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def initialize(
      context:,
      journal:,
      lease:,
      mapping:,
      scope_revision:,
      now: -> { Time.now.utc }
    )
      unless context.is_a?(ExecutionContext) &&
               journal.is_a?(MutationJournal) && journal.context.equal?(context)
        raise Error.new("identity_conflict")
      end
      @context, @journal, @protocol, @now =
        context,
        journal,
        context.protocol,
        now
      @installation = context.installation
      @protocol.validate!("Lease", lease)
      @protocol.validate!("Mapping", mapping)
      @protocol.validate!("Revision", scope_revision)
      @identity = copy(lease.fetch("work").slice(*WORK_FIELDS)).freeze
      validate_work_identity!(@identity)
      @mapping = copy(mapping.slice(*MAPPING_FIELDS)).freeze
      @scope_revision = scope_revision.dup.freeze
      @initial_native_id = mapping.fetch("destination_native_id")&.dup&.freeze
      @authority = {
        "work_id" => @identity.fetch("work_id"),
        "lease_token" => lease.fetch("lease_token").dup.freeze,
        "lease_generation" => lease.fetch("lease_generation"),
        "source_revision" => @identity.fetch("source_revision"),
        "policy_revision" => @identity.fetch("policy_revision")
      }.freeze
      @protocol.validate!("LeaseAuthority", @authority)
      unless @authority.fetch("lease_generation") ==
               @identity.fetch("lease_generation") &&
               @mapping.fetch("mapping_id") == @identity.fetch("mapping_id") &&
               @mapping.fetch("source_id") == @identity.fetch("source_id") &&
               @mapping.fetch("connection_id") ==
                 @installation.connection_public_id &&
               @protocol.url_origin_key(@mapping.fetch("canonical_url")) ==
                 @protocol.origin_key(@context.binding.fetch("ghost_origin"))
        raise Error.new("identity_conflict")
      end
      @key =
        "#{@identity.fetch("work_id")}:#{@identity.fetch("lease_generation")}"
      initialize_checkpoint!
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    # :mutate is only the leased stage. :verify is only the synchronized stage
    # and needs the exact native ID from a retained native receipt. Neither
    # terminal history nor a synchronized lease permits another native create.
    def guard!(operation:, native_id: nil)
      if %i[mutate verify].exclude?(operation)
        raise Error.new("work_authority_unavailable")
      end
      if native_id &&
           (!native_id.is_a?(String) || !/\A[a-f0-9]{24}\z/.match?(native_id))
        raise Error.new("identity_conflict")
      end
      @context.outside_transaction!
      @context.assert!
      current!(operation, native_id)
      assert_fence!

      # Resolve the old request first, including the after-response/before-local-
      # commit crash. Its replay is history, not fresh token proof. Then issue a
      # new renewal through the actual router under the still-current authority.
      resolve_pending! if checkpoint.fetch("pending")
      begin_renewal!
      renewed = resolve_pending!
      current = current!(operation, native_id)
      assert_fence!
      @context.assert!
      if Time.iso8601(renewed.fetch("expires_at")) - @now.call <
           MINIMUM_REMAINING_SECONDS ||
           Time.iso8601(current.fetch("lease_expires_at")) - @now.call <
             MINIMUM_REMAINING_SECONDS
        raise Error.new("work_authority_unavailable")
      end
      current
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def copy(value)
      JSON.parse(JSON.generate(value))
    end

    def current!(operation, native_id)
      connection = read!("V4-01")
      policy = connection.fetch("policy")
      capabilities = connection.fetch("native_capabilities")
      unless connection.fetch("connection_id") ==
               @installation.connection_public_id &&
               connection.fetch("profile") == "ghost" &&
               connection.fetch("scope_revision") == @scope_revision &&
               connection.fetch("directions").include?("from_discourse") &&
               @protocol.origin_key(connection.fetch("destination_origin")) ==
                 @protocol.origin_key(@context.binding.fetch("ghost_origin")) &&
               policy.fetch("enabled") &&
               policy.fetch("policy_revision") ==
                 @identity.fetch("policy_revision") &&
               policy.fetch("publication_kind") == "dynamic" &&
               capabilities.fetch("publication_kind") == "dynamic" &&
               capabilities.fetch("complete_content_supported") &&
               capabilities.fetch("supported_presentations").include?(
                 policy.fetch("presentation_mode")
               ) &&
               policy.fetch("presentation_mode") ==
                 @mapping.fetch("presentation_mode")
        raise Error.new("work_authority_unavailable")
      end
      current =
        read!("V4-14", path: { "work_id" => @identity.fetch("work_id") })
      work = current.fetch("work")
      mapping = current.fetch("mapping")
      expected_stage = operation == :mutate ? "leased" : "synchronized"
      unless work.slice(*WORK_FIELDS) == @identity &&
               work.fetch("state") == expected_stage &&
               mapping.slice(*MAPPING_FIELDS) == @mapping &&
               mapping.fetch("mapping_state") != "withdrawn" &&
               current.fetch("lease_expires_at")
        raise Error.new("work_authority_unavailable")
      end
      if @identity.fetch("action") == "publish_revision" &&
           mapping.fetch("desired_source_revision") !=
             @identity.fetch("source_revision")
        raise Error.new("work_authority_unavailable")
      end
      observed_native = mapping.fetch("destination_native_id")
      expected_native = @initial_native_id || native_id
      if (@initial_native_id && native_id && @initial_native_id != native_id) ||
           observed_native != expected_native ||
           (operation == :verify && !expected_native)
        raise Error.new("identity_conflict")
      end
      current
    end

    def read!(route, path: {})
      result = @context.read(route, path: path)
      raise Error.new("work_authority_unavailable") unless result.status == 200
      result.value
    end

    def initial_state
      {
        "format" => "ghost-work-authority-1",
        "binding" => @context.binding,
        "identity" => @identity,
        "mapping" => @mapping,
        "initial_native_id" => @initial_native_id,
        "scope_revision" => @scope_revision,
        "authority" => @authority,
        "next_renewal" => 0,
        "pending" => nil,
        "last_lease" => nil
      }
    end

    def initialize_checkpoint!
      @context.commit do
        row = find_record("work_authority", @key)
        if row
          retained = row.private_payload
          raise Error.new("identity_conflict") unless retained.is_a?(Hash)
          original_native = retained.fetch("initial_native_id")
          valid_original =
            original_native.nil? ||
              (
                original_native.is_a?(String) &&
                  /\A[a-f0-9]{24}\z/.match?(original_native)
              )
          raise Error.new("identity_conflict") unless valid_original
          # A synchronized mapping may now contain the ID assigned after this
          # work started. Keep the original baseline; guard!(:verify) requires
          # that ID separately from the retained native intent/receipt.
          @initial_native_id = original_native&.dup&.freeze
          validate_checkpoint!(retained, record: row)
        else
          write_record("work_authority", @key, initial_state)
        end
        assert_fence!
      end
    end

    def checkpoint
      row = find_record("work_authority", @key)
      raise Error.new("identity_conflict") unless row
      validate_checkpoint!(row.private_payload, record: row)
    end

    def validate_checkpoint!(state, record: nil)
      unless state.is_a?(Hash) && state.keys.sort == initial_state.keys.sort &&
               state.except("next_renewal", "pending", "last_lease") ==
                 initial_state.except("next_renewal", "pending", "last_lease")
        raise Error.new("identity_conflict")
      end
      validate_history!(
        state,
        record_key: @key,
        indexed_mapping: record&.mapping_public_id
      )
      state
    end

    # History is evidence, not current authority. Validate its own identity and
    # original scope/URL without rebasing it to a newer work item or URL move.
    def validate_history!(state, record_key:, indexed_mapping:)
      unless state.is_a?(Hash) && state.keys.sort == initial_state.keys.sort &&
               state.fetch("format") == "ghost-work-authority-1" &&
               state.fetch("binding") == @context.binding
        raise Error.new("identity_conflict")
      end
      identity, mapping, authority =
        state.values_at("identity", "mapping", "authority")
      validate_work_identity!(identity)
      unless mapping.is_a?(Hash) && mapping.keys.sort == MAPPING_FIELDS.sort &&
               mapping.fetch("mapping_id") == identity.fetch("mapping_id") &&
               mapping.fetch("source_id") == identity.fetch("source_id") &&
               mapping.fetch("connection_id") ==
                 @installation.connection_public_id &&
               record_key ==
                 "#{identity.fetch("work_id")}:#{identity.fetch("lease_generation")}"
        raise Error.new("identity_conflict")
      end
      %w[mapping_id resource_id].each do |field|
        @protocol.validate!("UUID", mapping.fetch(field))
      end
      %w[source_id external_id].each do |field|
        @protocol.validate!("OpaqueId", mapping.fetch(field))
      end
      @protocol.validate!("Mode", mapping.fetch("presentation_mode"))
      @protocol.validate!("Revision", state.fetch("scope_revision"))
      unless @protocol.url_origin_key(mapping.fetch("canonical_url")) ==
               @protocol.origin_key(@context.binding.fetch("ghost_origin"))
        raise Error.new("identity_conflict")
      end
      unless indexed_mapping.nil? ||
               indexed_mapping == identity.fetch("mapping_id")
        raise Error.new("identity_conflict")
      end
      native_id = state.fetch("initial_native_id")
      valid_native =
        native_id.nil? ||
          (native_id.is_a?(String) && /\A[a-f0-9]{24}\z/.match?(native_id))
      raise Error.new("identity_conflict") unless valid_native
      @protocol.validate!("LeaseAuthority", authority)
      fields = %w[work_id lease_generation source_revision policy_revision]
      unless authority.slice(*fields) == identity.slice(*fields)
        raise Error.new("identity_conflict")
      end
      @protocol.validate!("UInt", state.fetch("next_renewal"))
      pending = state.fetch("pending")
      unless pending.nil?
        unless pending.is_a?(Hash) &&
                 pending.keys.sort == %w[mutation_id operation_key] &&
                 pending.fetch("operation_key") == renewal_key(state)
          raise Error.new("identity_conflict")
        end
        @protocol.validate!("UUID", pending.fetch("mutation_id"))
      end
      last_lease = state.fetch("last_lease")
      unless (state.fetch("next_renewal") == 0) == last_lease.nil?
        raise Error.new("identity_conflict")
      end
      unless last_lease.nil?
        validate_lease!(last_lease, identity: identity, authority: authority)
      end
      state
    end

    def renewal_key(state)
      identity = state.fetch("identity")
      "renew:#{identity.fetch("work_id")}:#{identity.fetch("lease_generation")}:#{state.fetch("next_renewal")}"
    end

    def begin_renewal!
      @context.commit do
        state = copy(checkpoint)
        raise Error.new("identity_conflict") if state.fetch("pending")
        key = renewal_key(state)
        if @installation.mutations.exists?(operation_key: key)
          raise Error.new("identity_conflict")
        end
        state["pending"] = {
          "operation_key" => key,
          "mutation_id" => SecureRandom.uuid
        }
        write_record("work_authority", @key, state)
      end
    end

    def resolve_pending!
      state = checkpoint
      pending = state.fetch("pending")
      raise Error.new("identity_conflict") unless pending
      result =
        @journal.call(
          pending.fetch("operation_key"),
          "V4-15",
          path: {
            "work_id" => @identity.fetch("work_id")
          }
        ) do
          {
            "mutation_id" => pending.fetch("mutation_id"),
            "authority" => @authority
          }
        end
      raise Error.new("work_renewal_pending") unless result.status == 200
      lease = result.value
      validate_lease!(lease)
      @context.commit do
        retained = copy(checkpoint)
        unless retained.fetch("pending") == pending
          raise Error.new("identity_conflict")
        end
        advance_fence!
        next_counter = retained.fetch("next_renewal") + 1
        @protocol.validate!("UInt", next_counter)
        retained["next_renewal"] = next_counter
        retained["pending"] = nil
        retained["last_lease"] = lease
        write_record("work_authority", @key, retained)
      end
      lease
    end

    def validate_lease!(lease, identity: @identity, authority: @authority)
      @protocol.validate!("Lease", lease)
      unless lease.fetch("work").slice(*WORK_FIELDS) == identity &&
               lease.fetch("lease_token") == authority.fetch("lease_token") &&
               lease.fetch("lease_generation") ==
                 authority.fetch("lease_generation") &&
               Time.iso8601(lease.fetch("expires_at")) >
                 Time.iso8601(lease.fetch("server_time"))
        raise Error.new("identity_conflict")
      end
    end

    def assert_fence!
      row = find_record("mapping_fence", @identity.fetch("mapping_id"))
      unless row
        # A completed local checkpoint and its fence are one atomic commit.
        # Absence is valid before that first success, not after a restore has
        # lost the fence. Preserve the inconsistency for explicit reconciliation.
        if checkpoint.fetch("next_renewal") > 0 || @initial_native_id
          raise Error.new("identity_conflict")
        end
        assert_no_successful_mapping_history!
        return
      end
      fence = row.private_payload
      unless fence.is_a?(Hash) &&
               fence.keys.sort == %w[binding generation identity] &&
               fence.fetch("binding") == @context.binding
        raise Error.new("identity_conflict")
      end
      unless row.mapping_public_id.nil? ||
               row.mapping_public_id == @identity.fetch("mapping_id")
        raise Error.new("identity_conflict")
      end
      @protocol.validate!("PositiveUInt", fence.fetch("generation"))
      validate_work_identity!(fence.fetch("identity"))
      unless fence.fetch("identity").fetch("lease_generation") ==
               fence.fetch("generation") &&
               fence.fetch("identity").fetch("mapping_id") ==
                 @identity.fetch("mapping_id") &&
               fence.fetch("identity").fetch("source_id") ==
                 @identity.fetch("source_id")
        raise Error.new("identity_conflict")
      end
      held = @identity.fetch("lease_generation")
      if held < fence.fetch("generation") ||
           (
             held == fence.fetch("generation") &&
               fence.fetch("identity") != @identity
           )
        raise Error.new("work_authority_unavailable")
      end
    end

    def assert_no_successful_mapping_history!
      # New records use the indexed public UUID locator. Legacy NULL locators
      # remain readable in bounded batches; no global decrypt/rewrite/backfill
      # is performed for ordinary indexed history belonging to other mappings.
      @installation
        .operational_records
        .where(
          kind: "work_authority",
          mapping_public_id: [@identity.fetch("mapping_id"), nil]
        )
        .find_each(batch_size: 100) do |row|
          history =
            validate_history!(
              row.private_payload,
              record_key: row.record_key,
              indexed_mapping: row.mapping_public_id
            )
          if history.fetch("identity").fetch("mapping_id") ==
               @identity.fetch("mapping_id") &&
               history.fetch("next_renewal") > 0
            raise Error.new("identity_conflict")
          end
        end
    end

    def validate_work_identity!(identity)
      unless identity.is_a?(Hash) && identity.keys.sort == WORK_FIELDS.sort
        raise Error.new("identity_conflict")
      end
      %w[work_id mapping_id attempt_cycle].each do |field|
        @protocol.validate!("UUID", identity.fetch(field))
      end
      @protocol.validate!("OpaqueId", identity.fetch("source_id"))
      @protocol.validate!("Revision", identity.fetch("policy_revision"))
      @protocol.validate!("PositiveUInt", identity.fetch("lease_generation"))
      @protocol.validate!("PositiveUInt", identity.fetch("attempt"))
      raise Error.new("identity_conflict") if identity.fetch("attempt") > 3
      case identity.fetch("action")
      when "publish_revision"
        @protocol.validate!("Revision", identity.fetch("source_revision"))
      when "withdraw"
        unless identity.fetch("source_revision").nil?
          raise Error.new("identity_conflict")
        end
      else
        raise Error.new("identity_conflict")
      end
    end

    def advance_fence!
      assert_fence!
      write_record(
        "mapping_fence",
        @identity.fetch("mapping_id"),
        {
          "binding" => @context.binding,
          "generation" => @identity.fetch("lease_generation"),
          "identity" => @identity
        }
      )
    end

    def find_record(kind, key)
      @installation.operational_records.find_by(kind: kind, record_key: key)
    end

    def write_record(kind, key, value)
      row =
        find_record(kind, key) ||
          @installation.operational_records.build(
            kind: kind,
            record_key: key,
            mapping_public_id: @identity.fetch("mapping_id")
          )
      unless row.mapping_public_id.nil? ||
               row.mapping_public_id == @identity.fetch("mapping_id")
        raise Error.new("identity_conflict")
      end
      row.encrypted_payload =
        @installation.envelope.encrypt(
          "operational_record",
          value,
          binding: JSON.generate([kind, key])
        )
      row.save!
    end
  end
end
