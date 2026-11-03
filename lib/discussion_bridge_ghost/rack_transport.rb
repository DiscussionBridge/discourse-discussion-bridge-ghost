# frozen_string_literal: true

require "stringio"
require "timeout"
require "uri"

module DiscussionBridgeGhost
  # Fresh own-site HTTPS Rack requests through the actual V4 router/controller.
  # This is not an administrator session, a direct coordinator call, or an HTTP
  # proxy. No ambient cookies, API keys, shared-session headers or env are copied.
  class RackTransport
    include ProtectedDiagnostics

    def bound_to?(protocol, connection_id)
      @protocol.equal?(protocol) && @connection_id == connection_id
    end

    def initialize(
      protocol:,
      connection_id:,
      connection_secret:,
      app: Rails.application,
      base_url: Discourse.base_url
    )
      unless connection_id.is_a?(String) &&
               /\Adbc_[a-f0-9]{24}\z/.match?(connection_id) &&
               connection_secret.is_a?(String) &&
               connection_secret.bytesize.between?(32, 256) &&
               !connection_secret.match?(/[\p{Cc}]/)
        raise Error.new("configuration_invalid")
      end
      unless base_url == Discourse.base_url
        raise Error.new("configuration_invalid")
      end
      uri = URI.parse(base_url)
      unless uri.scheme == "https" && uri.host && !uri.userinfo && !uri.query &&
               !uri.fragment
        raise Error.new("configuration_invalid")
      end
      @protocol, @app = protocol, app
      @connection_id, @connection_secret =
        connection_id.dup.freeze,
        connection_secret.dup.freeze
      @host = uri.host.freeze
      @port = uri.port
      @base_path = uri.path == "/" ? "" : uri.path.delete_suffix("/")
      @host_header = (@port == 443 ? @host : "#{@host}:#{@port}").freeze
      @received_refusals = ObjectSpace::WeakMap.new
    rescue URI::InvalidURIError, EncodingError
      raise Error.new("configuration_invalid"), cause: nil
    end

    def execute(packet)
      @protocol.assert_packet!(packet)
      body = nil
      result = nil
      Timeout.timeout(20) do
        status, headers, body = @app.call(environment(packet))
        maximum = status == 204 ? 0 : @protocol.maximum_response_bytes(packet)
        bytes = +"".b
        body.each do |chunk|
          unless chunk.is_a?(String) &&
                   chunk.bytesize <= maximum - bytes.bytesize
            raise Error.new("response_invalid")
          end
          bytes << chunk.b
        end
        result =
          @protocol.response(
            packet,
            status: status,
            headers: headers,
            bytes: bytes
          )
      end
      if result.source_refusal_shape?
        # Evidence is registered only after this transport's actual dispatch and
        # validated response. A parser result or caller-provided code is not one.
        @received_refusals[result] = {
          "route_id" => packet.route_id,
          "connection_id" => @connection_id,
          "request_sha256" => packet.request_sha256,
          "status" => result.status,
          "envelope" => result.value
        }.freeze
      end
      result
    rescue Error
      raise
    rescue StandardError
      # Caller retains the exact prepared mutation. A timeout/exception after a
      # POST is never proof that the receiver did not commit it.
      raise Error.new("response_invalid"), cause: nil
    ensure
      begin
        body.close if body.respond_to?(:close)
      rescue StandardError
        raise Error.new("response_invalid"), cause: nil
      end
    end

    def actual_source_refusal(result)
      @received_refusals[result]
    end

    def inspect
      "#<DiscussionBridgeGhost::RackTransport [credentials omitted]>"
    end

    private

    def environment(packet)
      raw = packet.body_bytes || ""
      {
        "REQUEST_METHOD" => packet.method,
        "SCRIPT_NAME" => "",
        "PATH_INFO" => "#{@base_path}#{packet.path}",
        "QUERY_STRING" => packet.query,
        "SERVER_NAME" => @host,
        "SERVER_PORT" => @port.to_s,
        "SERVER_PROTOCOL" => "HTTP/1.1",
        "REMOTE_ADDR" => "127.0.0.1",
        "HTTP_HOST" => @host_header,
        "HTTPS" => "on",
        "rack.url_scheme" => "https",
        "rack.input" => StringIO.new(raw.b),
        "rack.errors" => StringIO.new,
        "rack.multithread" => true,
        "rack.multiprocess" => true,
        "rack.run_once" => false,
        "HTTP_ACCEPT" => "application/json",
        "HTTP_ACCEPT_ENCODING" => "identity",
        "HTTP_USER_AGENT" => "DiscussionBridge-Ghost-native/0.4.0-alpha.1",
        "HTTP_X_DISCUSSIONBRIDGE_CONNECTION" => @connection_id,
        "HTTP_X_DISCUSSIONBRIDGE_SECRET" => @connection_secret,
        "CONTENT_LENGTH" => raw.bytesize.to_s,
        **(packet.body_bytes ? { "CONTENT_TYPE" => "application/json" } : {})
      }
    end
  end
end
