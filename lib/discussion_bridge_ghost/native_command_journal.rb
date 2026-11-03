# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"
require "time"
require_relative "native_effect_verifier"

module DiscussionBridgeGhost
  # Local safety bookkeeping, NOT an effect executor or an ownership verifier.
  # No method sends HTTP or acknowledges receiver work. Physical completion
  # requires the actual verifier's original response and complete native proof.
  # An unresolved command blocks BOTH directions, including after a new work ID
  # or installation is selected for the same target. A later verifier must supply
  # a separately reviewed positive-completion path; observations alone cannot
  # release this barrier. There is deliberately no generic reset/resolve switch.
  class NativeCommandJournal
    include ProtectedDiagnostics

    MAXIMUM_BYTES = 33_554_432
    OWNER_FIELDS = %w[
      direction
      action
      mapping_id
      work_id
      generation
      source_revision
      external_id
      move_id
      proof_nonce
    ].sort.freeze
    IDENTITY_FIELDS = %w[resource_id kind native_id].sort.freeze
    REQUEST_FIELDS = %w[
      method
      path
      body_bytes
      maximum_bytes
      allowed_statuses
    ].sort.freeze
    COMMAND_FIELDS = %w[
      format
      binding
      command_id
      created_at
      identity
      owner
      request
      baseline
      candidate
      claims
    ].sort.freeze
    EVENT_FIELDS = %w[
      format
      binding
      command_id
      command_sha256
      sequence
      previous_sha256
      observer_execution_id
      observed_at
      kind
      value
    ].sort.freeze

    attr_reader :context

    def initialize(context:, now: -> { Time.now.utc })
      unless context.is_a?(ExecutionContext)
        raise Error.new("identity_conflict")
      end
      @context, @installation, @protocol, @now =
        context,
        context.installation,
        context.protocol,
        now
      @binding = context.binding
      @attempt_http = {}
    end

    # Retain exact bytes, complete baseline/candidate and original directional
    # provenance before an attempt. Reopening an ID never replaces its intent.
    def prepare(command_id:, identity:, owner:, request:, baseline:, candidate:)
      uuid!(command_id)
      command =
        snapshot(
          "format" => "ghost-native-command-1",
          "binding" => @binding,
          "command_id" => command_id,
          "created_at" => timestamp,
          "identity" => identity,
          "owner" => owner,
          "request" => request,
          "baseline" => baseline,
          "candidate" => candidate,
          "claims" => []
        )
      command = snapshot(command.merge("claims" => claims_for(command)))
      validate_command!(command, command_id)
      @context.commit do
        old = record("native_command", command_id)
        if old
          retained, = load_state(command_id)
          unless retained.except("created_at") == command.except("created_at")
            raise Error.new("identity_conflict")
          end
          next retained
        end
        if record("native_progress", command_id) ||
             @installation
               .operational_records
               .where(kind: "native_event")
               .where("record_key LIKE ?", "#{command_id}:%")
               .exists?
          raise Error.new("identity_conflict")
        end
        assert_claims_clear!(command.fetch("claims"))
        create_record("native_command", command_id, command)
        create_record("native_progress", command_id, initial_state(command))
        command
          .fetch("claims")
          .each do |claim|
            create_record(
              "native_barrier",
              claim,
              {
                "format" => "ghost-native-barrier-1",
                "binding" => @binding,
                "command_id" => command_id,
                "claim" => claim
              }
            )
          end
        command
      end
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    # This is a DURABLE dispatch-started record, not proof that bytes were sent.
    # The caller must obtain CURRENT direction-specific authority immediately
    # before effects. From WorkAuthority cannot authorize a To source move.
    # A crash after this commit is UNKNOWN until actual evidence is retained.
    def begin_attempt(command_id, http:)
      unless http.is_a?(GhostHttp) &&
               http.bound_origin?(
                 protocol: @protocol,
                 origin: @installation.native_target.admin_origin
               )
        raise Error.new("identity_conflict")
      end
      attempt =
        @context.commit do
          command, state = load_state(command_id)
          if state.fetch("pending_attempt") || state["completion"]
            raise Error.new("identity_conflict")
          end
          identity = {
            "command_id" => command_id,
            "attempt_id" => SecureRandom.uuid,
            "execution_id" => @context.execution_id
          }
          append(command, state, "attempt_started", identity)
          snapshot(identity)
        end
      @attempt_http[attempt.fetch("attempt_id")] = http
      attempt
    end

    # A process-local result must come from THIS HTTP instance, command,
    # execution, attempt, origin, method, path and exact bytes. Once request was
    # entered, even a received 2xx or 429 is NOT permission to repeat the write.
    # Lost authority/lock or failed receipt commit leaves the started attempt
    # uncertain. Never manufacture no-send from a caller exception or status.
    def retain_dispatch(command_id, attempt:, http:, outcome:)
      @context.commit do
        command, state = load_state(command_id)
        unless attempt.is_a?(Hash) &&
                 attempt == state.fetch("pending_attempt") &&
                 attempt["execution_id"] == @context.execution_id &&
                 @attempt_http[attempt["attempt_id"]].equal?(http) &&
                 !state.fetch("dispatch_recorded") && http.is_a?(GhostHttp) &&
                 http.bound_origin?(
                   protocol: @protocol,
                   origin: @installation.native_target.admin_origin
                 )
          raise Error.new("identity_conflict")
        end
        proof = http.actual_dispatch_evidence(outcome, dispatch: attempt)
        expected = {
          "format" => "ghost-http-dispatch-1",
          "dispatch" => attempt,
          "origin" =>
            @protocol.origin_key(@installation.native_target.admin_origin),
          "method" => command.dig("request", "method"),
          "path" => command.dig("request", "path"),
          "body_sha256" =>
            Digest::SHA256.hexdigest(command.dig("request", "body_bytes"))
        }
        unless proof && proof.value.except("phase") == expected &&
                 %w[not_sent may_have_sent response_received].include?(
                   proof.value["phase"]
                 )
          raise Error.new("identity_conflict")
        end
        response = proof.response
        value = {
          "dispatch" => proof.value,
          "response" =>
            response &&
              {
                "status" => response.status,
                "headers" => response.headers,
                # Preserve malformed/non-UTF8 native replies without interpreting
                # them or allowing binary content into a diagnostic.
                "body_base64" => Base64.strict_encode64(response.bytes)
              }
        }
        append(command, state, "dispatch_observed", value)
        snapshot(value)
      end
    end

    # Later discovery is retained as observation only. Equal candidates, private
    # drafts, empty lookups or matching source hashes do NOT prove that a delayed
    # earlier request cannot still arrive. No state release is derived here.
    def observe(command_id, value)
      retained = snapshot(value)
      raise Error.new("identity_conflict") unless retained.is_a?(Hash)
      @context.commit do
        command, state = load_state(command_id)
        append(command, state, "native_observed", retained)
      end
    end

    def retained(command_id)
      @context.outside_transaction!
      @context.assert!
      command, state, response = load_state(command_id)
      snapshot("command" => command, "state" => state, "response" => response)
    end

    # The immutable original command remains terminal forever. Remove only its
    # temporary exclusion rows after a checked terminal event is committed in
    # the SAME transaction. Ownership and URL reservations are not these rows.
    # Replaying an old completed ID cannot reconstruct or re-execute its write.
    def retain_completion(command_id, verifier:, evidence:)
      unless verifier.is_a?(NativeEffectVerifier) &&
               verifier.context.equal?(@context)
        raise Error.new("identity_conflict")
      end
      value = verifier.actual_evidence(evidence)
      raise Error.new("identity_conflict") unless value
      @context.commit do
        command, state, response = load_state(command_id)
        raise Error.new("identity_conflict") if state["completion"]
        validate_completion!(command, state, response, value)
        # A draft create discovers an alias not present in original intent.
        # Acquire it before recording completion; keep original native_id=nil.
        native_claim = "native:#{value.fetch("native_id")}"
        extra =
          command.fetch("claims").include?(native_claim) ? [] : [native_claim]
        assert_claims_clear!(extra) unless extra.empty?
        extra.each do |claim|
          create_record(
            "native_barrier",
            claim,
            {
              "format" => "ghost-native-barrier-1",
              "binding" => @binding,
              "command_id" => command_id,
              "claim" => claim
            }
          )
        end
        completion =
          snapshot(
            value.merge(
              "released_claims" => (command.fetch("claims") + extra).sort
            )
          )
        append(command, state, "effect_completed", completion)
        rows =
          @installation.operational_records.where(
            kind: "native_barrier",
            record_key: completion.fetch("released_claims")
          )
        unless rows.count == completion.fetch("released_claims").length &&
                 rows.all? { |row|
                   row.private_payload["command_id"] == command_id
                 }
          raise Error.new("identity_conflict")
        end
        rows.delete_all
        completion
      end
    end

    # Ordinary To delivery/move writers must also consult this shared barrier.
    # No direction-specific authority is granted by finding the barrier clear.
    def assert_clear!(resource_id:, kind:, native_id:, slugs:)
      @context.outside_transaction!
      @context.assert!
      identity = {
        "resource_id" => resource_id,
        "kind" => kind,
        "native_id" => native_id
      }
      validate_identity!(identity)
      assert_claims_clear!(identity_claims(identity, slugs))
      true
    end

    private

    def uuid!(value)
      unless value.is_a?(String) && SecretEnvelope::UUID.match?(value)
        raise Error.new("identity_conflict")
      end
    end

    def timestamp
      @now.call.utc.iso8601(6)
    end

    def snapshot(value)
      bytes = JSON.generate(value)
      raise Error.new("identity_conflict") if bytes.bytesize > MAXIMUM_BYTES
      parsed = JSON.parse(bytes, object_class: WireJson::StrictObject)
      freeze_value(parsed)
    rescue JSON::ParserError, JSON::GeneratorError, EncodingError, ArgumentError
      raise Error.new("identity_conflict"), cause: nil
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
      when Float
        raise Error.new("identity_conflict") unless value.finite?
      end
      value.freeze
    end

    def validate_identity!(identity)
      valid_identity =
        identity.is_a?(Hash) && identity.keys.sort == IDENTITY_FIELDS &&
          %w[post page].include?(identity["kind"]) &&
          (
            identity["native_id"].nil? ||
              (
                identity["native_id"].is_a?(String) &&
                  /\A[a-f0-9]{24}\z/.match?(identity["native_id"])
              )
          )
      raise Error.new("identity_conflict") unless valid_identity
      uuid!(identity["resource_id"])
    end

    def validate_command!(command, id)
      unless command.is_a?(Hash) && command.keys.sort == COMMAND_FIELDS &&
               command["format"] == "ghost-native-command-1" &&
               command["binding"] == @binding && command["command_id"] == id
        raise Error.new("identity_conflict")
      end
      uuid!(id)
      Time.iso8601(command.fetch("created_at"))
      identity = command.fetch("identity")
      validate_identity!(identity)
      owner, request = command.values_at("owner", "request")
      unless owner.is_a?(Hash) && owner.keys.sort == OWNER_FIELDS &&
               %w[from_discourse to_discourse].include?(owner["direction"]) &&
               %w[create_draft publish withdraw source_move].include?(
                 owner["action"]
               ) && request.is_a?(Hash) && request.keys.sort == REQUEST_FIELDS
        raise Error.new("identity_conflict")
      end
      @protocol.validate!("OpaqueId", owner.fetch("external_id"))
      if owner["direction"] == "from_discourse"
        uuid!(owner["mapping_id"])
        uuid!(owner["work_id"])
        unless owner["generation"].is_a?(Integer) &&
                 owner["generation"].between?(1, WireJson::MAX_COUNTER) &&
                 owner["action"] != "source_move"
          raise Error.new("identity_conflict")
        end
        if owner["action"] == "withdraw"
          unless owner["source_revision"].nil? && owner["move_id"].nil? &&
                   owner["proof_nonce"].nil?
            raise Error.new("identity_conflict")
          end
        else
          @protocol.validate!("Revision", owner.fetch("source_revision"))
          if owner["move_id"].nil?
            unless owner["proof_nonce"].nil?
              raise Error.new("identity_conflict")
            end
          else
            unless owner["action"] == "publish" && identity["native_id"]
              raise Error.new("identity_conflict")
            end
            @protocol.validate!("UUID", owner.fetch("move_id"))
            @protocol.validate!("PublicNonce", owner.fetch("proof_nonce"))
          end
        end
      else
        @protocol.validate!("UUID", owner.fetch("move_id"))
        @protocol.validate!("PublicNonce", owner.fetch("proof_nonce"))
        @protocol.validate!("Revision", owner.fetch("source_revision"))
        unless owner["mapping_id"].nil? && owner["work_id"].nil? &&
                 owner["generation"].is_a?(Integer) &&
                 owner["generation"] == 0 && owner["action"] == "source_move"
          raise Error.new("identity_conflict")
        end
      end
      create = owner["action"] == "create_draft"
      # A From slug change is presentation URL management, not an ordinary
      # publication update. Keep its actual move and proof nonce; this retains
      # provenance only and does not authorize the URL move or its ACK.
      if !create && owner["direction"] == "from_discourse" &&
           command.dig("baseline", "slug") !=
             command.dig("candidate", "slug") && owner["move_id"].nil?
        raise Error.new("identity_conflict")
      end
      path = "/ghost/api/admin/#{identity.fetch("kind")}s/"
      path += "#{identity.fetch("native_id")}/" unless create
      unless request["method"] == (create ? "POST" : "PUT") &&
               request["path"] == path &&
               (
                 if create
                   identity["native_id"].nil?
                 else
                   !identity["native_id"].nil?
                 end
               ) && request["body_bytes"].is_a?(String) &&
               request["maximum_bytes"].is_a?(Integer) &&
               request["maximum_bytes"].between?(1, MAXIMUM_BYTES) &&
               request["allowed_statuses"] == (create ? [201] : [200]) &&
               command["candidate"].is_a?(Hash) &&
               (
                 if create
                   command["baseline"].nil?
                 else
                   command["baseline"].is_a?(Hash)
                 end
               )
        raise Error.new("identity_conflict")
      end
      raw = request.fetch("body_bytes")
      unless raw.valid_encoding? && raw.encoding == Encoding::UTF_8 &&
               !raw.start_with?("\uFEFF")
        raise Error.new("identity_conflict")
      end
      body = JSON.parse(raw, object_class: WireJson::StrictObject)
      type = "#{identity.fetch("kind")}s"
      unless body.is_a?(Hash) && body.keys == [type] &&
               body[type].is_a?(Array) && body[type].size == 1 &&
               body[type].first.is_a?(Hash)
        raise Error.new("identity_conflict")
      end
      fields = body[type].first
      if fields.key?("slug") &&
           fields["slug"] != command.dig("candidate", "slug")
        raise Error.new("identity_conflict")
      end
      if create
        unless fields["status"] == "draft" && !fields.key?("id") &&
                 fields.key?("slug")
          raise Error.new("identity_conflict")
        end
      else
        baseline = command.fetch("baseline")
        unless baseline["id"] == identity["native_id"] &&
                 fields["id"] == identity["native_id"] &&
                 fields["updated_at"].is_a?(String) &&
                 fields["updated_at"] == baseline["updated_at"]
          raise Error.new("identity_conflict")
        end
        expected = { "publish" => "published", "withdraw" => "draft" }
        if owner["action"] == "source_move"
          unless (
                   fields.keys - %w[id slug updated_at codeinjection_head]
                 ).empty?
            raise Error.new("identity_conflict")
          end
        elsif fields["status"] != expected.fetch(owner["action"])
          raise Error.new("identity_conflict")
        end
      end
      unless command["claims"] == claims_for(command)
        raise Error.new("identity_conflict")
      end
      true
    rescue KeyError, ArgumentError, TypeError, JSON::ParserError
      raise Error.new("identity_conflict"), cause: nil
    end

    def identity_claims(identity, slugs)
      unless slugs.is_a?(Array) && slugs.size.between?(1, 2) &&
               slugs.all? { |slug|
                 slug.is_a?(String) && slug.bytesize.between?(1, 191) &&
                   /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.match?(slug)
               }
        raise Error.new("identity_conflict")
      end
      claims = ["resource:#{identity.fetch("resource_id")}"]
      claims << "native:#{identity.fetch("native_id")}" if identity["native_id"]
      # Slugs collide across posts/pages. This also protects the pre-ID create.
      claims.concat(slugs.uniq.map { |slug| "slug:#{slug}" }).sort
    end

    def claims_for(command)
      validate_identity!(command.fetch("identity"))
      baseline = command.fetch("baseline")
      candidate = command.fetch("candidate")
      valid_context =
        candidate.is_a?(Hash) && (baseline.nil? || baseline.is_a?(Hash))
      raise Error.new("identity_conflict") unless valid_context
      slugs = [baseline && baseline["slug"], candidate["slug"]].compact.uniq
      identity_claims(command.fetch("identity"), slugs)
    end

    def assert_claims_clear!(claims)
      installations =
        Installation.where(
          native_target_id: @installation.native_target_id
        ).select(:id)
      scope =
        OperationalRecord.where(
          installation_id: installations,
          kind: "native_barrier",
          record_key: claims
        )
      raise Error.new("identity_conflict") if scope.exists?
    end

    def record(kind, key)
      @installation.operational_records.find_by(kind: kind, record_key: key)
    end

    def create_record(kind, key, value)
      @installation.operational_records.create!(
        kind: kind,
        record_key: key,
        encrypted_payload:
          @installation.envelope.encrypt(
            "operational_record",
            value,
            binding: JSON.generate([kind, key])
          )
      )
    end

    def initial_state(command)
      {
        "format" => "ghost-native-progress-1",
        "binding" => @binding,
        "command_id" => command.fetch("command_id"),
        "command_sha256" => Digest::SHA256.hexdigest(JSON.generate(command)),
        "event_count" => 0,
        "last_event_sha256" => nil,
        "pending_attempt" => nil,
        "dispatch_recorded" => false
      }
    end

    def load_state(command_id)
      uuid!(command_id)
      command = record("native_command", command_id)&.private_payload
      validate_command!(command, command_id)
      state = initial_state(command)
      response = nil
      @installation
        .operational_records
        .where(kind: "native_event")
        .where("record_key LIKE ?", "#{command_id}:%")
        .find_each(batch_size: 50) do |row|
          event = row.private_payload
          sequence = state.fetch("event_count") + 1
          unless row.record_key == event_key(command_id, sequence) &&
                   event.is_a?(Hash) && event.keys.sort == EVENT_FIELDS &&
                   event["format"] == "ghost-native-event-1" &&
                   event["binding"] == @binding &&
                   event["command_id"] == command_id &&
                   event["command_sha256"] == state.fetch("command_sha256") &&
                   event["sequence"].is_a?(Integer) &&
                   event["sequence"] == sequence &&
                   event["previous_sha256"] == state.fetch("last_event_sha256")
            raise Error.new("identity_conflict")
          end
          uuid!(event["observer_execution_id"])
          Time.iso8601(event.fetch("observed_at"))
          if event["kind"] == "effect_completed"
            unless event["value"].is_a?(Hash)
              raise Error.new("identity_conflict")
            end
            validate_completion!(
              command,
              state,
              response,
              event.fetch("value").except("released_claims")
            )
          end
          apply_event(state, event, command)
          if event["kind"] == "attempt_started"
            response = nil
          elsif event["kind"] == "dispatch_observed"
            response = event.dig("value", "response")
          end
          state["event_count"] = sequence
          state["last_event_sha256"] = Digest::SHA256.hexdigest(
            JSON.generate(event)
          )
        end
      unless state["completion"]
        barriers =
          @installation.operational_records.where(
            kind: "native_barrier",
            record_key: command.fetch("claims")
          )
        unless barriers.count == command.fetch("claims").length &&
                 barriers.all? { |row|
                   row.private_payload ==
                     {
                       "format" => "ghost-native-barrier-1",
                       "binding" => @binding,
                       "command_id" => command_id,
                       "claim" => row.record_key
                     }
                 }
          raise Error.new("identity_conflict")
        end
      end
      progress = record("native_progress", command_id)
      stored = progress&.private_payload
      unless stored.is_a?(Hash) && stored == state &&
               stored["event_count"].is_a?(Integer)
        raise Error.new("identity_conflict")
      end
      [snapshot(command), state, response]
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def apply_event(state, event, command)
      raise Error.new("identity_conflict") if state["completion"]
      value = event.fetch("value")
      case event.fetch("kind")
      when "attempt_started"
        unless state["pending_attempt"].nil? && value.is_a?(Hash) &&
                 value.keys.sort == %w[attempt_id command_id execution_id] &&
                 value["command_id"] == state.fetch("command_id") &&
                 value["execution_id"] == event.fetch("observer_execution_id")
          raise Error.new("identity_conflict")
        end
        value.each_value { |id| uuid!(id) }
        state["pending_attempt"] = value
        state["dispatch_recorded"] = false
      when "dispatch_observed"
        unless value.is_a?(Hash) && value.keys.sort == %w[dispatch response]
          raise Error.new("identity_conflict")
        end
        dispatch = value.fetch("dispatch")
        unless state["pending_attempt"] && !state["dispatch_recorded"] &&
                 dispatch.is_a?(Hash) &&
                 dispatch.except("phase") ==
                   {
                     "format" => "ghost-http-dispatch-1",
                     "dispatch" => state.fetch("pending_attempt"),
                     "origin" =>
                       @protocol.origin_key(
                         @installation.native_target.admin_origin
                       ),
                     "method" => command.dig("request", "method"),
                     "path" => command.dig("request", "path"),
                     "body_sha256" =>
                       Digest::SHA256.hexdigest(
                         command.dig("request", "body_bytes")
                       )
                   } &&
                 dispatch["dispatch"] == state.fetch("pending_attempt") &&
                 dispatch.dig("dispatch", "execution_id") ==
                   event.fetch("observer_execution_id") &&
                 %w[not_sent may_have_sent response_received].include?(
                   dispatch["phase"]
                 )
          raise Error.new("identity_conflict")
        end
        if dispatch["phase"] == "not_sent"
          raise Error.new("identity_conflict") unless value["response"].nil?
          state["pending_attempt"] = nil
          state["dispatch_recorded"] = false
        else
          if dispatch["phase"] == "response_received"
            response = value["response"]
            valid_response =
              response.is_a?(Hash) &&
                response.keys.sort == %w[body_base64 headers status] &&
                response["status"].is_a?(Integer) &&
                command.dig("request", "allowed_statuses").include?(
                  response["status"]
                ) && response["headers"].is_a?(Hash) &&
                response["headers"].keys.sort ==
                  %w[content-encoding content-type location retry-after] &&
                response["headers"].values.all? do |header|
                  header.nil? || header.is_a?(String)
                end && response["body_base64"].is_a?(String)
            raise Error.new("identity_conflict") unless valid_response
            bytes = Base64.strict_decode64(response.fetch("body_base64"))
            if bytes.bytesize > command.dig("request", "maximum_bytes")
              raise Error.new("identity_conflict")
            end
          elsif !value["response"].nil?
            raise Error.new("identity_conflict")
          end
          state["dispatch_recorded"] = true
        end
      when "native_observed"
        raise Error.new("identity_conflict") unless value.is_a?(Hash)
      when "effect_completed"
        expected_claims =
          (
            command.fetch("claims") + ["native:#{value.fetch("native_id")}"]
          ).uniq.sort
        unless value.fetch("released_claims") == expected_claims
          raise Error.new("identity_conflict")
        end
        state["completion"] = value
      else
        raise Error.new("identity_conflict")
      end
    end

    def validate_completion!(command, state, response, value)
      fields = %w[
        format
        binding
        command_id
        command_sha256
        response_sha256
        native_id
        kind
        native
      ].sort
      unless state.fetch("pending_attempt") &&
               state.fetch("dispatch_recorded") && response &&
               value.is_a?(Hash) && value.keys.sort == fields &&
               value["format"] == "ghost-native-effect-1" &&
               value["binding"] == @binding &&
               value["command_id"] == command.fetch("command_id") &&
               value["command_sha256"] == state.fetch("command_sha256") &&
               value["response_sha256"] ==
                 Digest::SHA256.hexdigest(JSON.generate(response)) &&
               value["kind"] == command.dig("identity", "kind") &&
               value["native_id"] == value.dig("native", "id")
        raise Error.new("identity_conflict")
      end
      document = NativeDocument.new(command)
      original =
        document.response_object(
          Base64.strict_decode64(response.fetch("body_base64"))
        )
      document.verify!(response: original, current: value.fetch("native"))
    end

    def event_key(id, sequence)
      "#{id}:#{sequence.to_s.rjust(16, "0")}"
    end

    def append(command, state, kind, value)
      event =
        snapshot(
          "format" => "ghost-native-event-1",
          "binding" => @binding,
          "command_id" => command.fetch("command_id"),
          "command_sha256" => state.fetch("command_sha256"),
          "sequence" => state.fetch("event_count") + 1,
          "previous_sha256" => state.fetch("last_event_sha256"),
          "observer_execution_id" => @context.execution_id,
          "observed_at" => timestamp,
          "kind" => kind,
          "value" => value
        )
      apply_event(state, event, command)
      state["event_count"] = event.fetch("sequence")
      state["last_event_sha256"] = Digest::SHA256.hexdigest(
        JSON.generate(event)
      )
      create_record(
        "native_event",
        event_key(command.fetch("command_id"), state.fetch("event_count")),
        event
      )
      progress = record("native_progress", command.fetch("command_id"))
      progress.update!(
        encrypted_payload:
          @installation.envelope.encrypt(
            "operational_record",
            state,
            binding: JSON.generate([progress.kind, progress.record_key])
          )
      )
      event
    end
  end
end
