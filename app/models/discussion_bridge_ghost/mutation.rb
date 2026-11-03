# frozen_string_literal: true

module DiscussionBridgeGhost
  class Mutation < ActiveRecord::Base
    include ProtectedDiagnostics

    self.table_name = "discussion_bridge_ghost_mutations"
    belongs_to :installation, class_name: "DiscussionBridgeGhost::Installation"
    validates :operation_key,
              :route_id,
              :request_sha256,
              :request_ciphertext,
              presence: true
    validates :operation_key, uniqueness: { scope: :installation_id }
    validates :state, inclusion: { in: %w[pending completed refused] }
    validates :request_sha256, format: { with: /\A[a-f0-9]{64}\z/ }

    def private_request
      installation.envelope.decrypt(
        "journal_request",
        request_ciphertext,
        binding: operation_key
      )
    end

    def private_response
      return nil if response_ciphertext.nil?
      installation.envelope.decrypt(
        "journal_response",
        response_ciphertext,
        binding: operation_key
      )
    end
  end
end

# == Schema Information
#
# Table name: discussion_bridge_ghost_mutations
#
#  id                  :bigint           not null, primary key
#  operation_key       :text             not null
#  request_ciphertext  :text             not null
#  request_sha256      :string           not null
#  response_ciphertext :text
#  state               :string           default("pending"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  installation_id     :bigint           not null
#  route_id            :string           not null
#
# Indexes
#
#  idx_db_ghost_exact_mutation  (installation_id,operation_key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (installation_id => discussion_bridge_ghost_installations.id)
#
