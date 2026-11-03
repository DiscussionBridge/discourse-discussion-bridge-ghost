# frozen_string_literal: true

module DiscussionBridgeGhost
  class OperationalRecord < ActiveRecord::Base
    include ProtectedDiagnostics

    self.table_name = "discussion_bridge_ghost_records"
    belongs_to :installation, class_name: "DiscussionBridgeGhost::Installation"
    validates :kind, :record_key, :encrypted_payload, presence: true
    validates :record_key, uniqueness: { scope: %i[installation_id kind] }
    validates :mapping_public_id,
              format: {
                with: SecretEnvelope::UUID
              },
              allow_nil: true
    validate :preserve_mapping_locator, on: :update
    validates :native_guard_version, inclusion: { in: [2] }, allow_nil: true
    validates :native_assignment_version,
              inclusion: {
                in: [1]
              },
              allow_nil: true

    def private_payload
      installation.envelope.decrypt(
        "operational_record",
        encrypted_payload,
        binding: JSON.generate([kind, record_key])
      )
    end

    private

    def preserve_mapping_locator
      if will_save_change_to_mapping_public_id?
        errors.add(:base, "Retained work mapping metadata cannot be rebound.")
      end
    end
  end
end

# == Schema Information
#
# Table name: discussion_bridge_ghost_records
#
#  id                        :bigint           not null, primary key
#  encrypted_payload         :text             not null
#  kind                      :string           not null
#  native_assignment_version :integer
#  native_guard_version      :integer
#  record_key                :text             not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  installation_id           :bigint           not null
#  mapping_public_id         :uuid
#
# Indexes
#
#  idx_db_ghost_record_assignment  (installation_id,kind,native_assignment_version)
#  idx_db_ghost_record_guard       (installation_id,kind,native_guard_version)
#  idx_db_ghost_record_identity    (installation_id,kind,record_key) UNIQUE
#  idx_db_ghost_record_mapping     (installation_id,kind,mapping_public_id)
#
# Foreign Keys
#
#  fk_rails_...  (installation_id => discussion_bridge_ghost_installations.id)
#
