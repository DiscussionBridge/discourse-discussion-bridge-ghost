# frozen_string_literal: true

module DiscussionBridgeGhost
  class OperationalRecord < ActiveRecord::Base
    self.table_name = "discussion_bridge_ghost_records"
    belongs_to :installation, class_name: "DiscussionBridgeGhost::Installation"
    validates :kind, :record_key, :encrypted_payload, presence: true
    validates :record_key, uniqueness: { scope: [:installation_id, :kind] }

    def private_payload
      installation.envelope.decrypt("operational_record", encrypted_payload, binding: JSON.generate([kind, record_key]))
    end
  end
end
