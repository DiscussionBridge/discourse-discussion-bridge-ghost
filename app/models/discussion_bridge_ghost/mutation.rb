# frozen_string_literal: true

module DiscussionBridgeGhost
  class Mutation < ActiveRecord::Base
    self.table_name = "discussion_bridge_ghost_mutations"
    belongs_to :installation, class_name: "DiscussionBridgeGhost::Installation"
    validates :operation_key, :route_id, :request_sha256, :request_ciphertext, presence: true
    validates :operation_key, uniqueness: { scope: :installation_id }
    validates :state, inclusion: { in: %w[pending completed refused] }
    validates :request_sha256, format: { with: /\A[a-f0-9]{64}\z/ }

    def private_request
      installation.envelope.decrypt("journal_request", request_ciphertext, binding: operation_key)
    end

    def private_response
      return nil if response_ciphertext.nil?
      installation.envelope.decrypt("journal_response", response_ciphertext, binding: operation_key)
    end
  end
end
