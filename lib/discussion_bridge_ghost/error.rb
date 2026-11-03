# frozen_string_literal: true

require_relative "evidence_registry"

module DiscussionBridgeGhost
  # Only fixed codes cross logging, job, HTTP and operator boundaries. Upstream
  # exceptions/bodies can contain credentials or unpublished native content.
  class Error < StandardError
    MESSAGES = {
      "configuration_invalid" =>
        "The Ghost connector configuration is invalid.",
      "secret_unavailable" =>
        "Protected connector data could not be opened. Restore the matching application key and retained data; do not replace its receipts.",
      "signature_invalid" => "The Ghost event signature is invalid or expired.",
      "receiver_unavailable" =>
        "The matching DiscussionBridge V4 receiver is unavailable.",
      "protocol_mismatch" =>
        "The installed connector and receiver protocol identities do not match.",
      "response_invalid" => "The upstream response is invalid.",
      "ghost_http_failed" =>
        "The Ghost API request failed; retained native work must be reconciled before retrying a write.",
      "ghost_rate_limited" =>
        "Ghost has limited API requests. Wait for its reported cooldown before retrying.",
      "native_lock_busy" =>
        "This Ghost installation already has a native writer.",
      "native_lock_lost" => "The Ghost native writer no longer owns its lock.",
      "native_fragment_invalid" =>
        "The Ghost publication fragment could not be verified. Preserve its content and retained history for reconciliation.",
      "native_effect_uncertain" =>
        "A retained Ghost write has no proven completion. Preserve it for reconciliation; do not repeat the write.",
      "native_command_retired" =>
        "This saved Ghost write was retired without being sent. Its history is preserved; it cannot be executed or treated as a completed publication.",
      "native_exclusion_pending" =>
        "Retained Ghost exclusion records need local qualification before this target can accept new writes. Original work and receipts are preserved.",
      "native_representation_unavailable" =>
        "The required Ghost content parser is unavailable or incompatible. Reconciliation is required before continuing.",
      "identity_conflict" =>
        "Retained identity or request history requires reconciliation.",
      "disabled" => "This Ghost connector installation is disabled.",
      "work_authority_unavailable" =>
        "Current publication authority could not be verified. Preserve the retained work and receipts before retrying.",
      "work_renewal_pending" =>
        "The retained publication lease renewal has not succeeded. Honor its recorded retry or resolve the refusal before continuing.",
      "transaction_open" =>
        "Ghost synchronization requires a committed boundary outside an enclosing database transaction."
    }.freeze

    attr_reader :code

    def initialize(code)
      EvidenceRegistry.prepare(self)
      @code = MESSAGES.key?(code) ? code : "response_invalid"
      super(MESSAGES.fetch(@code))
    end
  end
end
