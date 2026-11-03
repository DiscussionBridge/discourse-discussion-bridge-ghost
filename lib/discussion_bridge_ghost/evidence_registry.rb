# frozen_string_literal: true

require_relative "protected_diagnostics"

module DiscussionBridgeGhost
  # Identity admission is a weak-key set with immediate true values, NOT weak
  # proof values. A private outcome anchor owns the actual evidence. Even a
  # proof that refers to its own response can be collected with that outcome;
  # the registry never roots all native replies or matches equal-valued copies.
  class EvidenceRegistry
    include ProtectedDiagnostics

    ANCHOR = :@discussion_bridge_ghost_evidence_anchor

    class Anchor
      include ProtectedDiagnostics

      def initialize
        @issuers = {}.compare_by_identity
      end

      def retain(issuer, evidence)
        # Actual responses have one issuer. Refuse pathological reuse rather
        # than evict evidence still held by another legitimate consumer.
        return false if !@issuers.key?(issuer) && @issuers.size >= 8
        @issuers[issuer] = evidence
        true
      end

      def for_issuer(issuer)
        @issuers[issuer]
      end
    end

    def self.prepare(outcome)
      anchor = outcome.instance_variable_get(ANCHOR)
      return anchor if anchor.is_a?(Anchor)
      return nil if outcome.frozen?
      outcome.instance_variable_set(ANCHOR, Anchor.new)
    end

    def initialize
      @entries = ObjectSpace::WeakMap.new
      # Anchors must not point back to the registry/weak map. They retain only
      # this opaque identity, otherwise outcome->registry cycles defeat cleanup.
      @issuer = Object.new.freeze
    end

    def retain(outcome, evidence)
      anchor = self.class.prepare(outcome)
      return nil unless anchor && anchor.retain(@issuer, evidence)
      @entries[outcome] = true
      evidence
    end

    def [](outcome)
      return nil unless @entries[outcome] == true
      anchor = outcome.instance_variable_get(ANCHOR)
      anchor.for_issuer(@issuer) if anchor.is_a?(Anchor)
    end
  end
end
