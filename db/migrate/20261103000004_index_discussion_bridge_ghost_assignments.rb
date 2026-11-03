# frozen_string_literal: true

class IndexDiscussionBridgeGhostAssignments < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_ghost_records,
               :native_assignment_version,
               :integer
    add_index :discussion_bridge_ghost_records,
              %i[installation_id kind native_assignment_version],
              name: :idx_db_ghost_record_assignment
  end
end
