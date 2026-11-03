# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridgeGhost::NativeLock do
  # Rails 8.1 transactional fixtures pin one physical connection across threads.
  # PostgreSQL session locks are reentrant on that session, so they cannot prove
  # cross-session exclusion. These tests create no persisted rows and use the
  # real unpinned pool, rather than weakening the lock assertion or mocking SQL.
  self.use_transactional_tests = false

  around do |example|
    # Native CI's primary pool may have only two slots, one retained by the
    # harness. Own exactly two additional test sessions without changing that
    # pool, its fixtures or the database configuration used by Discourse.
    base = Class.new(ActiveRecord::Base) { self.abstract_class = true }
    stub_const(Object, :GhostConnectorLockTestRecord, base) do
      begin
        base.establish_connection(
          ActiveRecord::Base.connection_db_config.configuration_hash.merge(
            pool: 2
          )
        )
        @lock_pool = base.connection_pool
        example.run
      ensure
        @lock_pool&.disconnect!
        base.remove_connection
      end
    end
  end

  def synchronize(id, &block)
    described_class.synchronize(id, pool: @lock_pool, &block)
  end

  it "serializes actual PostgreSQL writers on distinct sessions for one target" do
    id = SecureRandom.uuid
    synchronize(id) do |lease|
      result =
        Thread
          .new do
            synchronize(id) { "unexpected second writer" }
          rescue DiscussionBridgeGhost::Error => error
            error.code
          end
          .value
      expect(result).to eq("native_lock_busy")
      expect(lease.assert!).to eq(true)
    end
    expect(synchronize(id) { "released" }).to eq("released")
  end

  it "detects lock loss even with the query cache enabled" do
    id = SecureRandom.uuid
    synchronize(id) do |lease|
      connection = lease.instance_variable_get(:@connection)
      connection.cache do
        expect(lease.assert!).to eq(true)
        key = described_class.key(id)
        connection.select_value("SELECT pg_advisory_unlock(#{key})")
        expect { lease.assert! }.to raise_error(
          DiscussionBridgeGhost::Error,
          /no longer owns/
        )
      end
    end
  end

  it "retains its dedicated session through actual Rack executor completion" do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.force_https = true
    protocol = DiscussionBridgeGhost::WireProtocol.new
    transport =
      DiscussionBridgeGhost::RackTransport.new(
        protocol: protocol,
        connection_id: "dbc_#{"a" * 24}",
        connection_secret: "SYNTHETIC-unknown-secret-#{"x" * 20}"
      )
    synchronize(SecureRandom.uuid) do |lease|
      result = transport.execute(protocol.prepare("V4-01"))
      expect(result.value.fetch("code")).to eq("authentication_failed")
      expect(lease.assert!).to eq(true)
    end
  end

  it "permanently expires an old lease even when its exact session acquires the target again" do
    id = SecureRandom.uuid
    previous = nil
    synchronize(id) { |lease| previous = lease }
    expect { previous.assert! }.to raise_error(DiscussionBridgeGhost::Error)
    synchronize(id) do |current|
      expect(current.instance_variable_get(:@pid)).to eq(
        previous.instance_variable_get(:@pid)
      )
      expect(current.assert!).to eq(true)
      expect { previous.assert! }.to raise_error(DiscussionBridgeGhost::Error)
    end
  end

  it "discards an unsafe cleanup session rather than returning its lock to the pool" do
    id = SecureRandom.uuid
    lost_pid = nil
    synchronize(id) do |lease|
      connection = lease.instance_variable_get(:@connection)
      lost_pid = connection.select_value("SELECT pg_backend_pid()")
      connection.stubs(:select_value).raises("synthetic cleanup query failure")
    end
    synchronize(id) do |lease|
      expect(lease.instance_variable_get(:@pid)).not_to eq(lost_pid)
      expect(lease.assert!).to eq(true)
    end
  end
end
