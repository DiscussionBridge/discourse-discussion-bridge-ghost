# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module DiscussionBridgeGhost
  module AdminToken
    KEY = /\A([a-f0-9]{24}):([a-f0-9]{64})\z/i

    def self.generate(api_key, now: Time.now.to_i)
      match = api_key.is_a?(String) && KEY.match(api_key)
      unless match && now.is_a?(Integer) && now >= 0
        raise Error.new("configuration_invalid")
      end
      header = encode("alg" => "HS256", "typ" => "JWT", "kid" => match[1])
      payload = encode("iat" => now, "exp" => now + 300, "aud" => "/admin/")
      input = "#{header}.#{payload}"
      signature = OpenSSL::HMAC.digest("SHA256", [match[2]].pack("H*"), input)
      "#{input}.#{Base64.urlsafe_encode64(signature, padding: false)}"
    end

    def self.encode(value)
      Base64.urlsafe_encode64(JSON.generate(value), padding: false)
    end
    private_class_method :encode
  end
end
