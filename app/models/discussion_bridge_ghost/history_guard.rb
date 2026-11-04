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
      revision = scope.pick(:revision)
      return nil if revision.nil? && missing && expected.nil?
      unless revision.is_a?(String) && SecretEnvelope::UUID.match?(revision)
        raise Error.new("identity_conflict")
      end
      raise Error.new("identity_conflict") if expected && revision != expected
      revision
    end
  end
end
