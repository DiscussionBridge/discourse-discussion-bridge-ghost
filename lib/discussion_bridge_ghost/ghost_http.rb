# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"
require "uri"

module DiscussionBridgeGhost
  # Fixed-origin outbound transport. Production uses Core's DNS/IP filtering,
  # never an environment proxy, ambient cookies, redirects or automatic retries.
  # The caller's guard is its current installation/work/lease authority check;
  # completing HTTP alone never grants a native receipt or verified ACK.
  class GhostHttp
    include ProtectedDiagnostics

    Response =
      Struct.new(:status, :headers, :bytes, keyword_init: true) do
        include ProtectedDiagnostics
      end

    class Failure < Error
      attr_reader :status, :retry_after_seconds

      def initialize(status: nil, retry_after_seconds: nil)
        @status = status
        @retry_after_seconds = retry_after_seconds
        super(status == 429 ? "ghost_rate_limited" : "ghost_http_failed")
      end
    end

    def initialize(
      origin:,
      protocol:,
      guard:,
      api_key: nil,
      factory: nil,
      now: -> { Time.now.to_i },
      deadline_seconds: 10
    )
      valid_deadline =
        guard.respond_to?(:call) &&
          (deadline_seconds.is_a?(Integer) || deadline_seconds.is_a?(Float)) &&
          deadline_seconds.finite? && deadline_seconds.positive? &&
          deadline_seconds <= 10
      raise Error.new("configuration_invalid") unless valid_deadline
      @deadline_seconds = deadline_seconds
      @origin = protocol.origin_key(origin).freeze
      @address = URI.parse(@origin)
      @guard, @now = guard, now
      @api_key = api_key&.dup&.freeze
      AdminToken.generate(@api_key, now: @now.call) if @api_key
      @factory =
        factory ||
          ->(host, port) { ::FinalDestination::HTTP.new(host, port, nil) }
    end

    def request(
      method,
      path,
      maximum_bytes:,
      payload: nil,
      authenticated: false,
      media: "json",
      allowed_statuses: [200],
      retained_body: nil
    )
      unless %w[GET POST PUT].include?(method) && path.is_a?(String) &&
               path.ascii_only? && path.start_with?("/") &&
               !path.start_with?("//") &&
               !path.match?(/[\p{Space}\p{Cc}#\\]/) &&
               maximum_bytes.is_a?(Integer) && maximum_bytes.positive? &&
               %w[json html any].include?(media) &&
               allowed_statuses.is_a?(Array) && !allowed_statuses.empty? &&
               allowed_statuses.all? { |status|
                 status.is_a?(Integer) && status.between?(200, 599)
               }
        raise Error.new("configuration_invalid")
      end
      valid_body =
        retained_body.nil? ||
          (
            payload.nil? && retained_body.is_a?(String) &&
              retained_body.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          )
      raise Error.new("configuration_invalid") unless valid_body
      valid_authority =
        (
          !authenticated || (@api_key && path.start_with?("/ghost/api/admin/"))
        ) && (method != "GET" || (payload.nil? && retained_body.nil?)) &&
          (authenticated || method == "GET")
      raise Error.new("configuration_invalid") unless valid_authority
      # Validate the whole address without normalizing navigable dot segments or
      # introducing another authority. All API paths are assembled by the client.
      uri = URI.parse(@origin + path)
      unless uri.scheme == "https" && uri.host == @address.host &&
               uri.port == @address.port && !uri.userinfo && !uri.fragment
        raise Error.new("configuration_invalid")
      end
      if uri
           .path
           .split("/")
           .any? { |segment| %w[. ..].include?(segment.gsub(/%2e/i, ".")) }
        raise Error.new("configuration_invalid")
      end
      @guard.call
      response = nil
      Timeout.timeout(@deadline_seconds) do
        http = @factory.call(@address.hostname, @address.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = 3
        http.read_timeout = 3
        http.write_timeout = 3
        http.max_retries = 0
        headers = {
          "Accept" => {
            "json" => "application/json",
            "html" => "text/html",
            "any" => "*/*"
          }.fetch(media),
          "Accept-Encoding" => "identity",
          "User-Agent" => "DiscussionBridge-Ghost-native/0.4.0-alpha.1"
        }
        headers[
          "Authorization"
        ] = "Ghost #{AdminToken.generate(@api_key, now: @now.call)}" if authenticated
        body =
          (
            retained_body || (payload.nil? ? nil : JSON.generate(payload))
          )&.dup&.freeze
        headers["Content-Type"] = "application/json; charset=utf-8" if body
        klass = {
          "GET" => Net::HTTP::Get,
          "POST" => Net::HTTP::Post,
          "PUT" => Net::HTTP::Put
        }.fetch(method)
        outgoing = klass.new(uri.request_uri, headers)
        outgoing.body = body if body
        http.start do |connection|
          connection.request(outgoing) do |incoming|
            status = Integer(incoming.code, 10)
            if status == 429
              value = incoming["retry-after"].to_s
              cooldown =
                /\A[0-9]{1,8}\z/.match?(value) ? Integer(value, 10) : nil
              raise Failure.new(status: status, retry_after_seconds: cooldown)
            end
            if allowed_statuses.index(status).nil?
              raise Failure.new(status: status)
            end
            content_type = incoming["content-type"].to_s
            content_encoding = incoming["content-encoding"]
            unless content_encoding.nil? ||
                     content_encoding.downcase == "identity"
              raise Failure.new(status: status)
            end
            valid_media =
              media == "any" ||
                (
                  media == "json" &&
                    WireProtocol::JSON_MEDIA.match?(content_type)
                ) ||
                (
                  media == "html" &&
                    %r{\Atext/html(?:\s*;[^\r\n]*)?\z}i.match?(content_type)
                )
            raise Failure.new(status: status) unless valid_media
            declared = incoming["content-length"]
            if declared &&
                 (
                   !/\A[0-9]+\z/.match?(declared) ||
                     declared.to_i > maximum_bytes
                 )
              raise Failure.new(status: status)
            end
            bytes = +"".b
            incoming.read_body do |chunk|
              if chunk.bytesize > maximum_bytes - bytes.bytesize
                raise Failure.new(status: status)
              end
              bytes << chunk.b
            end
            if declared && bytes.bytesize != declared.to_i
              raise Failure.new(status: status)
            end
            retained_headers =
              %w[content-type content-encoding location retry-after]
                .to_h { |name| [name, incoming[name]&.dup&.freeze] }
                .freeze
            response =
              Response.new(
                status: status,
                headers: retained_headers,
                bytes: bytes.freeze
              ).freeze
          end
        end
        @guard.call
      end
      response || raise(Failure.new)
    rescue Error
      raise
    rescue StandardError
      # A failed POST/PUT may already have reached Ghost. The native coordinator
      # must retain its prior intent and look up ownership; never create again
      # merely because a reply or this transport's deadline was lost.
      raise Failure.new, cause: nil
    end
  end
end
