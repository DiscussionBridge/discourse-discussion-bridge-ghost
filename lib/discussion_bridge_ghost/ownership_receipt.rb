# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridgeGhost
  # Immutable V4 receipt value and canonical fingerprint, NOT proof that a
  # Ghost object exists/is owned or that a caller may write. The native layer
  # must establish those facts separately before durably recording a receipt.
  class OwnershipReceipt
    include ProtectedDiagnostics

    FIELDS = %w[
      schema_version
      forum_origin
      connection_id
      mapping_id
      resource_id
      source_id
      external_id
      native_id
      canonical_url
      source_revision
      last_lease_generation
      move_id
      proof_nonce
    ].map(&:freeze).freeze

    attr_reader :value, :sha256

    def initialize(value, protocol:)
      raise Error.new("identity_conflict") unless protocol.is_a?(WireProtocol)
      snapshot =
        WireJson.parse(
          JSON.generate(value),
          maximum_bytes: WireProtocol::RESPONSE_MAXIMUM
        )
      protocol.validate!("NativeOwnershipReceipt", snapshot)
      @value =
        FIELDS
          .to_h do |name|
            member = snapshot.fetch(name)
            [name, member.is_a?(String) ? member.dup.freeze : member]
          end
          .freeze
      @sha256 = self.class.send(:canonical_fingerprint, @value).freeze
      freeze
    rescue JSON::GeneratorError, KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    # The normative field order is not JSON/hash insertion order. Lengths are
    # raw UTF-8 bytes, numbers are canonical decimal, and NULL has its own frame.
    # No URL or Unicode normalization and no extra hash-domain prefix is added.
    def self.canonical_fingerprint(value)
      digest = Digest::SHA256.new
      FIELDS.each do |name|
        member = value.fetch(name)
        if member.nil?
          digest.update([0xffff_ffff].pack("N"))
        else
          bytes = member.to_s.b
          digest.update([bytes.bytesize].pack("N"))
          digest.update(bytes)
        end
      end
      digest.hexdigest
    end
    private_class_method :canonical_fingerprint
  end
end
