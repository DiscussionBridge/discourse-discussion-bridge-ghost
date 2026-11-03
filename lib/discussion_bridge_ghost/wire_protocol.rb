# frozen_string_literal: true

require "cgi"
require "digest"
require "json"
require "uri"

module DiscussionBridgeGhost
  # Connector-owned CLIENT rules. The receiver's pure type/semantic validator is
  # a same-suite dependency, not permission to bypass any actual V4 controller.
  # No receiver model/store/coordinator is called from this facade.
  class WireProtocol
    NORMATIVE_SHA256 = "808042688cbde88fac0acdf1187e4cb8c251e13025bfcf09cf3a3c361ca02003"
    SCHEMA_SHA256 = "e6a15a6d70f7bc8b8ee82aa22a0b9c2ff1bbf2da6277f7087118be9e026ce5c0"
    REQUEST_MAXIMUM = 65_536
    RESPONSE_MAXIMUM = 262_144
    JSON_MEDIA = %r{\Aapplication/json(?:\s*;\s*charset\s*=\s*(?:UTF-8|"UTF-8"))?\s*\z}i

    class Packet
      attr_reader :route_id, :method, :path, :query, :body_bytes, :request_sha256

      def initialize(owner:, route:, path:, query:, body_bytes:)
        @owner = owner
        @route_id = route.fetch("id").freeze
        @method = route.fetch("method").freeze
        @path = path.freeze
        @query = query.freeze
        @body_bytes = body_bytes&.freeze
        @request_sha256 = body_bytes && Digest::SHA256.hexdigest(body_bytes).freeze
        freeze
      end

      def owned_by?(owner)
        @owner.equal?(owner)
      end

      def inspect
        "#<DiscussionBridgeGhost::WireProtocol::Packet #{@route_id} [private payload omitted]>"
      end
    end

    class Result
      attr_reader :status, :value, :route_id, :request_sha256

      def initialize(status:, value:, packet:)
        @status = status
        @value = freeze_value(value)
        @route_id = packet.route_id
        @request_sha256 = packet.request_sha256
        freeze
      end

      # Shape classification only. The eventual transport client must retain
      # actual dispatch/response provenance before authorizing refusal recovery.
      # A caller invoking this parser with invented JSON has no such authority.
      def source_refusal_shape?
        %w[V4-02 V4-29].include?(@route_id) && @status == 422 &&
          @value.is_a?(Hash) && @value["outcome"] == "rejected" &&
          @value["retryable"] == false && @value["retry_after_seconds"].nil? &&
          (@value["code"] == "content_preservation_unavailable" ||
            (@route_id == "V4-02" && @value["code"] == "invalid_field"))
      end

      def inspect
        "#<DiscussionBridgeGhost::WireProtocol::Result #{@route_id} #{@status} [private response omitted]>"
      end

      private

      def freeze_value(value)
        case value
        when Hash
          value.each { |key, member| key.freeze; freeze_value(member) }
        when Array
          value.each { |member| freeze_value(member) }
        end
        value.freeze
      end
    end

    def initialize(codec: nil)
      unless codec || defined?(::DiscussionBridge::CmsProtocol)
        raise Error.new("receiver_unavailable")
      end
      @codec = codec || ::DiscussionBridge::CmsProtocol
      unless @codec::CONTRACT_SHA256 == NORMATIVE_SHA256 && @codec::SCHEMA_SHA256 == SCHEMA_SHA256
        raise Error.new("protocol_mismatch")
      end
      @schema = @codec::SCHEMA
      @prepared = ObjectSpace::WeakMap.new
    end

    def prepare(route_id, body: nil, path: {}, query: {}, retained_body: nil)
      route = route!(route_id)
      raise Error.new("response_invalid") unless path.is_a?(Hash) && query.is_a?(Hash)
      raise Error.new("response_invalid") unless retained_body.nil? || body.nil?
      raw = retained_body.nil? ? (body.nil? ? nil : JSON.generate(body)) : retained_body
      decoded = raw.nil? ? nil : WireJson.parse(raw, maximum_bytes: REQUEST_MAXIMUM)
      if route["input"]
        @codec.validate!(route.fetch("input"), decoded)
      elsif !decoded.nil?
        raise Error.new("response_invalid")
      end
      if route["query"]
        @codec.validate!(route.fetch("query"), query)
      elsif !query.empty?
        raise Error.new("response_invalid")
      end
      fields = route.fetch("path").scan(/\{([^}]+)\}/).flatten
      raise Error.new("response_invalid") unless path.keys.sort == fields.sort
      fields.each do |field|
        type = field == "source_id" ? "OpaqueId" : field == "source_revision" ? "Revision" : "UUID"
        @codec.validate!(type, path.fetch(field))
        body_identity = decoded.is_a?(Hash) && (decoded[field] || decoded.dig("authority", field))
        raise Error.new("identity_conflict") if body_identity && body_identity != path.fetch(field)
      end
      relative = route.fetch("path").gsub(/\{([^}]+)\}/) { segment(path.fetch(Regexp.last_match(1))) }
      search = URI.encode_www_form(query.map { |name, value| [name, value.to_s] })
      packet = Packet.new(owner: self, route: route, path: relative, query: search, body_bytes: raw&.dup)
      @prepared[packet] = true
      packet
    rescue JSON::GeneratorError, EncodingError, KeyError
      raise Error.new("response_invalid"), cause: nil
    end

    def response(packet, status:, headers:, bytes:)
      assert_packet!(packet)
      route = route!(packet.route_id)
      unless status.is_a?(Integer) && status.between?(200, 599) && headers.is_a?(Hash) && bytes.is_a?(String)
        raise Error.new("response_invalid")
      end
      lowered = headers.transform_keys { |key| key.to_s.downcase }
      encoding = lowered["content-encoding"]
      raise Error.new("response_invalid") unless encoding.nil? || encoding.to_s.downcase == "identity"
      if status == 204
        unless route.fetch("success_http").include?(204) && bytes.empty?
          raise Error.new("response_invalid")
        end
        return Result.new(status: status, value: nil, packet: packet)
      end
      raise Error.new("response_invalid") unless JSON_MEDIA.match?(lowered["content-type"].to_s)
      maximum = route["response"] == "ContentChunk" ? REQUEST_MAXIMUM : RESPONSE_MAXIMUM
      value = WireJson.parse(bytes, maximum_bytes: maximum)
      if route.fetch("success_http").include?(status)
        @codec.validate!(route.fetch("response"), value)
        if packet.route_id == "V4-02"
          expected = { "created" => 201, "resolved" => 200, "updated" => 200, "reconciliation_required" => 409 }[value["outcome"]]
          raise Error.new("response_invalid") unless status == expected
        end
      elsif packet.route_id == "V4-02" && status == 409 && value.is_a?(Hash) && value["outcome"] == "reconciliation_required"
        @codec.validate!("ResolveResult", value)
      elsif value.is_a?(Hash) && value["outcome"] == "rejected"
        @codec.validate_error_response!(packet.route_id, value, status)
        specification = @schema.fetch("errors").find { |entry| entry.fetch("code") == value.fetch("code") }
        raise Error.new("response_invalid") unless specification && specification.fetch("retryable") == value["retryable"]
      else
        raise Error.new("response_invalid")
      end
      Result.new(status: status, value: value, packet: packet)
    end

    def maximum_response_bytes(packet)
      assert_packet!(packet)
      route!(packet.route_id)["response"] == "ContentChunk" ? REQUEST_MAXIMUM : RESPONSE_MAXIMUM
    end

    def assert_packet!(packet)
      unless packet.is_a?(Packet) && packet.owned_by?(self) && @prepared.key?(packet)
        raise Error.new("response_invalid")
      end
      packet
    end

    private

    def route!(id)
      @schema.fetch("routes").find { |route| route.fetch("id") == id } || raise(Error.new("response_invalid"))
    end

    def segment(value)
      return "%2E" if value == "."
      return "%2E%2E" if value == ".."
      CGI.escape(value).gsub("+", "%20")
    end
  end
end
