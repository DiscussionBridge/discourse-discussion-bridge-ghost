# frozen_string_literal: true

require "digest"

module DiscussionBridgeGhost
  # The session lock is shared by both directions and all job processes. Do not
  # hold a database transaction over Ghost HTTP requests. PostgreSQL releases
  # this lock on process/connection loss; every external effect checks ownership.
  module NativeLock
    def self.key(native_target_id)
      unless native_target_id.is_a?(String) && SecretEnvelope::UUID.match?(native_target_id)
        raise Error.new("configuration_invalid")
      end
      unsigned = Digest::SHA256.digest("discussionbridge-ghost-native-v1\0#{native_target_id}").unpack1("Q>")
      unsigned >= (1 << 63) ? unsigned - (1 << 64) : unsigned
    end

    def self.synchronize(native_target_id, pool: ActiveRecord::Base.connection_pool)
      selected = key(native_target_id)
      # A dedicated checkout is not the thread's normal ORM lease. Nested Rack
      # executor cleanup must not return this lock-holding session to the pool.
      connection = pool.checkout
      lease = nil
      acquired = false
      begin
        raise Error.new("native_lock_lost") unless connection.adapter_name == "PostgreSQL"
        acquired = connection.select_value("SELECT pg_try_advisory_lock(#{selected})")
        raise Error.new("native_lock_busy") unless acquired == true
        lease = Lease.new(connection, selected)
        lease.assert!
        yield lease
      ensure
        begin
          # Never unlock an unrelated replacement session. Loss is not success;
          # the caller retains its exact intent/receipt for reconciliation.
          connection.select_value("SELECT pg_advisory_unlock(#{selected})") if acquired && lease&.same_session?
        ensure
          pool.checkin(connection)
        end
      end
    end

    class Lease
      def initialize(connection, key)
        @connection = connection
        @session = connection.raw_connection
        @pid = connection.select_value("SELECT pg_backend_pid()")
        @high = (key >> 32) & 0xffff_ffff
        @low = key & 0xffff_ffff
      end

      def same_session?
        @connection.raw_connection.equal?(@session) &&
          @connection.select_value("SELECT pg_backend_pid()") == @pid
      rescue StandardError
        false
      end

      def assert!
        raise Error.new("native_lock_lost") unless same_session?
        owned = @connection.select_value(<<~SQL)
          SELECT EXISTS (
            SELECT 1 FROM pg_locks
            WHERE locktype = 'advisory' AND pid = pg_backend_pid()
              AND classid = #{@high}::oid AND objid = #{@low}::oid
              AND objsubid = 1 AND granted
          )
        SQL
        raise Error.new("native_lock_lost") unless owned == true
        true
      end
    end
  end
end
