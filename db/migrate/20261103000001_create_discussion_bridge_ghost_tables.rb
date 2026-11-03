# frozen_string_literal: true

class CreateDiscussionBridgeGhostTables < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_ghost_targets do |t|
      t.uuid :public_id, null: false
      t.text :ghost_origin, null: false
      t.text :admin_origin, null: false
      t.timestamps null: false
    end
    add_index :discussion_bridge_ghost_targets, :public_id, unique: true
    # A second connection to the same Ghost site shares the same native writer
    # target. Alias/identity changes require reconciliation, not another lock.
    add_index :discussion_bridge_ghost_targets, :ghost_origin, unique: true
    add_index :discussion_bridge_ghost_targets, :admin_origin, unique: true

    create_table :discussion_bridge_ghost_installations do |t|
      t.uuid :public_id, null: false
      t.bigint :native_target_id, null: false
      t.string :connection_public_id, null: false
      t.text :encrypted_configuration, null: false
      t.boolean :enabled, null: false, default: false
      t.bigint :configuration_revision, null: false, default: 1
      t.datetime :next_run_at
      t.string :last_sync_state, null: false, default: "not_run"
      t.datetime :last_sync_started_at
      t.datetime :last_sync_completed_at
      t.jsonb :last_sync_summary, null: false, default: {}
      t.timestamps null: false
    end
    add_index :discussion_bridge_ghost_installations, :public_id, unique: true
    add_index :discussion_bridge_ghost_installations, :connection_public_id, unique: true, name: "idx_db_ghost_installation_connection"
    add_index :discussion_bridge_ghost_installations, [:enabled, :next_run_at], name: "idx_db_ghost_due_installations"
    add_foreign_key :discussion_bridge_ghost_installations, :discussion_bridge_ghost_targets, column: :native_target_id

    create_table :discussion_bridge_ghost_records do |t|
      t.bigint :installation_id, null: false
      t.string :kind, null: false
      t.text :record_key, null: false
      t.text :encrypted_payload, null: false
      t.timestamps null: false
    end
    add_index :discussion_bridge_ghost_records, [:installation_id, :kind, :record_key], unique: true, name: "idx_db_ghost_record_identity"
    add_foreign_key :discussion_bridge_ghost_records, :discussion_bridge_ghost_installations, column: :installation_id

    create_table :discussion_bridge_ghost_mutations do |t|
      t.bigint :installation_id, null: false
      t.text :operation_key, null: false
      t.string :route_id, null: false
      t.string :request_sha256, null: false
      t.text :request_ciphertext, null: false
      t.text :response_ciphertext
      t.string :state, null: false, default: "pending"
      t.timestamps null: false
    end
    add_index :discussion_bridge_ghost_mutations, [:installation_id, :operation_key], unique: true, name: "idx_db_ghost_exact_mutation"
    add_foreign_key :discussion_bridge_ghost_mutations, :discussion_bridge_ghost_installations, column: :installation_id
    # No cascading deletes: disabling/removing an optional connector must not
    # erase native ownership, exact requests, historical ACKs or discussion.
  end
end
