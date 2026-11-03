# frozen_string_literal: true

module DiscussionBridgeGhost
  # Only fixed codes cross logging, job, HTTP and operator boundaries. Upstream
  # exceptions/bodies can contain credentials or unpublished native content.
  class Error < StandardError
    MESSAGES = {
      "configuration_invalid" => "The Ghost connector configuration is invalid.",
      "secret_unavailable" => "Protected connector data could not be opened. Restore the matching application key and retained data; do not replace its receipts.",
      "signature_invalid" => "The Ghost event signature is invalid or expired.",
      "receiver_unavailable" => "The matching DiscussionBridge V4 receiver is unavailable.",
      "protocol_mismatch" => "The installed connector and receiver protocol identities do not match.",
      "response_invalid" => "The upstream response is invalid.",
      "native_lock_busy" => "This Ghost installation already has a native writer.",
      "native_lock_lost" => "The Ghost native writer no longer owns its lock.",
      "identity_conflict" => "Retained identity or request history requires reconciliation.",
      "disabled" => "This Ghost connector installation is disabled."
    }.freeze

    attr_reader :code

    def initialize(code)
      @code = MESSAGES.key?(code) ? code : "response_invalid"
      super(MESSAGES.fetch(@code))
    end
  end
end
