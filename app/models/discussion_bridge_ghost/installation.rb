# frozen_string_literal: true

module DiscussionBridgeGhost
  class Installation < ActiveRecord::Base
    self.table_name = "discussion_bridge_ghost_installations"
    belongs_to :native_target, class_name: "DiscussionBridgeGhost::NativeTarget"
    has_many :operational_records, class_name: "DiscussionBridgeGhost::OperationalRecord", foreign_key: :installation_id
    has_many :mutations, class_name: "DiscussionBridgeGhost::Mutation", foreign_key: :installation_id
    validates :public_id, :connection_public_id, presence: true, uniqueness: true
    validates :public_id, format: { with: SecretEnvelope::UUID }
    validates :connection_public_id, format: { with: /\Adbc_[a-f0-9]{24}\z/ }
    validates :encrypted_configuration, presence: true
    validates :configuration_revision, numericality: { only_integer: true, greater_than: 0 }
    validates :last_sync_state, inclusion: { in: %w[not_run queued running complete attention disabled] }

    def envelope
      SecretEnvelope.new(application_key: Rails.application.secret_key_base, installation_id: public_id)
    end

    def private_configuration
      envelope.decrypt("configuration", encrypted_configuration)
    end

    def assert_enabled!(expected_revision: nil)
      reload
      unless SiteSetting.discussion_bridge_ghost_enabled && enabled &&
               (expected_revision.nil? || configuration_revision == expected_revision)
        raise Error.new("disabled")
      end
      true
    end
  end
end
