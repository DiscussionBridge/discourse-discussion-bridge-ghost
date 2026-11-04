# frozen_string_literal: true

require_relative "native_baseline_journal"
require_relative "ownership_receipt"

module DiscussionBridgeGhost
  # Current native ownership observations under an actual From lease. Immutable
  # physical completions remain separate. A receipt is NOT proof that the latest
  # source/policy has been published or publicly verified, and never sends ACK.
  class NativeOwnershipJournal
    include ProtectedDiagnostics

    ENTRY = "native_ownership_receipt"
    HEAD = "native_ownership_head"
    FIELDS = %w[
      format
      binding
      work
      receipt
      receipt_sha256
      baseline_command_id
      baseline_sha256
      native_revision
    ].sort.freeze
    HEAD_FIELDS = %w[
      format
      binding
      mapping_id
      key
      receipt_sha256
      generation
    ].sort.freeze
    SHA256 = /\A[a-f0-9]{64}\z/

    class Observation
      include ProtectedDiagnostics
      attr_reader :key, :value, :receipt

      def initialize(key:, value:, receipt:)
        @key, @value, @receipt = key.freeze, value, receipt
        freeze
      end
    end

    def initialize(context:, commands:, authority:, api_key:, factory: nil)
      unless context.is_a?(ExecutionContext) &&
               commands.is_a?(NativeCommandJournal) &&
               commands.context.equal?(context) &&
               authority.is_a?(WorkAuthority) && authority.bound_to?(context)
        raise Error.new("identity_conflict")
      end
      @context, @commands, @authority = context, commands, authority
      @installation, @protocol = context.installation, context.protocol
      @baselines =
        NativeBaselineJournal.new(context: context, journal: commands)
      @http =
        GhostHttp.new(
          protocol: @protocol,
          origin: @installation.native_target.admin_origin,
          api_key: api_key,
          guard: -> { current_authority! },
          factory: factory
        )
      @client = GhostAdminClient.new(http: @http)
    end

    def capture
      check!
      state = current_authority!
      mapping, work = state.values_at("mapping", "work")
      baseline = @baselines.current(mapping.fetch("mapping_id"))
      unless baseline &&
               baseline.value.dig("management", "stage") != "create_draft"
        raise Error.new("identity_conflict")
      end
      identity = baseline.value.fetch("identity")
      unless identity.slice("mapping_id", "resource_id", "external_id") ==
               mapping.slice("mapping_id", "resource_id", "external_id") &&
               (
                 @authority.initial_native_id.nil? ||
                   @authority.initial_native_id == identity.fetch("native_id")
               )
        raise Error.new("identity_conflict")
      end
      previous_head = checked_head(mapping.fetch("mapping_id"))
      command =
        @commands.retained(baseline.value.fetch("command_id")).fetch("command")
      maximum = command.dig("request", "maximum_bytes")
      native =
        @client.get(
          identity.fetch("native_id"),
          kind: identity.fetch("kind"),
          maximum_bytes: maximum
        )
      baseline.assert_current!(native)
      matches =
        @client.find_by_resource(
          identity.fetch("resource_id"),
          maximum_bytes: maximum
        )
      unless matches.length == 1 && matches.first["id"] == native.fetch("id") &&
               matches.first["type"] == native.fetch("type") &&
               matches.first["updated_at"] == native.fetch("updated_at")
        raise Error.new("identity_conflict")
      end
      baseline.assert_current!(matches.first)
      native = matches.first
      @protocol.validate!("Revision", native.fetch("updated_at"))
      # If Ghost reports a canonical URL, it cannot silently replace the owned
      # receiver reservation. Missing URL is not public verification either.
      if native.key?("url") &&
           native.fetch("url") != mapping.fetch("canonical_url")
        raise Error.new("identity_conflict")
      end
      unless current_authority!.slice("work", "mapping") ==
               state.slice("work", "mapping") &&
               @baselines.current(mapping.fetch("mapping_id"))&.sha256 ==
                 baseline.sha256
        raise Error.new("work_authority_unavailable")
      end
      receipt =
        OwnershipReceipt.new(
          {
            "schema_version" => "db-native-ownership-1",
            "forum_origin" => @context.binding.fetch("forum_origin"),
            "connection_id" => @installation.connection_public_id,
            "mapping_id" => mapping.fetch("mapping_id"),
            "resource_id" => mapping.fetch("resource_id"),
            "source_id" => mapping.fetch("source_id"),
            "external_id" => mapping.fetch("external_id"),
            "native_id" => identity.fetch("native_id"),
            "canonical_url" => mapping.fetch("canonical_url"),
            "source_revision" =>
              baseline.value.dig("fragment", "source_revision"),
            "last_lease_generation" => work.fetch("lease_generation"),
            "move_id" => nil,
            "proof_nonce" => nil
          },
          protocol: @protocol
        )
      value =
        snapshot(
          "format" => "ghost-native-ownership-1",
          "binding" => @context.binding,
          "work" => work,
          "receipt" => receipt.value,
          "receipt_sha256" => receipt.sha256,
          "baseline_command_id" => baseline.value.fetch("command_id"),
          "baseline_sha256" => baseline.sha256,
          "native_revision" => native.fetch("updated_at")
        )
      key = key_for(value)
      @context.commit do
        unless payload(HEAD, mapping.fetch("mapping_id")) == previous_head
          raise Error.new("identity_conflict")
        end
        if previous_head &&
             previous_head.fetch("generation") > work.fetch("lease_generation")
          raise Error.new("work_authority_unavailable")
        end
        existing = payload(ENTRY, key)
        raise Error.new("identity_conflict") if existing && existing != value
        write(ENTRY, key, mapping.fetch("mapping_id"), value) unless existing
        head = {
          "format" => "ghost-native-ownership-head-1",
          "binding" => @context.binding,
          "mapping_id" => mapping.fetch("mapping_id"),
          "key" => key,
          "receipt_sha256" => receipt.sha256,
          "generation" => work.fetch("lease_generation")
        }
        unless head == previous_head
          write(
            HEAD,
            mapping.fetch("mapping_id"),
            mapping.fetch("mapping_id"),
            head
          )
        end
      end
      retained(key)
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    # Historical data only: reading a retained receipt grants no permission and
    # cannot substitute for capture's fresh receiver/native checks.
    def latest(mapping_id)
      check!
      @protocol.validate!("UUID", mapping_id)
      head = checked_head(mapping_id)
      head && retained(head.fetch("key"))
    end

    def retained(key)
      check!
      value = payload(ENTRY, key)
      unless value.is_a?(Hash) && value.keys.sort == FIELDS &&
               value["format"] == "ghost-native-ownership-1" &&
               value["binding"] == @context.binding && key_for(value) == key
        raise Error.new("identity_conflict")
      end
      @protocol.validate!("Revision", value.fetch("native_revision"))
      receipt =
        OwnershipReceipt.new(value.fetch("receipt"), protocol: @protocol)
      work = value.fetch("work")
      @protocol.validate!("Work", work)
      baseline = @baselines.retained(value.fetch("baseline_command_id"))
      identity = baseline.value.fetch("identity")
      unless receipt.sha256 == value.fetch("receipt_sha256") &&
               baseline.sha256 == value.fetch("baseline_sha256") &&
               receipt.value.slice(
                 "mapping_id",
                 "resource_id",
                 "external_id",
                 "native_id"
               ) ==
                 identity.slice(
                   "mapping_id",
                   "resource_id",
                   "external_id",
                   "native_id"
                 ) &&
               receipt.value.fetch("source_revision") ==
                 baseline.value.dig("fragment", "source_revision") &&
               receipt.value.fetch("connection_id") ==
                 @installation.connection_public_id &&
               receipt.value.fetch("forum_origin") ==
                 @context.binding.fetch("forum_origin") &&
               baseline.value.dig("management", "stage") != "create_draft" &&
               receipt.value.fetch("move_id").nil? &&
               receipt.value.fetch("proof_nonce").nil? &&
               @protocol.url_origin_key(receipt.value.fetch("canonical_url")) ==
                 @protocol.origin_key(@context.binding.fetch("ghost_origin")) &&
               work.fetch("mapping_id") == receipt.value.fetch("mapping_id") &&
               work.fetch("source_id") == receipt.value.fetch("source_id") &&
               work.fetch("lease_generation") ==
                 receipt.value.fetch("last_lease_generation")
        raise Error.new("identity_conflict")
      end
      Observation.new(key: key.dup, value: snapshot(value), receipt: receipt)
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def check!
      @context.outside_transaction!
      @context.assert!
    end

    def current_authority!
      @authority.guard!(
        operation: :mutate,
        native_id: @authority.initial_native_id
      )
    end

    def checked_head(mapping_id)
      head = payload(HEAD, mapping_id)
      return unless head
      observed = retained(head.fetch("key"))
      unless observed.receipt.value.fetch("mapping_id") == mapping_id &&
               observed.receipt.sha256 == head.fetch("receipt_sha256") &&
               observed.receipt.value.fetch("last_lease_generation") ==
                 head.fetch("generation")
        raise Error.new("identity_conflict")
      end
      head
    end

    def key_for(value)
      Digest::SHA256.hexdigest(JSON.generate(value))
    end

    def payload(kind, key)
      row =
        @installation.operational_records.find_by(kind: kind, record_key: key)
      return unless row
      value = row.private_payload
      unless value.is_a?(Hash) && value["binding"] == @context.binding
        raise Error.new("identity_conflict")
      end
      if kind == HEAD
        unless value.keys.sort == HEAD_FIELDS &&
                 value["format"] == "ghost-native-ownership-head-1" &&
                 value["mapping_id"] == key && row.mapping_public_id == key &&
                 value["key"].is_a?(String) && SHA256.match?(value["key"]) &&
                 value["receipt_sha256"].is_a?(String) &&
                 SHA256.match?(value["receipt_sha256"]) &&
                 value["generation"].is_a?(Integer) &&
                 value["generation"].positive?
          raise Error.new("identity_conflict")
        end
        @protocol.validate!("UInt", value.fetch("generation"))
      elsif kind != ENTRY ||
            row.mapping_public_id != value.dig("receipt", "mapping_id")
        raise Error.new("identity_conflict")
      end
      value
    end

    def write(kind, key, mapping, value)
      encrypted =
        @installation.envelope.encrypt(
          "operational_record",
          value,
          binding: JSON.generate([kind, key])
        )
      row =
        @installation.operational_records.find_by(kind: kind, record_key: key)
      if row
        row.update!(encrypted_payload: encrypted)
      else
        @installation.operational_records.create!(
          kind: kind,
          record_key: key,
          mapping_public_id: mapping,
          encrypted_payload: encrypted
        )
      end
    end

    def snapshot(value)
      result =
        NativeDocument.parse(
          JSON.generate(value),
          maximum_bytes: WireProtocol::RESPONSE_MAXIMUM
        )
      freeze_value(result)
    end

    def freeze_value(value)
      case value
      when Hash
        value.each do |key, item|
          key.freeze
          freeze_value(item)
        end
      when Array
        value.each { |item| freeze_value(item) }
      end
      value.freeze
    end
  end
end
