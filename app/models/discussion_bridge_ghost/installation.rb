# frozen_string_literal: true

module DiscussionBridgeGhost
  class Installation < ActiveRecord::Base
    include ProtectedDiagnostics

    self.table_name = "discussion_bridge_ghost_installations"
    belongs_to :native_target, class_name: "DiscussionBridgeGhost::NativeTarget"
    has_many :operational_records,
             class_name: "DiscussionBridgeGhost::OperationalRecord",
             foreign_key: :installation_id
    has_many :mutations,
             class_name: "DiscussionBridgeGhost::Mutation",
             foreign_key: :installation_id
    validates :public_id,
              :connection_public_id,
              presence: true,
              uniqueness: true
    validates :public_id, format: { with: SecretEnvelope::UUID }
    validates :connection_public_id, format: { with: /\Adbc_[a-f0-9]{24}\z/ }
    validates :encrypted_configuration, presence: true
    validates :configuration_revision,
              numericality: {
                only_integer: true,
                greater_than: 0
              }
    validates :last_sync_state,
              inclusion: {
                in: %w[not_run queued running complete attention disabled]
              }
    validate :preserve_installation_identity, on: :update

    def envelope
      SecretEnvelope.new(
        application_key: Rails.application.secret_key_base,
        installation_id: public_id
      )
    end

    def private_configuration
      envelope.decrypt("configuration", encrypted_configuration)
    end

    def assert_enabled!(expected_revision: nil)
      reload
      unless SiteSetting.discussion_bridge_ghost_enabled && enabled
        raise Error.new("disabled")
      end
      if expected_revision && configuration_revision != expected_revision
        raise Error.new("disabled")
      end
      true
    end

    private

    def preserve_installation_identity
      if %w[public_id connection_public_id native_target_id].any? { |field|
           will_save_change_to_attribute?(field)
         }
        errors.add(
          :base,
          "Existing Ghost installation identity cannot be rebound."
        )
      end
    end
  end
end

# == Schema Information
#
# Table name: discussion_bridge_ghost_installations
#
#  id                      :bigint           not null, primary key
#  configuration_revision  :bigint           default(1), not null
#  enabled                 :boolean          default(FALSE), not null
#  encrypted_configuration :text             not null
#  last_sync_completed_at  :datetime
#  last_sync_started_at    :datetime
#  last_sync_state         :string           default("not_run"), not null
#  last_sync_summary       :jsonb            not null
#  next_run_at             :datetime
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  connection_public_id    :string           not null
#  native_target_id        :bigint           not null
#  public_id               :uuid             not null
#
# Indexes
#
#  idx_db_ghost_due_installations                            (enabled,next_run_at)
#  idx_db_ghost_installation_connection                      (connection_public_id) UNIQUE
#  index_discussion_bridge_ghost_installations_on_public_id  (public_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (native_target_id => discussion_bridge_ghost_targets.id)
#
