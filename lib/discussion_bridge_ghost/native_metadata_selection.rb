# frozen_string_literal: true

require_relative "work_authority"
require_relative "ghost_admin_client"
require_relative "native_command_journal"

module DiscussionBridgeGhost
  # Bounded, restartable descriptive lookup for the CURRENT selected native
  # relations. This never writes Ghost, acknowledges work or grants authority.
  # Clearing a selection is nil (preserve Ghost control), not an empty relation
  # assignment. The later native planner still checks actual ownership and CAS.
  class NativeMetadataSelection
    include ProtectedDiagnostics

    ENTRY = "native_metadata_selection"
    FIELDS = %w[format binding work management offsets items].sort.freeze
    KINDS = %w[authors taxonomy].freeze
    SLICE_SIZE = 100

    def initialize(context:, authority:, api_key:, factory: nil)
      unless context.is_a?(ExecutionContext) &&
               authority.is_a?(WorkAuthority) && authority.bound_to?(context)
        raise Error.new("identity_conflict")
      end
      @context, @authority = context, authority
      @installation = context.installation
      @client =
        GhostAdminClient.new(
          http:
            GhostHttp.new(
              protocol: context.protocol,
              origin: context.binding.fetch("admin_origin"),
              guard: -> { current! },
              api_key: api_key,
              factory: factory
            )
        )
    end

    # At most two native GETs, each at most100 selected IDs, per call. The full
    # protocol selection can be larger: continuation is retained, never clipped.
    def advance(batch_budget: 1)
      unless batch_budget.is_a?(Integer) && (1..2).cover?(batch_budget)
        raise Error.new("configuration_invalid")
      end
      bind_current!
      state = read || initial_state
      processed = 0
      while processed < batch_budget
        kind =
          KINDS.find do |name|
            state.fetch("offsets").fetch(name) < ids(name).length
          end
        break unless kind
        offset = state.fetch("offsets").fetch(kind)
        selected = ids(kind).slice(offset, SLICE_SIZE)
        observed = @client.selected_metadata(kind, ids: selected)
        if kind == "taxonomy" &&
             observed.any? { |item| automation_tag?(item.fetch("name")) }
          raise Error.new("identity_conflict")
        end
        current!
        after = mutable(state)
        after.fetch("items").fetch(kind).concat(observed)
        after.fetch("offsets")[kind] += selected.length
        after = snapshot(after)
        commit(state, after)
        state = after
        processed += 1
      end
      # Retain an explicit completed empty selection as well; it conveys no
      # permission to erase either native relation.
      commit(nil, state) unless row
      current!
      {
        "complete" => complete?(state),
        "batches" => processed,
        "remaining" =>
          KINDS.sum do |name|
            ids(name).length - state.fetch("offsets").fetch(name)
          end
      }.freeze
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def selection
      bind_current!
      state = read
      raise Error.new("native_state_not_ready") unless state && complete?(state)
      snapshot(
        KINDS.to_h do |kind|
          [kind, ids(kind).empty? ? nil : state.fetch("items").fetch(kind)]
        end
      )
    end

    private

    def bind_current!
      @context.outside_transaction!
      state =
        @authority.guard!(
          operation: :mutate,
          native_id: @authority.initial_native_id
        )
      unless state.dig("work", "action") == "publish_revision"
        raise Error.new("work_authority_unavailable")
      end
      @work = snapshot(state.fetch("work").slice(*WorkAuthority::WORK_FIELDS))
      @management = @authority.native_management!(stage: "publish")
      @key = "#{@work.fetch("work_id")}:#{@work.fetch("lease_generation")}"
      current!
    end

    def current!
      @authority.guard!(
        operation: :mutate,
        native_id: @authority.initial_native_id,
        management: @management
      )
    end

    def ids(kind)
      name = kind == "authors" ? "author" : "taxonomy"
      @management.value.fetch("policy_#{name}_ids")
    end

    def initial_state
      snapshot(
        "format" => "ghost-native-metadata-selection-1",
        "binding" => @context.binding,
        "work" => @work,
        "management" => @management.value,
        "offsets" => KINDS.to_h { |kind| [kind, 0] },
        "items" => KINDS.to_h { |kind| [kind, []] }
      )
    end

    def complete?(state)
      KINDS.all? do |kind|
        state.fetch("offsets").fetch(kind) == ids(kind).length
      end
    end

    def row
      @installation.operational_records.find_by(kind: ENTRY, record_key: @key)
    end

    def read
      saved = row
      return unless saved
      state = snapshot(saved.private_payload)
      unless state.is_a?(Hash) && state.keys.sort == FIELDS &&
               state.fetch("format") == "ghost-native-metadata-selection-1" &&
               state.fetch("binding") == @context.binding &&
               state.fetch("work") == @work &&
               state.fetch("management") == @management.value &&
               saved.mapping_public_id == @work.fetch("mapping_id") &&
               state.fetch("offsets").is_a?(Hash) &&
               state.fetch("offsets").keys.sort == KINDS.sort &&
               state.fetch("items").is_a?(Hash) &&
               state.fetch("items").keys.sort == KINDS.sort
        raise Error.new("identity_conflict")
      end
      KINDS.each do |kind|
        offset = state.fetch("offsets").fetch(kind)
        items = state.fetch("items").fetch(kind)
        fields = kind == "authors" ? %w[id name status] : %w[id name slug]
        valid_items =
          offset.is_a?(Integer) && (0..ids(kind).length).cover?(offset) &&
            items.is_a?(Array) && items.length == offset &&
            items.all? do |item|
              item.is_a?(Hash) && item.keys.sort == fields.sort &&
                fields.all? { |field| item[field].is_a?(String) } &&
                (kind != "taxonomy" || !automation_tag?(item.fetch("name")))
            end &&
            items.map { |item| item.fetch("id") } == ids(kind).first(offset)
        raise Error.new("identity_conflict") unless valid_items
      end
      state
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def commit(before, after)
      @context.commit do
        observed = read
        matches =
          observed == before || (before == initial_state && observed.nil?)
        raise Error.new("identity_conflict") unless matches
        saved =
          row ||
            @installation.operational_records.build(
              kind: ENTRY,
              record_key: @key,
              mapping_public_id: @work.fetch("mapping_id")
            )
        saved.encrypted_payload =
          @installation.envelope.encrypt(
            "operational_record",
            after,
            binding: JSON.generate([ENTRY, @key])
          )
        saved.save!
      end
    end

    def automation_tag?(name)
      name.start_with?("#discussionbridge-resource-") ||
        NativeManagement::INTERNAL_TAGS.include?(name)
    end

    def mutable(value)
      plain_value(
        NativeDocument.parse(
          JSON.generate(value),
          maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES
        )
      )
    end

    # The validating decoder deliberately rejects duplicate assignments. Its
    # StrictObject is not a mutable checkpoint: copy the already-validated tree
    # into ordinary hashes before advancing offsets. Never weaken the decoder.
    def plain_value(value)
      case value
      when Hash
        value.to_h { |key, member| [key, plain_value(member)] }
      when Array
        value.map { |member| plain_value(member) }
      else
        value
      end
    end

    def snapshot(value)
      freeze_value(mutable(value))
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
