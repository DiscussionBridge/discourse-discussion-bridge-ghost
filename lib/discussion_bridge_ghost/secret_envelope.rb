# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module DiscussionBridgeGhost
  # A per-installation, purpose-bound authenticated envelope. Moving a cipher
  # between installations or between config/request/response slots must fail.
  # No key or decrypted upstream exception is returned in a diagnostic.
  class SecretEnvelope
    include ProtectedDiagnostics

    PURPOSES = %w[
      configuration
      journal_request
      journal_response
      operational_record
    ].freeze
    UUID =
      /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    FIELDS = %w[version nonce tag ciphertext].sort.freeze

    def initialize(application_key:, installation_id:)
      unless application_key.is_a?(String) && application_key.bytesize >= 32 &&
               installation_id.is_a?(String) && UUID.match?(installation_id)
        raise Error.new("secret_unavailable")
      end
      @key =
        OpenSSL::KDF.hkdf(
          application_key,
          salt: "discussionbridge-ghost-secret-envelope-v1",
          info: installation_id,
          length: 32,
          hash: "SHA256"
        )
      @installation_id = installation_id.freeze
    end

    def encrypt(purpose, value, binding: "")
      associated = associated_data(purpose, binding)
      plaintext = JSON.generate(value)
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = @key
      nonce = cipher.random_iv
      cipher.auth_data = associated
      encrypted = cipher.update(plaintext) + cipher.final
      JSON.generate(
        "version" => 1,
        "nonce" => Base64.strict_encode64(nonce),
        "tag" => Base64.strict_encode64(cipher.auth_tag),
        "ciphertext" => Base64.strict_encode64(encrypted)
      )
    rescue JSON::GeneratorError,
           EncodingError,
           ArgumentError,
           OpenSSL::Cipher::CipherError
      raise Error.new("secret_unavailable"), cause: nil
    end

    def decrypt(purpose, encoded, binding: "")
      associated = associated_data(purpose, binding)
      raise Error.new("secret_unavailable") unless encoded.is_a?(String)
      envelope = JSON.parse(encoded)
      unless envelope.is_a?(Hash) && envelope.keys.sort == FIELDS &&
               envelope["version"] == 1 &&
               envelope
                 .values_at("nonce", "tag", "ciphertext")
                 .all? { |v| v.is_a?(String) }
        raise Error.new("secret_unavailable")
      end
      nonce = Base64.strict_decode64(envelope.fetch("nonce"))
      tag = Base64.strict_decode64(envelope.fetch("tag"))
      unless nonce.bytesize == 12 && tag.bytesize == 16
        raise Error.new("secret_unavailable")
      end
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = @key
      cipher.iv = nonce
      cipher.auth_tag = tag
      cipher.auth_data = associated
      bytes =
        cipher.update(Base64.strict_decode64(envelope.fetch("ciphertext"))) +
          cipher.final
      bytes.force_encoding(Encoding::UTF_8)
      raise Error.new("secret_unavailable") unless bytes.valid_encoding?
      JSON.parse(bytes)
    rescue JSON::ParserError,
           ArgumentError,
           EncodingError,
           OpenSSL::Cipher::CipherError
      raise Error.new("secret_unavailable"), cause: nil
    end

    private

    def associated_data(purpose, binding)
      unless PURPOSES.include?(purpose) && binding.is_a?(String) &&
               binding.valid_encoding? && !binding.include?("\0")
        raise Error.new("secret_unavailable")
      end
      JSON.generate(
        [
          "discussionbridge-ghost-envelope-v1",
          @installation_id,
          purpose,
          binding
        ]
      )
    end
  end
end
