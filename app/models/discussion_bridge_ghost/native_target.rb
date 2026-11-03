# frozen_string_literal: true

module DiscussionBridgeGhost
  class NativeTarget < ActiveRecord::Base
    include ProtectedDiagnostics

    self.table_name = "discussion_bridge_ghost_targets"
    has_many :installations,
             class_name: "DiscussionBridgeGhost::Installation",
             foreign_key: :native_target_id
    validates :public_id,
              :ghost_origin,
              :admin_origin,
              presence: true,
              uniqueness: true
    validates :public_id, format: { with: SecretEnvelope::UUID }
    validates :ghost_origin_key,
              :admin_origin_key,
              presence: true,
              uniqueness: true
    before_validation :set_origin_keys
    validate :preserve_target_identity, on: :update

    def with_native_writer(&block)
      reload
      NativeLock.synchronize(public_id, &block)
    end

    private

    def set_origin_keys
      protocol = WireProtocol.new
      self.ghost_origin_key = protocol.origin_key(ghost_origin)
      self.admin_origin_key = protocol.origin_key(admin_origin)
    rescue Error
      errors.add(
        :base,
        "Ghost and Admin addresses must be valid HTTPS origins."
      )
    end

    def preserve_target_identity
      if %w[
           public_id
           ghost_origin
           admin_origin
           ghost_origin_key
           admin_origin_key
         ].any? { |field| will_save_change_to_attribute?(field) }
        errors.add(:base, "Existing Ghost target identity cannot be rebound.")
      end
    end
  end
end

# == Schema Information
#
# Table name: discussion_bridge_ghost_targets
#
#  id               :bigint           not null, primary key
#  admin_origin     :text             not null
#  admin_origin_key :text             not null
#  ghost_origin     :text             not null
#  ghost_origin_key :text             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  public_id        :uuid             not null
#
# Indexes
#
#  idx_db_ghost_admin_origin_identity                     (admin_origin_key) UNIQUE
#  idx_db_ghost_public_origin_identity                    (ghost_origin_key) UNIQUE
#  index_discussion_bridge_ghost_targets_on_admin_origin  (admin_origin) UNIQUE
#  index_discussion_bridge_ghost_targets_on_ghost_origin  (ghost_origin) UNIQUE
#  index_discussion_bridge_ghost_targets_on_public_id     (public_id) UNIQUE
#
