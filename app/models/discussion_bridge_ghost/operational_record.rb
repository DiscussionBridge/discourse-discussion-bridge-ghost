# frozen_string_literal: true

module DiscussionBridgeGhost
  class OperationalRecord < ActiveRecord::Base
    include ProtectedDiagnostics

    self.table_name = "discussion_bridge_ghost_records"
    belongs_to :installation, class_name: "DiscussionBridgeGhost::Installation"
    validates :kind, :record_key, :encrypted_payload, presence: true
    validates :record_key, uniqueness: { scope: %i[installation_id kind] }

    def private_payload
      installation.envelope.decrypt(
        "operational_record",
        encrypted_payload,
        binding: JSON.generate([kind, record_key])
      )
    end
  end
end

# == Schema Information
#
# Table name: discussion_bridge_ghost_records
#
#  id                :bigint           not null, primary key
#  encrypted_payload :text             not null
#  kind              :string           not null
#  record_key        :text             not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  installation_id   :bigint           not null
#
# Indexes
#
#  idx_db_ghost_record_identity  (installation_id,kind,record_key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (installation_id => discussion_bridge_ghost_installations.id)
#
