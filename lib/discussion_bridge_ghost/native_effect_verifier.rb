# frozen_string_literal: true

require "base64"
require "digest"
require_relative "native_document"

module DiscussionBridgeGhost
  # Proves a historical physical effect only. It cannot renew receiver work,
  # issue an ownership receipt, acknowledge a lease or authorize another write.
  # UNKNOWN with no retained completed response is deliberately not resolved by
  # content equality or an empty resource lookup.
  class NativeEffectVerifier
    include ProtectedDiagnostics

    Evidence =
      Struct.new(:value, keyword_init: true) { include ProtectedDiagnostics }

    attr_reader :context

    def initialize(context:, api_key:, factory: nil)
      unless context.is_a?(ExecutionContext)
        raise Error.new("identity_conflict")
      end
      @context = context
      @http =
        GhostHttp.new(
          protocol: context.protocol,
          origin: context.installation.native_target.admin_origin,
          guard: -> { context.assert! },
          api_key: api_key,
          factory: factory
        )
      @client = GhostAdminClient.new(http: @http)
      @evidence = EvidenceRegistry.new
    end

    def verify(command:, response:)
      @context.outside_transaction!
      @context.assert!
      unless command.fetch("binding") == @context.binding &&
               response.is_a?(Hash) &&
               command.dig("request", "allowed_statuses").include?(
                 response["status"]
               )
        raise Error.new("identity_conflict")
      end
      bytes = Base64.strict_decode64(response.fetch("body_base64"))
      document = NativeDocument.new(command)
      original = document.response_object(bytes)
      native_id = original.fetch("id")
      current =
        @client.get(
          native_id,
          kind: command.dig("identity", "kind"),
          maximum_bytes: command.dig("request", "maximum_bytes")
        )
      document.verify!(response: original, current: current)
      if command.dig("owner", "direction") == "from_discourse"
        matches =
          @client.find_by_resource(
            command.dig("identity", "resource_id"),
            maximum_bytes: command.dig("request", "maximum_bytes")
          )
        unless matches.length == 1 && matches.first["id"] == native_id &&
                 matches.first["type"] == command.dig("identity", "kind") &&
                 matches.first["updated_at"] == current["updated_at"]
          raise Error.new("identity_conflict")
        end
        document.verify!(response: original, current: matches.first)
        current = matches.first
      end
      @context.assert!
      value = {
        "format" => "ghost-native-effect-1",
        "binding" => @context.binding,
        "command_id" => command.fetch("command_id"),
        "command_sha256" => Digest::SHA256.hexdigest(JSON.generate(command)),
        "response_sha256" => Digest::SHA256.hexdigest(JSON.generate(response)),
        "native_id" => native_id,
        "kind" => command.dig("identity", "kind"),
        "native" => current
      }
      # The result is protected and privately retained; public/protocol output
      # must instead be constructed by its separately authorized projection.
      result = Evidence.new(value: deep_freeze(value))
      @evidence.retain(result, result.value)
      result.freeze
    rescue KeyError, TypeError, ArgumentError
      raise Error.new("identity_conflict"), cause: nil
    end

    def actual_evidence(result)
      @evidence[result]
    end

    private

    def deep_freeze(value)
      case value
      when Hash
        value.each do |key, member|
          key.freeze
          deep_freeze(member)
        end
      when Array
        value.each { |member| deep_freeze(member) }
      end
      value.freeze
    end
  end
end
