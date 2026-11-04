# frozen_string_literal: true

require_relative "native_public_verifier"

module DiscussionBridgeGhost
  # Exact dynamic-stage requests are retained BEFORE dispatch. A lost reply
  # replays the original body/mutation ID; it never rotates a receipt or grants
  # a new native write. Resolving old work is explicitly historical.
  class NativeAcknowledgements
    include ProtectedDiagnostics

    ENTRY = "native_acknowledgement_intent"
    STAGES = { "synchronized" => "leased", "verified" => "synchronized" }.freeze
    FIELDS = %w[
      format
      binding
      work
      stage
      readiness_key
      readiness_sha256
      body_bytes
    ].sort.freeze

    class Outcome
      include ProtectedDiagnostics
      attr_reader :result, :observed, :historical

      def initialize(result:, observed:, historical:)
        @result, @observed, @historical = result, observed, historical
        freeze
      end
    end

    def initialize(
      context:,
      commands:,
      authority:,
      journal:,
      lease:,
      api_key:,
      factory: nil,
      now: -> { Time.now.utc }
    )
      unless context.is_a?(ExecutionContext) &&
               commands.is_a?(NativeCommandJournal) &&
               commands.context.equal?(context) &&
               authority.is_a?(WorkAuthority) && authority.bound_to?(context) &&
               journal.is_a?(MutationJournal) && journal.context.equal?(context)
        raise Error.new("identity_conflict")
      end
      @context, @commands, @authority, @journal, @api_key, @factory, @now =
        context,
        commands,
        authority,
        journal,
        api_key,
        factory,
        now
      @installation, @protocol = context.installation, context.protocol
      @protocol.validate!("Lease", lease)
      @identity =
        snapshot(lease.fetch("work").slice(*WorkAuthority::WORK_FIELDS))
      @lease_authority =
        snapshot(
          "work_id" => @identity.fetch("work_id"),
          "lease_token" => lease.fetch("lease_token"),
          "lease_generation" => lease.fetch("lease_generation"),
          "source_revision" => @identity.fetch("source_revision"),
          "policy_revision" => @identity.fetch("policy_revision")
        )
      @protocol.validate!("LeaseAuthority", @lease_authority)
    end

    def synchronize(event_id: nil)
      complete("synchronized", event_id)
    end

    def verify(event_id: nil)
      complete("verified", event_id)
    end

    private

    def complete(stage, event_id)
      @context.outside_transaction!
      @context.assert!
      previous = retained(stage)
      observed = query
      unless observed.fetch("work").slice(*WorkAuthority::WORK_FIELDS) ==
               @identity
        raise Error.new("identity_conflict")
      end
      if previous && observed.dig("work", "state") != STAGES.fetch(stage)
        # Resolve ONLY the original request through the receiver's idempotency
        # journal. This is history, not permission to verify/write anything new.
        result = dispatch(stage, previous)
        return Outcome.new(result: result, observed: query, historical: true)
      end
      unless observed.dig("work", "state") == STAGES.fetch(stage)
        raise Error.new("work_authority_unavailable")
      end
      sync = nil
      if stage == "verified"
        sync = retained("synchronized")
        raise Error.new("identity_conflict") unless sync
        prior = dispatch("synchronized", sync)
        unless prior.status == 200
          raise Error.new("acknowledgement_unavailable")
        end
      end
      readiness, verification = qualify(stage, event_id, sync)
      unless readiness.value.fetch("work").slice(*WorkAuthority::WORK_FIELDS) ==
               @identity
        raise Error.new("identity_conflict")
      end
      if previous
        old = readiness_reader.retained(previous.fetch("readiness_key"))
        # Ghost may edit a released field/unrelated card. Recheck desired state,
        # but preserve the exact genuine earlier native revision in the request.
        unless old.value.fetch("native_result").except("native_revision") ==
                 readiness
                   .value
                   .fetch("native_result")
                   .except("native_revision") &&
                 old.value.fetch("fragment_sha256") ==
                   readiness.value.fetch("fragment_sha256") &&
                 old.value.fetch("scope_revision") ==
                   readiness.value.fetch("scope_revision")
          raise Error.new("native_state_not_ready")
        end
        if stage == "verified"
          packet =
            @protocol.prepare(
              "V4-16",
              path: work_path,
              retained_body: previous.fetch("body_bytes")
            )
          old_proof =
            WireJson.parse(
              packet.body_bytes,
              maximum_bytes: WireProtocol::REQUEST_MAXIMUM
            ).fetch("verification")
          unless old_proof.except("checked_at") ==
                   verification.except("checked_at")
            raise Error.new("public_verification_failed")
          end
        end
      else
        body = {
          "mutation_id" => SecureRandom.uuid,
          "stage" => stage,
          "authority" => @lease_authority
        }
        if stage == "synchronized"
          body["native_result"] = readiness.value.fetch("native_result")
        else
          body["verification"] = verification
        end
        packet = @protocol.prepare("V4-16", path: work_path, body: body)
        value =
          snapshot(
            "format" => "ghost-native-acknowledgement-1",
            "binding" => @context.binding,
            "work" => @identity,
            "stage" => stage,
            "readiness_key" => readiness.key,
            "readiness_sha256" =>
              Digest::SHA256.hexdigest(JSON.generate(readiness.value)),
            "body_bytes" => packet.body_bytes
          )
        @context.commit do
          raise Error.new("identity_conflict") if row(stage)
          @installation.operational_records.create!(
            kind: ENTRY,
            record_key: key(stage),
            mapping_public_id: @identity.fetch("mapping_id"),
            encrypted_payload:
              @installation.envelope.encrypt(
                "operational_record",
                value,
                binding: JSON.generate([ENTRY, key(stage)])
              )
          )
        end
        # The exact packet and genuine readiness were checked while building
        # this immutable intent. A restart uses retained() and revalidates all
        # historical dependencies; this invocation keeps its actual value.
        previous = value
      end
      @authority.guard!(
        operation: stage == "synchronized" ? :mutate : :verify,
        native_id:
          (
            if stage == "synchronized"
              @authority.initial_native_id
            else
              readiness.value.dig("native_result", "native_id")
            end
          )
      )
      result = dispatch(stage, previous)
      after = query
      if result.status == 200
        expected_states =
          stage == "synchronized" ? %w[synchronized verified] : ["verified"]
        connection = @context.read("V4-01")
        unless expected_states.include?(after.dig("work", "state")) &&
                 after.fetch("work").slice(*WorkAuthority::WORK_FIELDS) ==
                   @identity &&
                 after.dig("mapping", "destination_native_id") ==
                   readiness.value.dig("native_result", "native_id") &&
                 after.fetch("mapping").slice(*WorkAuthority::MAPPING_FIELDS) ==
                   readiness
                     .value
                     .fetch("mapping")
                     .slice(*WorkAuthority::MAPPING_FIELDS) &&
                 connection.status == 200 &&
                 connection.value.fetch("scope_revision") ==
                   readiness.value.fetch("scope_revision") &&
                 connection.value.dig("policy", "enabled") &&
                 connection.value.dig("policy", "policy_revision") ==
                   @identity.fetch("policy_revision")
          raise Error.new("acknowledgement_not_current")
        end
      end
      Outcome.new(result: result, observed: after, historical: false)
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def qualify(stage, event_id, sync)
      if stage == "synchronized"
        checker = readiness_reader
        observation = checker.capture(event_id: event_id)
        unless checker.actual_evidence(observation) == observation.value
          raise Error.new("identity_conflict")
        end
        [observation, nil]
      else
        prior = readiness_reader.retained(sync.fetch("readiness_key"))
        verifier =
          NativePublicVerifier.new(
            context: @context,
            commands: @commands,
            authority: @authority,
            api_key: @api_key,
            factory: @factory,
            now: @now
          )
        observation =
          verifier.capture(
            event_id: event_id,
            prior_ownership_key: prior.value.fetch("ownership_key")
          )
        expected = {
          "readiness" => observation.readiness.value,
          "verification" => observation.verification
        }
        unless verifier.actual_evidence(observation) == expected
          raise Error.new("identity_conflict")
        end
        [observation.readiness, observation.verification]
      end
    end

    def readiness_reader
      NativeReadiness.new(
        context: @context,
        commands: @commands,
        authority: @authority,
        api_key: @api_key,
        factory: @factory
      )
    end

    def query
      result = @context.read("V4-14", path: work_path)
      raise Error.new("acknowledgement_unavailable") unless result.status == 200
      result.value
    end

    def dispatch(stage, value)
      @journal.call(
        "native-ack:#{key(stage)}",
        "V4-16",
        path: work_path,
        retained_body: value.fetch("body_bytes")
      )
    end

    def work_path
      { "work_id" => @identity.fetch("work_id") }
    end

    def key(stage)
      "#{@identity.fetch("work_id")}:#{@identity.fetch("lease_generation")}:#{stage}"
    end

    def row(stage)
      @installation.operational_records.find_by(
        kind: ENTRY,
        record_key: key(stage)
      )
    end

    def retained(stage)
      saved = row(stage)
      return unless saved
      value = snapshot(saved.private_payload)
      unless value.keys.sort == FIELDS &&
               value["format"] == "ghost-native-acknowledgement-1" &&
               value["binding"] == @context.binding &&
               value["work"] == @identity && value["stage"] == stage &&
               saved.mapping_public_id == @identity.fetch("mapping_id")
        raise Error.new("identity_conflict")
      end
      packet =
        @protocol.prepare(
          "V4-16",
          path: work_path,
          retained_body: value.fetch("body_bytes")
        )
      body =
        WireJson.parse(
          packet.body_bytes,
          maximum_bytes: WireProtocol::REQUEST_MAXIMUM
        )
      readiness = readiness_reader.retained(value.fetch("readiness_key"))
      unless readiness.value.fetch("work").slice(*WorkAuthority::WORK_FIELDS) ==
               @identity &&
               readiness.value.fetch("operation") ==
                 (stage == "synchronized" ? "mutate" : "verify") &&
               Digest::SHA256.hexdigest(JSON.generate(readiness.value)) ==
                 value.fetch("readiness_sha256") &&
               body.fetch("stage") == stage &&
               body.fetch("authority") == @lease_authority
        raise Error.new("identity_conflict")
      end
      if stage == "synchronized"
        unless body.fetch("native_result") ==
                 readiness.value.fetch("native_result")
          raise Error.new("identity_conflict")
        end
      else
        proof = body.fetch("verification")
        unless proof.fetch("url") ==
                 readiness.value.dig("mapping", "canonical_url") &&
                 proof.fetch("native_id") ==
                   readiness.value.dig("native_result", "native_id")
          raise Error.new("identity_conflict")
        end
        if readiness.value.dig("work", "action") == "publish_revision"
          unless proof.fetch("kind") == "published" &&
                   proof.fetch("source_revision") ==
                     readiness.value.dig("source", "source_revision") &&
                   proof.fetch("source_content_sha256") ==
                     readiness.value.dig("source", "content_sha256") &&
                   proof.fetch("native_publication_sha256") ==
                     readiness.value.fetch("fragment_sha256") &&
                   proof.fetch("verification_profile") ==
                     NativePublicVerifier::PROFILE &&
                   proof.fetch("representation") ==
                     readiness.value.dig("native_result", "representation")
            raise Error.new("identity_conflict")
          end
        elsif proof.fetch("kind") != "absent" ||
              ![404, 410].include?(proof.fetch("http_status"))
          raise Error.new("identity_conflict")
        end
      end
      value
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def snapshot(value)
      freeze_value(
        NativeDocument.parse(
          JSON.generate(value),
          maximum_bytes: WireProtocol::RESPONSE_MAXIMUM
        )
      )
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
