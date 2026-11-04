# frozen_string_literal: true

require_relative "native_readiness"
require "time"

module DiscussionBridgeGhost
  # Actual anonymous canonical-page verification, not trust in a copied source
  # marker. Native ownership/current desired state is independently rechecked.
  # This emits bounded evidence only; it never writes Ghost or sends an ACK.
  class NativePublicVerifier
    include ProtectedDiagnostics

    PROFILE = "ghost-public-owned-fragment-v2"

    class Observation
      include ProtectedDiagnostics
      attr_reader :readiness, :verification

      def initialize(readiness:, verification:)
        @readiness, @verification = readiness, verification
        EvidenceRegistry.prepare(self)
        freeze
      end
    end

    def initialize(
      context:,
      commands:,
      authority:,
      api_key:,
      factory: nil,
      now: -> { Time.now.utc }
    )
      unless context.is_a?(ExecutionContext) &&
               commands.is_a?(NativeCommandJournal) &&
               commands.context.equal?(context) &&
               authority.is_a?(WorkAuthority) && authority.bound_to?(context) &&
               now.respond_to?(:call)
        raise Error.new("identity_conflict")
      end
      @context, @commands, @authority, @api_key, @factory, @now =
        context,
        commands,
        authority,
        api_key,
        factory,
        now
      @evidence = EvidenceRegistry.new
    end

    def capture(event_id: nil, prior_ownership_key:)
      checker =
        NativeReadiness.new(
          context: @context,
          commands: @commands,
          authority: @authority,
          api_key: @api_key,
          operation: :verify,
          factory: @factory
        )
      readiness =
        checker.capture(
          event_id: event_id,
          prior_ownership_key: prior_ownership_key
        )
      unless checker.actual_evidence(readiness) == readiness.value
        raise Error.new("identity_conflict")
      end
      value = readiness.value
      native_id = value.dig("native_result", "native_id")
      url = value.dig("mapping", "canonical_url")
      guard = -> { @authority.guard!(operation: :verify, native_id: native_id) }
      publish = value.dig("work", "action") == "publish_revision"
      http =
        GhostHttp.new(
          protocol: @context.protocol,
          origin: @context.binding.fetch("ghost_origin"),
          guard: guard,
          factory: @factory
        )
      response =
        http.request(
          "GET",
          request_path(url),
          maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES,
          media: publish ? "html" : "any",
          allowed_statuses: publish ? [200] : [404, 410]
        )
      checked_at = Time.at((@now.call.to_r * 1000).floor / 1000r).utc.iso8601(3)
      if publish
        baseline =
          NativeBaselineJournal.new(
            context: @context,
            journal: @commands
          ).retained(value.fetch("baseline_command_id"))
        fragment =
          OwnedFragment.new(
            resource_id: value.dig("mapping", "resource_id"),
            kind: baseline.value.dig("identity", "kind"),
            native_id: native_id,
            nonce: baseline.value.dig("fragment", "nonce"),
            maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES
          )
        actual =
          fragment.extract(
            response.bytes,
            context: :document,
            expected: {
              "data-discussionbridge-source-revision" =>
                value.dig("source", "source_revision"),
              "data-discussionbridge-mode" =>
                value.dig("mapping", "presentation_mode")
            }
          )
        unless actual.sha256 == value.fetch("fragment_sha256")
          raise Error.new("public_verification_failed")
        end
        verification = {
          "kind" => "published",
          "url" => url,
          "native_id" => native_id,
          "source_revision" => value.dig("source", "source_revision"),
          "source_content_sha256" => value.dig("source", "content_sha256"),
          "native_publication_sha256" => actual.sha256,
          "verification_profile" => PROFILE,
          "checked_at" => checked_at,
          "representation" => value.dig("native_result", "representation")
        }
      else
        verification = {
          "kind" => "absent",
          "url" => url,
          "native_id" => native_id,
          "checked_at" => checked_at,
          "http_status" => response.status
        }
      end
      @context.protocol.validate!("Verification", verification)
      guard.call
      current_baseline =
        NativeBaselineJournal.new(
          context: @context,
          journal: @commands
        ).current(value.dig("mapping", "mapping_id"))
      unless current_baseline &&
               current_baseline.sha256 == value.fetch("baseline_sha256")
        raise Error.new("identity_conflict")
      end
      @commands.assert_clear!(
        resource_id: value.dig("mapping", "resource_id"),
        kind: current_baseline.value.dig("identity", "kind"),
        native_id: native_id,
        slugs: [current_baseline.value.dig("scalars", "slug")]
      )
      observation =
        Observation.new(
          readiness: readiness,
          verification: freeze_value(verification)
        )
      @evidence.retain(
        observation,
        {
          "readiness" => value,
          "verification" => observation.verification
        }.freeze
      )
      observation
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def actual_evidence(observation)
      @evidence[observation]
    end

    private

    # Protocol identity is retained byte-for-byte. Only the HTTP request path
    # encodes literal UTF-8 bytes; existing escapes, query and delimiters survive.
    def request_path(url)
      unless @context.protocol.url_origin_key(url) ==
               @context.protocol.origin_key(
                 @context.binding.fetch("ghost_origin")
               )
        raise Error.new("identity_conflict")
      end
      suffix = url.sub(%r{\Ahttps://[^/?#]+}i, "")
      suffix = "/#{suffix}" unless suffix.start_with?("/")
      suffix
        .b
        .bytes
        .map { |byte| byte <= 32 || byte >= 127 ? "%%%02X" % byte : byte.chr }
        .join
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
