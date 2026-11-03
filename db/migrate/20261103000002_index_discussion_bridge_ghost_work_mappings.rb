# frozen_string_literal: true

class IndexDiscussionBridgeGhostWorkMappings < ActiveRecord::Migration[7.0]
  def change
    # Public lookup metadata only. Retained encrypted payloads are unchanged;
    # older NULL locators are validated read-only, never silently backfilled.
    add_column :discussion_bridge_ghost_records, :mapping_public_id, :uuid
    add_index :discussion_bridge_ghost_records,
              %i[installation_id kind mapping_public_id],
              name: "idx_db_ghost_record_mapping"
  end
end
