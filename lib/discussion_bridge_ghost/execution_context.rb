# frozen_string_literal: true

require "securerandom"

module DiscussionBridgeGhost
  # One run's local lock/configuration boundary. Historical binding deliberately
  # excludes credentials and the per-run revision: same-identity rotation can
  # resume exact requests, but it cannot keep an already-running writer alive.
  class ExecutionContext
    include ProtectedDiagnostics

    attr_reader :installation, :protocol, :transport, :binding, :execution_id

    def initialize(installation:, protocol:, transport:, lease:)
      unless transport.is_a?(RackTransport) &&
               transport.bound_to?(
                 protocol,
                 installation.connection_public_id
               ) && lease.is_a?(NativeLock::Lease) &&
               lease.native_target_id == installation.native_target.public_id
        raise Error.new("identity_conflict")
      end
      @installation, @protocol, @transport, @lease =
        installation,
        protocol,
        transport,
        lease
      @revision = installation.configuration_revision
      @target_id = installation.native_target_id
      @binding = current_binding
      # Per-run transport attribution, not a historical binding or wire field.
      @execution_id = SecureRandom.uuid.freeze
      @history_guards = {}
    end

    def bound_to?(installation:, protocol:, transport:, lease:)
      @installation.equal?(installation) && @protocol.equal?(protocol) &&
        @transport.equal?(transport) && @lease.equal?(lease)
    end

    def assert!
      @lease.assert!
      @installation.assert_enabled!(expected_revision: @revision)
      unless @installation.native_target_id == @target_id &&
               current_binding == @binding
        raise Error.new("identity_conflict")
      end
      assert_history_guards!
      true
    end

    # A release proof remains a dependency through the native HTTP guards and
    # local receipt commits, not just when its witness was first looked up.
    def retain_history_guard!(key, revision)
      unless key.is_a?(String) && revision.is_a?(String) &&
               SecretEnvelope::UUID.match?(revision)
        raise Error.new("identity_conflict")
      end
      prior = @history_guards[key]
      raise Error.new("identity_conflict") if prior && prior != revision
      @history_guards[key.dup.freeze] = revision.dup.freeze
      assert!
    end

    def outside_transaction!
      if @installation
           .class
           .connection_pool
           .active_connection?
           &.transaction_open?
        raise Error.new("transaction_open")
      end
    end

    def read(route_id, path: {}, query: {})
      outside_transaction!
      assert!
      packet = @protocol.prepare(route_id, path: path, query: query)
      raise Error.new("identity_conflict") unless packet.method == "GET"
      result = @transport.execute(packet)
      assert!
      result
    end

    # The block performs only local state work. No Rack/Ghost calls belong here.
    def commit
      outside_transaction!
      @installation.with_lock do
        assert!
        assert_history_guards!(lock: true)
        yield
      end
    end

    private

    def assert_history_guards!(lock: false)
      @history_guards.sort.each do |key, revision|
        HistoryGuard.revision!(
          installation_id: @installation.id,
          key: key,
          expected: revision,
          lock: lock
        )
      end
    end

    def current_binding
      target = @installation.native_target.reload
      {
        "format" => "ghost-journal-identity-1",
        "installation_id" => @installation.public_id,
        "connection_id" => @installation.connection_public_id,
        "forum_origin" => Discourse.base_url,
        "native_target_id" => target.public_id,
        "ghost_origin" => target.ghost_origin,
        "admin_origin" => target.admin_origin,
        "normative_sha256" => WireProtocol::NORMATIVE_SHA256,
        "schema_sha256" => WireProtocol::SCHEMA_SHA256
      }.transform_values { |value| value.dup.freeze }.freeze
    end
  end
end
