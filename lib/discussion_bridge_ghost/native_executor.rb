# frozen_string_literal: true

require_relative "native_effect_verifier"
require_relative "native_command_journal"

module DiscussionBridgeGhost
  # Unactivated native command executor. The public coordinator will supply
  # fully prepared owned-card/metadata intents. This class sends only their
  # already-durable exact bytes, under current From authority, and retains the
  # genuine transport outcome even when final current-authority checks fail.
  # Source URL moves require their separate current To authority and are NOT
  # accidentally authorized by a From lease here.
  class NativeExecutor
    include ProtectedDiagnostics

    def initialize(context:, journal:, api_key:, authority: nil, factory: nil)
      valid_authority =
        authority.nil? ||
          (authority.is_a?(WorkAuthority) && authority.bound_to?(context))
      unless context.is_a?(ExecutionContext) &&
               journal.is_a?(NativeCommandJournal) &&
               journal.context.equal?(context) && valid_authority
        raise Error.new("identity_conflict")
      end
      @context, @journal, @api_key, @authority, @factory =
        context,
        journal,
        api_key,
        authority,
        factory
    end

    def execute(command_id)
      retained = @journal.retained(command_id)
      command = retained.fetch("command")
      if retained.dig("state", "completion")
        return retained.dig("state", "completion")
      end
      if retained.dig("state", "pending_attempt")
        raise Error.new("native_effect_uncertain")
      end
      raise Error.new("work_authority_unavailable") unless @authority
      NativeDocument.new(command)
      @authority.guard_native!(command)
      http =
        GhostHttp.new(
          protocol: @context.protocol,
          origin: @context.installation.native_target.admin_origin,
          guard: -> { @authority.guard_native!(command) },
          api_key: @api_key,
          factory: @factory
        )
      attempt = @journal.begin_attempt(command_id, http: http)
      request = command.fetch("request")
      begin
        outcome =
          http.request(
            request.fetch("method"),
            request.fetch("path"),
            retained_body: request.fetch("body_bytes"),
            maximum_bytes: request.fetch("maximum_bytes"),
            allowed_statuses: request.fetch("allowed_statuses"),
            authenticated: true,
            dispatch: attempt
          )
      rescue Error => error
        # An unregistered/pre-claim exception has no evidence; leave UNKNOWN.
        if http.actual_dispatch_evidence(error, dispatch: attempt)
          @journal.retain_dispatch(
            command_id,
            attempt: attempt,
            http: http,
            outcome: error
          )
        end
        raise
      end
      @journal.retain_dispatch(
        command_id,
        attempt: attempt,
        http: http,
        outcome: outcome
      )
      recover(command_id)
    end

    # Read/record the original completed effect under this current installation
    # lock, even if receiver work now belongs to another generation. This does
    # not reuse that old generation for a new write or ACK.
    def recover(command_id)
      retained = @journal.retained(command_id)
      if retained.dig("state", "completion")
        return retained.dig("state", "completion")
      end
      response = retained.fetch("response")
      raise Error.new("native_effect_uncertain") unless response
      verifier =
        NativeEffectVerifier.new(
          context: @context,
          api_key: @api_key,
          factory: @factory
        )
      evidence =
        verifier.verify(command: retained.fetch("command"), response: response)
      @journal.retain_completion(
        command_id,
        verifier: verifier,
        evidence: evidence
      )
    end
  end
end
