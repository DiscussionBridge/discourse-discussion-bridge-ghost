# frozen_string_literal: true

module DiscussionBridgeGhost
  class NativeTarget < ActiveRecord::Base
    self.table_name = "discussion_bridge_ghost_targets"
    has_many :installations, class_name: "DiscussionBridgeGhost::Installation", foreign_key: :native_target_id
    validates :public_id, :ghost_origin, :admin_origin, presence: true, uniqueness: true
    validates :public_id, format: { with: SecretEnvelope::UUID }

    def with_native_writer(&block)
      NativeLock.synchronize(public_id, &block)
    end
  end
end

# == Schema Information
#
# Table name: discussion_bridge_ghost_targets
#
#  id           :bigint           not null, primary key
#  admin_origin :text             not null
#  ghost_origin :text             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  public_id    :uuid             not null
#
# Indexes
#
#  index_discussion_bridge_ghost_targets_on_admin_origin  (admin_origin) UNIQUE
#  index_discussion_bridge_ghost_targets_on_ghost_origin  (ghost_origin) UNIQUE
#  index_discussion_bridge_ghost_targets_on_public_id     (public_id) UNIQUE
#
