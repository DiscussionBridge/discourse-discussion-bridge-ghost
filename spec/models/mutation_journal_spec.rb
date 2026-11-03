# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridgeGhost::MutationJournal do
  self.use_transactional_tests = false

  around do |example|
    base = Class.new(ActiveRecord::Base) { self.abstract_class = true }
    stub_const(Object, :GhostJournalCommitObserver, base) do
      begin
        base.establish_connection(
          ActiveRecord::Base.connection_db_config.configuration_hash.merge(
            pool: 1
          )
        )
        @observer_pool = base.connection_pool
        example.run
      ensure
        begin
          if @installation&.persisted?
            DiscussionBridgeGhost::OperationalRecord.where(
              installation_id: @installation.id
            ).delete_all
            DiscussionBridgeGhost::Mutation.where(
              installation_id: @installation.id
            ).delete_all
            @installation.delete
          end
          @target.delete if @target&.persisted?
        ensure
          @observer_pool&.disconnect!
          base.remove_connection
        end
      end
    end
  end

  before do
    SiteSetting.discussion_bridge_ghost_enabled = true
    SiteSetting.force_https = true
    suffix = SecureRandom.hex(8)
    @target =
      DiscussionBridgeGhost::NativeTarget.create!(
        public_id: SecureRandom.uuid,
        ghost_origin: "https://ghost-native-#{suffix}.example",
        admin_origin: "https://ghost-admin-#{suffix}.example"
      )
    id = SecureRandom.uuid
    envelope =
      DiscussionBridgeGhost::SecretEnvelope.new(
        application_key: Rails.application.secret_key_base,
        installation_id: id
      )
    @installation =
      DiscussionBridgeGhost::Installation.create!(
        native_target: @target,
        public_id: id,
        enabled: true,
        connection_public_id: "dbc_#{SecureRandom.hex(12)}",
        encrypted_configuration:
          envelope.encrypt(
            "configuration",
            { "secret" => "SYNTHETIC-private-value" }
          )
      )
    @clock = Time.utc(2026, 11, 3, 10)
  end

  def with_journal(app, secret: "SYNTHETIC-connection-secret-#{"x" * 20}")
    @installation.reload
    DiscussionBridgeGhost::NativeLock.synchronize(
      @installation.native_target.public_id
    ) do |lease|
      protocol = DiscussionBridgeGhost::WireProtocol.new
      transport =
        DiscussionBridgeGhost::RackTransport.new(
          protocol: protocol,
          connection_id: @installation.connection_public_id,
          connection_secret: secret,
          app: app,
          base_url: Discourse.base_url
        )
      journal =
        described_class.new(
          installation: @installation.reload,
          protocol: protocol,
          transport: transport,
          lease: lease,
          now: -> { @clock }
        )
      yield journal
    end
  end

  def response(code, status, retry_after: nil)
    [
      status,
      { "content-type" => "application/json" },
      [
        JSON.generate(
          "outcome" => "rejected",
          "code" => code,
          "retryable" => !retry_after.nil?,
          "retry_after_seconds" => retry_after,
          "correlation_id" => nil,
          "core_fallback" => false
        )
      ]
    ]
  end

  it "commits exact bytes before dispatch and replays a completed receipt after reconstruction" do
    raw = " { \"mutation_id\" : \"#{SecureRandom.uuid}\" }\n"
    received = []
    app =
      lambda do |env|
        # This independent backend cannot see an uncommitted fixture/savepoint.
        @observer_pool.with_connection do |connection|
          row =
            connection.select_one(
              "SELECT state, request_ciphertext FROM discussion_bridge_ghost_mutations WHERE installation_id = #{@installation.id}"
            )
          expect(row.fetch("state")).to eq("pending")
          request =
            @installation.envelope.decrypt(
              "journal_request",
              row.fetch("request_ciphertext"),
              binding: "claim:one"
            )
          expect(request.fetch("body_bytes")).to eq(raw)
          expect(connection.select_value("SELECT pg_backend_pid()")).not_to eq(
            ActiveRecord::Base.lease_connection.select_value(
              "SELECT pg_backend_pid()"
            )
          )
        end
        received << env.fetch("rack.input").read
        [204, {}, []]
      end
    with_journal(app) do |journal|
      expect(
        journal.call("claim:one", "V4-13", retained_body: raw).status
      ).to eq(204)
    end
    expect(received).to eq([raw])
    operation = @installation.mutations.sole
    expect(operation.state).to eq("completed")
    expect(operation.request_sha256).to eq(Digest::SHA256.hexdigest(raw))
    expect(operation.request_ciphertext).not_to include(
      JSON.parse(raw).fetch("mutation_id")
    )
    with_journal(
      ->(_env) { raise "must not dispatch completed work" }
    ) do |journal|
      expect(
        journal
          .call("claim:one", "V4-13") { raise "must not make another mutation" }
          .status
      ).to eq(204)
    end
    expect(
      @installation.operational_records.where(kind: "mutation_receipt").count
    ).to eq(1)
  end

  it "retains an uncertain request and retries the same mutation bytes with new client objects" do
    raw = JSON.generate("mutation_id" => SecureRandom.uuid)
    with_journal(
      ->(_env) { raise "SYNTHETIC-secret must not be exposed" }
    ) do |journal|
      expect {
        journal.call("claim:unknown", "V4-13", retained_body: raw)
      }.to raise_error(
        DiscussionBridgeGhost::Error,
        "The upstream response is invalid."
      )
    end
    expect(@installation.mutations.sole.state).to eq("pending")
    received = []
    app = ->(env) do
      received << env.fetch("rack.input").read
      [204, {}, []]
    end
    with_journal(app) do |journal|
      expect(
        journal
          .call("claim:unknown", "V4-13") { raise "new mutation forbidden" }
          .status
      ).to eq(204)
    end
    expect(received).to eq([raw])
    expect(@installation.mutations.count).to eq(1)
  end

  it "retains transient receipts, honors cooldown and then retries the same intent" do
    received = []
    app =
      lambda do |env|
        received << env.fetch("rack.input").read
        if received.length == 1
          response("rate_limited", 429, retry_after: 10)
        else
          [204, {}, []]
        end
      end
    with_journal(app) do |journal|
      expect(
        journal
          .call("claim:limited", "V4-13") do
            { "mutation_id" => SecureRandom.uuid }
          end
          .status
      ).to eq(429)
      @clock += 5
      expect(journal.call("claim:limited", "V4-13").status).to eq(429)
      expect(received.length).to eq(1)
      @clock += 6
      expect(journal.call("claim:limited", "V4-13").status).to eq(204)
    end
    expect(received.length).to eq(2)
    expect(received.uniq.length).to eq(1)
    expect(
      @installation.operational_records.where(kind: "mutation_receipt").count
    ).to eq(2)
    expect(@installation.mutations.sole.state).to eq("completed")
  end

  it "durably retains a typed source refusal after GC and reconstructs it without another dispatch" do
    html = "<p>Private synthetic native source.</p>"
    raw =
      JSON.generate(
        "mutation_id" => SecureRandom.uuid,
        "bridge_record" => {
          "direction" => "to_discourse",
          "external_id" => "gc-source",
          "canonical_url" => "#{@target.ghost_origin}/gc-source/",
          "title" => "Native proof lifetime source",
          "content_html" => html,
          "published" => true,
          "source_revision" => "native:gc1",
          "expected_source_revision" => nil,
          "source_created_at" => @clock.iso8601(3),
          "source_updated_at" => nil,
          "representation" => {
            "kind" => "full"
          },
          "source_content_sha256" => Digest::SHA256.hexdigest(html),
          "source_content_bytes" => html.bytesize
        }
      )
    collected = false
    # Ruby3.4 need not emit a line event for a Hash value expression. Trigger
    # collection at the actual consuming method entry, before proof lookup.
    trace =
      TracePoint.new(:call) do |event|
        if event.defined_class == DiscussionBridgeGhost::RackTransport &&
             event.method_id == :actual_source_refusal
          trace.disable
          3.times { GC.start(full_mark: true, immediate_sweep: true) }
          collected = true
        end
      end
    calls = 0
    app = ->(_env) do
      calls += 1
      response("invalid_field", 422)
    end
    with_journal(app) do |journal|
      trace.enable
      result = journal.call("source:gc", "V4-02", retained_body: raw)
      expect(collected).to eq(true)
      expect(result.source_refusal_shape?).to eq(true)
      expect(
        journal.confirmed_source_refusal("source:gc").value.fetch("code")
      ).to eq("invalid_field")
    end
    operation = @installation.mutations.sole
    original_request, original_response =
      operation.request_ciphertext,
      operation.response_ciphertext
    expect(
      operation.private_response.dig("dispatch_proof", "request_sha256")
    ).to eq(Digest::SHA256.hexdigest(raw))
    with_journal(
      ->(_env) { raise "must not repeat refused request" }
    ) do |journal|
      3.times { GC.start(full_mark: true, immediate_sweep: true) }
      expect(journal.confirmed_source_refusal("source:gc").status).to eq(422)
      expect(
        journal.call("source:gc", "V4-02", retained_body: raw).status
      ).to eq(422)
    end
    expect(calls).to eq(1)
    expect(operation.reload.request_ciphertext).to eq(original_request)
    expect(operation.response_ciphertext).to eq(original_response)
  ensure
    trace&.disable
  end

  it "does not automatically redeliver a known nonretryable refusal" do
    calls = 0
    app = ->(_env) do
      calls += 1
      response("authentication_failed", 401)
    end
    with_journal(app) do |journal|
      expect(
        journal
          .call("claim:refused", "V4-13") do
            { "mutation_id" => SecureRandom.uuid }
          end
          .status
      ).to eq(401)
      expect(journal.call("claim:refused", "V4-13").status).to eq(401)
      expect(journal.confirmed_source_refusal("claim:refused")).to eq(nil)
    end
    expect(calls).to eq(1)
    expect(@installation.mutations.sole.state).to eq("refused")
  end

  it "rejects changed route, bytes and corrupted retained digests before another dispatch" do
    raw = JSON.generate("mutation_id" => SecureRandom.uuid)
    calls = 0
    app = ->(_env) do
      calls += 1
      [204, {}, []]
    end
    with_journal(app) do |journal|
      journal.call("claim:bound", "V4-13", retained_body: raw)
      expect { journal.call("claim:bound", "V4-01") }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect {
        journal.call("claim:bound", "V4-13", retained_body: " #{raw}")
      }.to raise_error(DiscussionBridgeGhost::Error)
      @installation.mutations.sole.update!(request_sha256: "0" * 64)
      expect { journal.call("claim:bound", "V4-13") }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect(calls).to eq(1)
  end

  it "stops dispatch after disablement or configuration revision changes without deleting history" do
    calls = 0
    with_journal(
      ->(_env) do
        calls += 1
        [204, {}, []]
      end
    ) do |journal|
      journal.call("claim:before-disable", "V4-13") do
        { "mutation_id" => SecureRandom.uuid }
      end
      @installation.update!(enabled: false)
      expect { journal.call("claim:after-disable", "V4-13") }.to raise_error(
        DiscussionBridgeGhost::Error,
        /disabled/
      )
      @installation.update!(enabled: true, configuration_revision: 2)
      expect { journal.call("claim:after-change", "V4-13") }.to raise_error(
        DiscussionBridgeGhost::Error,
        /disabled/
      )
    end
    expect(calls).to eq(1)
    expect(@installation.mutations.count).to eq(1)
    expect(@installation.operational_records.count).to eq(1)
  end

  it "rejects dispatch inside an enclosing transaction before an intent can be rolled back" do
    calls = 0
    with_journal(
      ->(_env) do
        calls += 1
        [204, {}, []]
      end
    ) do |journal|
      ActiveRecord::Base.transaction do
        expect {
          journal.call("claim:outer", "V4-13") do
            { "mutation_id" => SecureRandom.uuid }
          end
        }.to raise_error(
          DiscussionBridgeGhost::Error,
          /enclosing database transaction/
        )
        raise ActiveRecord::Rollback
      end
    end
    expect(calls).to eq(0)
    expect(@installation.mutations.count).to eq(0)
  end

  it "does not replay unknown old requests under a newly configured connection" do
    with_journal(->(_env) { raise "synthetic uncertain result" }) do |journal|
      expect {
        journal.call("claim:old-scope", "V4-13") do
          { "mutation_id" => SecureRandom.uuid }
        end
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    operation = @installation.mutations.sole
    retained = operation.request_ciphertext
    @installation.update_columns(
      connection_public_id: "dbc_#{SecureRandom.hex(12)}",
      configuration_revision: 2
    )
    calls = 0
    with_journal(
      ->(_env) do
        calls += 1
        [204, {}, []]
      end
    ) do |journal|
      expect { journal.call("claim:old-scope", "V4-13") }.to raise_error(
        DiscussionBridgeGhost::Error,
        /identity/
      )
    end
    expect(calls).to eq(0)
    expect(operation.reload.request_ciphertext).to eq(retained)
    expect(operation.state).to eq("pending")
  end

  it "does not relabel completed or refused receipts after a native origin changes" do
    with_journal(->(_env) { [204, {}, []] }) do |journal|
      journal.call("claim:completed-origin", "V4-13") do
        { "mutation_id" => SecureRandom.uuid }
      end
    end
    with_journal(
      ->(_env) { response("authentication_failed", 401) }
    ) do |journal|
      journal.call("claim:refused-origin", "V4-13") do
        { "mutation_id" => SecureRandom.uuid }
      end
    end
    @target.update_columns(ghost_origin: "https://different-ghost.example")
    calls = 0
    with_journal(
      ->(_env) do
        calls += 1
        [204, {}, []]
      end
    ) do |journal|
      %w[claim:completed-origin claim:refused-origin].each do |key|
        expect { journal.call(key, "V4-13") }.to raise_error(
          DiscussionBridgeGhost::Error,
          /identity/
        )
      end
    end
    expect(calls).to eq(0)
    expect(@installation.mutations.order(:id).pluck(:state)).to eq(
      %w[completed refused]
    )
  end

  it "allows unchanged-identity credential rotation without replacing the pending bytes" do
    with_journal(->(_env) { raise "synthetic uncertain result" }) do |journal|
      expect {
        journal.call("claim:rotate", "V4-13") do
          { "mutation_id" => SecureRandom.uuid }
        end
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    original = @installation.mutations.sole.private_request
    @installation.update!(configuration_revision: 2)
    rotated_secret = "SYNTHETIC-rotated-secret-#{"y" * 32}"
    received = []
    with_journal(
      ->(env) do
        received << env.fetch("HTTP_X_DISCUSSIONBRIDGE_SECRET")
        [204, {}, []]
      end,
      secret: rotated_secret
    ) do |journal|
      expect(journal.call("claim:rotate", "V4-13").status).to eq(204)
    end
    expect(received).to eq([rotated_secret])
    expect(@installation.mutations.sole.private_request).to eq(original)
  end

  it "does not replay retained work under another forum origin or native lock identity" do
    app = ->(_env) { [204, {}, []] }
    with_journal(app) do |journal|
      journal.call("claim:original-realm", "V4-13") do
        { "mutation_id" => SecureRandom.uuid }
      end
    end
    retained = @installation.mutations.sole.request_ciphertext
    original_forum = Discourse.base_url
    calls = 0
    Discourse.stubs(:base_url).returns("https://other-forum.example")
    with_journal(
      ->(_env) do
        calls += 1
        [204, {}, []]
      end
    ) do |journal|
      expect { journal.call("claim:original-realm", "V4-13") }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    Discourse.stubs(:base_url).returns(original_forum)
    @target.update_columns(public_id: SecureRandom.uuid)
    with_journal(
      ->(_env) do
        calls += 1
        [204, {}, []]
      end
    ) do |journal|
      expect { journal.call("claim:original-realm", "V4-13") }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect(calls).to eq(0)
    expect(@installation.mutations.sole.request_ciphertext).to eq(retained)
  end

  it "atomically rolls back receipt append and latest response while retaining committed intent" do
    calls = 0
    app = ->(_env) do
      calls += 1
      [204, {}, []]
    end
    with_journal(app) do |journal|
      DiscussionBridgeGhost::Mutation
        .any_instance
        .stubs(:update!)
        .raises("synthetic receipt persistence failure")
      expect {
        journal.call("claim:atomic", "V4-13") do
          { "mutation_id" => SecureRandom.uuid }
        end
      }.to raise_error(/synthetic receipt/)
      DiscussionBridgeGhost::Mutation.any_instance.unstub(:update!)
      expect(@installation.operational_records.count).to eq(0)
      expect(@installation.mutations.sole.state).to eq("pending")
      expect(journal.call("claim:atomic", "V4-13").status).to eq(204)
    end
    expect(calls).to eq(2)
    expect(@installation.operational_records.count).to eq(1)
  end
end
