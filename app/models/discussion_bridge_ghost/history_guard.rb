# frozen_string_literal: true

module DiscussionBridgeGhost
  # A database-maintained invalidation token, never a native write grant.
  class HistoryGuard < ActiveRecord::Base
    self.table_name = "discussion_bridge_ghost_history_guards"

    def self.revision!(
      installation_id:,
      key:,
      expected: nil,
      lock: false,
      missing: false
    )
      scope = where(installation_id: installation_id, guard_key: key)
      scope = scope.lock if lock
      # Job/request query caches are not mutation authority. A trigger may have
      # run on another connection (or raw SQL) since the preceding read.
      revision = uncached { scope.pick(:revision) }
      return nil if revision.nil? && missing && expected.nil?
      unless revision.is_a?(String) && SecretEnvelope::UUID.match?(revision)
        raise Error.new("identity_conflict")
      end
      raise Error.new("identity_conflict") if expected && revision != expected
      revision
    end
  end
end

# == Schema Information
#
# Table name: discussion_bridge_ghost_history_guards
#
#  id              :bigint           not null, primary key
#  guard_key       :text             not null
#  revision        :uuid             not null
#  installation_id :bigint           not null
#
# Indexes
#
#  idx_db_ghost_history_guard  (installation_id,guard_key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (installation_id => discussion_bridge_ghost_installations.id)
#
