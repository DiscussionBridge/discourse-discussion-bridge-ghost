# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

module DiscussionBridgeGhost
  class ConnectionCheck
    CONTRACT_SHA256 = "808042688cbde88fac0acdf1187e4cb8c251e13025bfcf09cf3a3c361ca02003"
    SCHEMA_SHA256 = "e6a15a6d70f7bc8b8ee82aa22a0b9c2ff1bbf2da6277f7087118be9e026ce5c0"
    MAX_RESPONSE_BYTES = 32_768
    API_VERSION = "v6.0"

    class Error < StandardError
      attr_reader :code, :status

      def initialize(code, status: nil)
        @code = code
        @status = status
        super(status ? "#{code} (HTTP #{status})" : code)
      end
    end

    def self.call(connection_id:, admin_url:, admin_key:)
      unless defined?(::DiscussionBridge::CmsProtocol::CONTRACT_SHA256) &&
             defined?(::DiscussionBridge::CmsProtocol::SCHEMA_SHA256) &&
             DiscussionBridge::CmsProtocol::CONTRACT_SHA256 == CONTRACT_SHA256 &&
             DiscussionBridge::CmsProtocol::SCHEMA_SHA256 == SCHEMA_SHA256
        raise Error.new("r7_receiver_required")
      end

      new(admin_url, admin_key).check(connection_id)
    end

    def initialize(admin_url, admin_key)
      @admin_uri = URI.parse(admin_url)
      unless @admin_uri.is_a?(URI::HTTPS) && @admin_uri.host && !@admin_uri.userinfo &&
             !@admin_uri.query && !@admin_uri.fragment
        raise Error.new("ghost_admin_url_invalid")
      end

      key = /\A([0-9a-f]{24}):([0-9a-f]{64})\z/i.match(admin_key)
      raise Error.new("ghost_admin_key_invalid") unless key

      @key_id = key[1]
      @key_secret = [key[2]].pack("H*")
    rescue URI::InvalidURIError
      raise Error.new("ghost_admin_url_invalid"), cause: nil
    end

    def check(connection_id)
      connection = DiscussionBridgeContentConnection.find_by(public_id: connection_id)
      raise Error.new("receiver_connection_missing") unless connection

      descriptor = DiscussionBridge::CmsAuthorityStore.new(connection).descriptor.body
      unless descriptor.fetch("profile") == "ghost" &&
             descriptor.dig("native_capabilities", "publication_kind") == "dynamic"
        raise Error.new("ghost_dynamic_connection_required")
      end

      site = get("site")["site"]
      unless site.is_a?(Hash) && site["url"].is_a?(String) && site["version"].is_a?(String)
        raise Error.new("ghost_response_invalid")
      end
      DiscussionBridge::CmsConfiguration.destination_url!(
        connection, descriptor, site.fetch("url"),
      )

      %w[posts pages].each do |collection|
        items = get(collection, query: "limit=1&fields=id", token: token)[collection]
        unless items.is_a?(Array) && items.length <= 1 &&
               items.all? { |item| item.is_a?(Hash) && item["id"].is_a?(String) }
          raise Error.new("ghost_response_invalid")
        end
      end

      {
        connection_id: descriptor.fetch("connection_id"),
        destination_origin: descriptor.fetch("destination_origin"),
        directions: descriptor.fetch("directions"),
        from_discourse_policy_enabled: descriptor.dig("policy", "enabled"),
        ghost_version: site.fetch("version"),
        ghost_admin_read: %w[posts pages],
      }
    rescue DiscussionBridge::CmsProtocol::Error => error
      raise Error.new("receiver_#{error.code}"), cause: nil
    end

    private

    def get(resource, query: nil, token: nil)
      uri = @admin_uri.dup
      uri.path = "#{uri.path.delete_suffix('/')}/ghost/api/admin/#{resource}/"
      uri.query = query

      headers = { "Accept" => "application/json", "Accept-Version" => API_VERSION }
      headers["Authorization"] = "Ghost #{token}" if token
      http = FinalDestination::HTTP.new(uri.hostname, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = http.read_timeout = 5
      http.max_retries = 0

      body = +"".b
      http.start do |session|
        session.request(Net::HTTP::Get.new(uri.request_uri, headers)) do |response|
          status = response.code.to_i
          raise Error.new("ghost_http_error", status: status) unless status == 200
          response.read_body do |chunk|
            raise Error.new("ghost_response_too_large") if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
            body << chunk
          end
        end
      end

      value = JSON.parse(body)
      raise Error.new("ghost_response_invalid") unless value.is_a?(Hash)
      value
    rescue JSON::ParserError, EncodingError
      raise Error.new("ghost_response_invalid"), cause: nil
    rescue SocketError, SystemCallError, Timeout::Error, IOError, Net::HTTPBadResponse, OpenSSL::SSL::SSLError
      raise Error.new("ghost_transport_failed"), cause: nil
    end

    def token
      now = Time.now.to_i
      header = { alg: "HS256", typ: "JWT", kid: @key_id }
      claims = { iat: now, exp: now + 60, aud: "/admin/" }
      unsigned = [header, claims].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }
        .join(".")
      signature = OpenSSL::HMAC.digest("SHA256", @key_secret, unsigned)
      "#{unsigned}.#{Base64.urlsafe_encode64(signature, padding: false)}"
    end

    private_class_method :new
  end
end
