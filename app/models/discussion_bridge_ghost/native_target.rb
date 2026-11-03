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
