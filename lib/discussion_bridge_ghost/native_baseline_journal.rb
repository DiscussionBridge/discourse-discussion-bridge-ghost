# frozen_string_literal: true

require_relative "native_managed_baseline"

module DiscussionBridgeGhost
  # Protected last-PROVEN state, not receiver authority or a public receipt.
  # Immutable entries and the current head commit together, after the physical
  # command's separate durable handoff. A crash in between can finish this local
  # handoff without sending Ghost bytes again. Old replay never rewinds the head.
  class NativeBaselineJournal
    include ProtectedDiagnostics

    ENTRY = "native_managed_baseline"
    HEAD = "native_managed_head"
    ENTRY_FIELDS = %w[
      format
      binding
      mapping_id
      command_id
      root_command_id
      previous_command_id
      sequence
      baseline
      baseline_sha256
    ].sort.freeze
    HEAD_FIELDS = %w[
      format
      binding
      mapping_id
      command_id
      root_command_id
      sequence
      baseline_sha256
    ].sort.freeze
    HASH_PATTERN = /\A[a-f0-9]{64}\z/

    def initialize(context:, journal:)
      unless context.is_a?(ExecutionContext) &&
               journal.is_a?(NativeCommandJournal) &&
               journal.context.equal?(context)
        raise Error.new("identity_conflict")
      end
      @context, @commands, @installation =
        context,
        journal,
        context.installation
    end

    def current(mapping_id)
      current_state(mapping_id).first
    end

    def retained(command_id)
      check!
      entry = read_entry(command_id)
      _baseline, head_entry, = current_state(entry.fetch("mapping_id"))
      unless head_entry &&
               entry.fetch("root_command_id") ==
                 head_entry.fetch("root_command_id") &&
               entry.fetch("sequence") <= head_entry.fetch("sequence")
        raise Error.new("identity_conflict")
      end
      restore_entry(entry)
    end

    def remember(command_id)
      check!
      history = completed(command_id)
      command = history.fetch("command")
      mapping = command.dig("owner", "mapping_id")
      prior, prior_entry, head = current_state(mapping)
      return retained(command_id) if row(ENTRY, command_id)
      baseline =
        NativeManagedBaseline.from_completed(
          journal: @commands,
          command_id: command_id,
          previous: prior
        )
      entry =
        snapshot(
          "format" => "ghost-native-baseline-entry-1",
          "binding" => @context.binding,
          "mapping_id" => mapping,
          "command_id" => command_id,
          "root_command_id" =>
            prior_entry ? prior_entry.fetch("root_command_id") : command_id,
          "previous_command_id" => prior_entry&.fetch("command_id"),
          "sequence" => prior_entry ? prior_entry.fetch("sequence") + 1 : 1,
          "baseline" => baseline.value,
          "baseline_sha256" => baseline.sha256
        )
      validate_entry!(entry)
      @context.commit do
        current_head = row(HEAD, mapping)
        unless current_head&.private_payload == head && !row(ENTRY, command_id)
          raise Error.new("identity_conflict")
        end
        # No public journal reader, Rack call or HTTP operation in this short
        # transaction. The shared native-target lock covers the outside reads.
        create_record(ENTRY, command_id, mapping, entry)
        new_head = head_for(entry)
        if current_head
          current_head.update!(
            encrypted_payload: encrypt(HEAD, mapping, new_head)
          )
        else
          create_record(HEAD, mapping, mapping, new_head)
        end
      end
      baseline
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    # Call after current direction-specific authority and BEFORE native writes.
    # A fresh CAS snapshot alone cannot replace the last proven managed state:
    # it could already contain an editor's changes to owned content/metadata.
    def assert_before_write!(command, native: nil)
      check!
      original =
        @commands.retained(command.fetch("command_id")).fetch("command")
      raise Error.new("identity_conflict") unless original == command
      previous = current(command.dig("owner", "mapping_id"))
      if command.dig("owner", "action") == "create_draft"
        raise Error.new("identity_conflict") if previous || native
      else
        unless previous && native &&
                 previous.value.fetch("identity") ==
                   identity_for(command, native.fetch("id"))
          raise Error.new("identity_conflict")
        end
        management =
          NativeManagement.new(
            protocol: @context.protocol,
            value: command.fetch("candidate").fetch("management")
          )
        management.validate_command!(command)
        released =
          previous.released_relations(
            journal: @commands,
            through_generation: command.dig("owner", "generation")
          )
        previous.assert_current!(
          command.fetch("baseline"),
          management: management,
          released_relations: released
        )
        previous.assert_current!(
          native,
          management: management,
          released_relations: released
        )
      end
      @context.assert!
      true
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def check!
      @context.outside_transaction!
      @context.assert!
    end

    def current_state(mapping)
      check!
      uuid!(mapping)
      if @installation
           .operational_records
           .where(kind: ENTRY, mapping_public_id: nil)
           .exists?
        raise Error.new("identity_conflict")
      end
      head_row = row(HEAD, mapping)
      unless head_row
        if @installation
             .operational_records
             .where(kind: ENTRY, mapping_public_id: mapping)
             .exists?
          raise Error.new("identity_conflict")
        end
        return nil, nil, nil
      end
      head = snapshot(head_row.private_payload)
      unless head_row.mapping_public_id == mapping && head.is_a?(Hash) &&
               head.keys.sort == HEAD_FIELDS &&
               head["format"] == "ghost-native-baseline-head-1" &&
               head["binding"] == @context.binding &&
               head["mapping_id"] == mapping
        raise Error.new("identity_conflict")
      end
      entry = read_entry(head.fetch("command_id"))
      raise Error.new("identity_conflict") unless head == head_for(entry)
      [restore_entry(entry), entry, head]
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def read_entry(command_id)
      uuid!(command_id)
      saved = row(ENTRY, command_id)
      raise Error.new("identity_conflict") unless saved
      entry = snapshot(saved.private_payload)
      validate_entry!(entry)
      unless entry.fetch("command_id") == command_id &&
               saved.mapping_public_id == entry.fetch("mapping_id")
        raise Error.new("identity_conflict")
      end
      entry
    end

    def validate_entry!(entry)
      unless entry.is_a?(Hash) && entry.keys.sort == ENTRY_FIELDS &&
               entry["format"] == "ghost-native-baseline-entry-1" &&
               entry["binding"] == @context.binding
        raise Error.new("identity_conflict")
      end
      %w[mapping_id command_id root_command_id].each do |key|
        uuid!(entry.fetch(key))
      end
      sequence = entry.fetch("sequence")
      unless sequence.is_a?(Integer) && sequence.positive? &&
               entry.fetch("baseline").is_a?(Hash) &&
               entry["baseline_sha256"].is_a?(String) &&
               HASH_PATTERN.match?(entry["baseline_sha256"]) &&
               Digest::SHA256.hexdigest(
                 JSON.generate(entry.fetch("baseline"))
               ) == entry["baseline_sha256"] &&
               entry.dig("baseline", "command_id") == entry["command_id"] &&
               entry.dig("baseline", "binding") == entry["binding"] &&
               entry.dig("baseline", "identity", "mapping_id") ==
                 entry["mapping_id"]
        raise Error.new("identity_conflict")
      end
      if sequence == 1
        unless entry["root_command_id"] == entry["command_id"] &&
                 entry["previous_command_id"].nil? &&
                 entry.dig("baseline", "previous_sha256").nil?
          raise Error.new("identity_conflict")
        end
      else
        uuid!(entry.fetch("previous_command_id"))
        unless entry.dig("baseline", "previous_sha256").is_a?(String) &&
                 HASH_PATTERN.match?(entry.dig("baseline", "previous_sha256"))
          raise Error.new("identity_conflict")
        end
      end
      true
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    def restore_entry(entry)
      # Constant-size dependency set, not an ever-growing recursive replay of
      # every previous article revision. Protected entries attest enrollment;
      # actual root/current/content completions independently rebuild the value.
      root =
        NativeManagedBaseline.from_completed(
          journal: @commands,
          command_id: entry.fetch("root_command_id")
        )
      unless root.value.fetch("identity") == entry.dig("baseline", "identity")
        raise Error.new("identity_conflict")
      end
      current = project_entry(entry)
      if entry.fetch("sequence") == 1 && current.value == root.value
        return current
      end
      previous = read_entry(entry.fetch("previous_command_id"))
      unless previous.fetch("sequence") + 1 == entry.fetch("sequence") &&
               previous.fetch("root_command_id") ==
                 entry.fetch("root_command_id") &&
               previous.fetch("mapping_id") == entry.fetch("mapping_id") &&
               previous.fetch("baseline_sha256") ==
                 entry.dig("baseline", "previous_sha256")
        raise Error.new("identity_conflict")
      end
      prior = project_entry(previous)
      rebuilt =
        NativeManagedBaseline.from_completed(
          journal: @commands,
          command_id: entry.fetch("command_id"),
          previous: prior,
          before_record_id: enrollment_record_id(entry)
        )
      raise Error.new("identity_conflict") unless rebuilt.value == current.value
      current
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def project_entry(entry)
      latest = completed(entry.fetch("command_id"))
      previous_value = nil
      if latest.dig("command", "owner", "action") == "withdraw"
        # A prior release can survive more than one status-only command. Read
        # its authenticated predecessor projection, not today's selection and
        # not a recursive traversal of every historical article revision.
        predecessor = read_entry(entry.fetch("previous_command_id"))
        unless predecessor.fetch("root_command_id") ==
                 entry.fetch("root_command_id") &&
                 predecessor.fetch("mapping_id") == entry.fetch("mapping_id") &&
                 predecessor.fetch("sequence") + 1 == entry.fetch("sequence") &&
                 predecessor.fetch("baseline_sha256") ==
                   entry.dig("baseline", "previous_sha256")
          raise Error.new("identity_conflict")
        end
        previous_value = predecessor.fetch("baseline")
      end
      content_id = entry.fetch("baseline").fetch("content_command_id")
      if content_id == entry.fetch("command_id")
        content = latest
      else
        content_entry = read_entry(content_id)
        unless content_entry.fetch("root_command_id") ==
                 entry.fetch("root_command_id") &&
                 content_entry.fetch("sequence") < entry.fetch("sequence") &&
                 content_entry.dig("baseline", "identity") ==
                   entry.dig("baseline", "identity")
          raise Error.new("identity_conflict")
        end
        content = completed(content_id)
      end
      NativeManagedBaseline.send(
        :restore,
        protocol: @context.protocol,
        command: latest.fetch("command"),
        completion: latest.dig("state", "completion"),
        content_command: content.fetch("command"),
        content_completion: content.dig("state", "completion"),
        previous_value: previous_value,
        released_relations:
          (
            if previous_value
              NativeManagedBaseline.release_history(
                journal: @commands,
                value: previous_value,
                through_generation:
                  latest.dig("command", "owner", "generation"),
                before_record_id: enrollment_record_id(entry)
              )
            else
              []
            end
          ),
        value: entry.fetch("baseline")
      )
    end

    # Immutable causal boundary for this exact enrolled projection, not today's
    # policy or a caller-selected wall clock. Native-target exclusion serializes
    # release observations and enrollment. This preserves legacy projections
    # even when a valid observation followed preparation but preceded enrollment.
    def enrollment_record_id(entry)
      saved = row(ENTRY, entry.fetch("command_id"))
      unless saved && saved.id.is_a?(Integer) && saved.id.positive? &&
               saved.mapping_public_id == entry.fetch("mapping_id") &&
               saved.private_payload == entry
        raise Error.new("identity_conflict")
      end
      saved.id
    end

    def completed(command_id)
      value = @commands.retained(command_id)
      unless value.dig("state", "completion") &&
               value.dig("command", "binding") == @context.binding
        raise Error.new("identity_conflict")
      end
      value
    end

    def identity_for(command, native_id)
      {
        "mapping_id" => command.dig("owner", "mapping_id"),
        "external_id" => command.dig("owner", "external_id"),
        "resource_id" => command.dig("identity", "resource_id"),
        "native_id" => native_id,
        "kind" => command.dig("identity", "kind")
      }
    end

    def head_for(entry)
      entry.slice(*HEAD_FIELDS).merge(
        "format" => "ghost-native-baseline-head-1"
      )
    end

    def row(kind, key)
      @installation.operational_records.find_by(kind: kind, record_key: key)
    end

    def encrypt(kind, key, value)
      @installation.envelope.encrypt(
        "operational_record",
        value,
        binding: JSON.generate([kind, key])
      )
    end

    def create_record(kind, key, mapping, value)
      @installation.operational_records.create!(
        kind: kind,
        record_key: key,
        mapping_public_id: mapping,
        encrypted_payload: encrypt(kind, key, value)
      )
    end

    def uuid!(value)
      unless value.is_a?(String) && SecretEnvelope::UUID.match?(value)
        raise Error.new("identity_conflict")
      end
    end

    def snapshot(value)
      NativeDocument.parse(
        JSON.generate(value),
        maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES
      )
    rescue JSON::GeneratorError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end
  end
end
