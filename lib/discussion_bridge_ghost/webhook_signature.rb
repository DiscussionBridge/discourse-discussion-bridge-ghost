# frozen_string_literal: true

require "openssl"

module DiscussionBridgeGhost
  module WebhookSignature
    WINDOW_MS = 300_000
    HEADER = /\Asha256=([a-f0-9]{64}), t=([0-9]{13})\z/

    # Authenticate the exact raw bytes BEFORE JSON parsing. The event body is an
    # identity notification; it never supplies authoritative publication HTML.
    def self.valid?(
      header:,
      raw_body:,
      secret:,
      now_ms: (Time.now.to_r * 1000).to_i
    )
      unless header.is_a?(String) && raw_body.is_a?(String) &&
               secret.is_a?(String) && secret.bytesize.between?(24, 512) &&
               now_ms.is_a?(Integer)
        return false
      end
      match = HEADER.match(header)
      unless match && (Integer(match[2], 10) - now_ms).abs <= WINDOW_MS
        return false
      end
      actual = [match[1]].pack("H*")
      expected = OpenSSL::HMAC.digest("SHA256", secret, raw_body.b + match[2].b)
      OpenSSL.fixed_length_secure_compare(actual, expected)
    rescue ArgumentError, EncodingError
      false
    end
  end
end
