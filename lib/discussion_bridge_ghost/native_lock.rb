# frozen_string_literal: true

require "digest"

module DiscussionBridgeGhost
  # The session lock is shared by both directions and all job processes. Do not
  # hold a database transaction over Ghost HTTP requests. PostgreSQL releases
  # this lock on process/connection loss; every external effect checks ownership.
  module NativeLock
    def self.key(native_target_id)
      unless native_target_id.is_a?(String) &&
               SecretEnvelope::UUID.match?(native_target_id)
        raise Error.new("configuration_invalid")
      end
      unsigned =
        Digest::SHA256.digest(
          "discussionbridge-ghost-native-v1\0#{native_target_id}"
        ).unpack1("Q>")
      unsigned >= (1 << 63) ? unsigned - (1 << 64) : unsigned
    end

    def self.synchronize(
      native_target_id,
      pool: ActiveRecord::Base.connection_pool
    )
      selected = key(native_target_id)
      # A dedicated checkout is not the thread's normal ORM lease. Nested Rack
      # executor cleanup must not return this lock-holding session to the pool.
      connection = pool.checkout
      lease = nil
      acquisition_attempted = false
      acquired = nil
      begin
        unless connection.adapter_name == "PostgreSQL"
          raise Error.new("native_lock_lost")
        end
        lease = Lease.new(connection, selected, native_target_id)
        acquisition_attempted = true
        acquired =
          connection.uncached do
            connection.select_value("SELECT pg_try_advisory_lock(#{selected})")
          end
        raise Error.new("native_lock_busy") unless acquired == true
        lease.assert!
        yield lease
      ensure
        lease&.invalidate!
        reusable = !acquisition_attempted || acquired == false
        begin
          # Never unlock an unrelated replacement session. Loss is not success;
          # uncertain acquisition or cleanup must discard this exact checkout.
          if acquired == true && lease&.same_session?
            reusable =
              !lease.session_owns_lock? ||
                connection.uncached do
                  connection.select_value(
                    "SELECT pg_advisory_unlock(#{selected})"
                  )
                end == true
          end
        rescue StandardError
          reusable = false
        ensure
          if reusable
            pool.checkin(connection)
          else
            begin
              pool.remove(connection)
            ensure
              connection.disconnect!
            end
          end
        end
      end
    end

    class Lease
      include ProtectedDiagnostics

      attr_reader :native_target_id

      def initialize(connection, key, native_target_id)
        @connection = connection
        @active = true
        @native_target_id = native_target_id.dup.freeze
        @session = connection.raw_connection
        @pid =
          connection.uncached do
            connection.select_value("SELECT pg_backend_pid()")
          end
        @high = (key >> 32) & 0xffff_ffff
        @low = key & 0xffff_ffff
      end

      def same_session?
        @connection.raw_connection.equal?(@session) &&
          @connection.uncached do
            @connection.select_value("SELECT pg_backend_pid()")
          end == @pid
      rescue StandardError
        false
      end

      def invalidate!
        @active = false
      end

      def session_owns_lock?
        return false unless same_session?
        query = <<~SQL
          SELECT EXISTS (
            SELECT 1 FROM pg_locks
            WHERE locktype = 'advisory' AND pid = pg_backend_pid()
              AND classid = #{@high}::oid AND objid = #{@low}::oid
              AND objsubid = 1 AND granted
          )
        SQL
        @connection.uncached { @connection.select_value(query) } == true
      end

      def assert!
        raise Error.new("native_lock_lost") unless @active && session_owns_lock?
        true
      end
    end
  end
end
