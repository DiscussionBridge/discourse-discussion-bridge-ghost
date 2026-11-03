# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridgeGhost::MutationJournal do
  before do
    SiteSetting.discussion_bridge_ghost_enabled = true
    SiteSetting.force_https = true
    target = DiscussionBridgeGhost::NativeTarget.create!(
      public_id: SecureRandom.uuid, ghost_origin: "https://ghost-native.example", admin_origin: "https://ghost-admin.example"
    )
    id = SecureRandom.uuid
    envelope = DiscussionBridgeGhost::SecretEnvelope.new(
      application_key: Rails.application.secret_key_base, installation_id: id
    )
    @installation = DiscussionBridgeGhost::Installation.create!(
      native_target: target, public_id: id, enabled: true,
      connection_public_id: "dbc_#{SecureRandom.hex(12)}",
      encrypted_configuration: envelope.encrypt("configuration", { "secret" => "SYNTHETIC-private-value" })
    )
    @clock = Time.utc(2026, 11, 3, 10)
  end

  def with_journal(app)
    DiscussionBridgeGhost::NativeLock.synchronize(@installation.native_target.public_id) do |lease|
      protocol = DiscussionBridgeGhost::WireProtocol.new
      transport = DiscussionBridgeGhost::RackTransport.new(
        protocol: protocol,
        connection_id: @installation.connection_public_id,
        connection_secret: "SYNTHETIC-connection-secret-#{'x' * 20}",
        app: app,
        base_url: Discourse.base_url
      )
      journal = described_class.new(
        installation: @installation.reload, protocol: protocol, transport: transport, lease: lease, now: -> { @clock }
      )
      yield journal
    end
  end

  def response(code, status, retry_after: nil)
    [status, { "content-type" => "application/json" }, [JSON.generate(
      "outcome" => "rejected", "code" => code, "retryable" => !retry_after.nil?,
      "retry_after_seconds" => retry_after, "correlation_id" => nil, "core_fallback" => false
    )]]
  end

  it "commits exact bytes before dispatch and replays a completed receipt after reconstruction" do
    raw = " { \"mutation_id\" : \"#{SecureRandom.uuid}\" }\n"
    received = []
    app = lambda do |env|
      operation = @installation.mutations.sole
      expect(operation.state).to eq("pending")
      expect(operation.private_request.fetch("body_bytes")).to eq(raw)
      received << env.fetch("rack.input").read
      [204, {}, []]
    end
    with_journal(app) { |journal| expect(journal.call("claim:one", "V4-13", retained_body: raw).status).to eq(204) }
    expect(received).to eq([raw])
    operation = @installation.mutations.sole
    expect(operation.state).to eq("completed")
    expect(operation.request_sha256).to eq(Digest::SHA256.hexdigest(raw))
    expect(operation.request_ciphertext).not_to include(JSON.parse(raw).fetch("mutation_id"))
    with_journal(->(_env) { raise "must not dispatch completed work" }) do |journal|
      expect(journal.call("claim:one", "V4-13") { raise "must not make another mutation" }.status).to eq(204)
    end
    expect(@installation.operational_records.where(kind: "mutation_receipt").count).to eq(1)
  end

  it "retains an uncertain request and retries the same mutation bytes with new client objects" do
    raw = JSON.generate("mutation_id" => SecureRandom.uuid)
    with_journal(->(_env) { raise "SYNTHETIC-secret must not be exposed" }) do |journal|
      expect { journal.call("claim:unknown", "V4-13", retained_body: raw) }.to raise_error(
        DiscussionBridgeGhost::Error, "The upstream response is invalid."
      )
    end
    expect(@installation.mutations.sole.state).to eq("pending")
    received = []
    app = ->(env) { received << env.fetch("rack.input").read; [204, {}, []] }
    with_journal(app) do |journal|
      expect(journal.call("claim:unknown", "V4-13") { raise "new mutation forbidden" }.status).to eq(204)
    end
    expect(received).to eq([raw])
    expect(@installation.mutations.count).to eq(1)
  end

  it "retains transient receipts, honors cooldown and then retries the same intent" do
    received = []
    app = lambda do |env|
      received << env.fetch("rack.input").read
      received.length == 1 ? response("rate_limited", 429, retry_after: 10) : [204, {}, []]
    end
    with_journal(app) do |journal|
      expect(journal.call("claim:limited", "V4-13") { { "mutation_id" => SecureRandom.uuid } }.status).to eq(429)
      @clock += 5
      expect(journal.call("claim:limited", "V4-13").status).to eq(429)
      expect(received.length).to eq(1)
      @clock += 6
      expect(journal.call("claim:limited", "V4-13").status).to eq(204)
    end
    expect(received.length).to eq(2)
    expect(received.uniq.length).to eq(1)
    expect(@installation.operational_records.where(kind: "mutation_receipt").count).to eq(2)
    expect(@installation.mutations.sole.state).to eq("completed")
  end

  it "does not automatically redeliver a known nonretryable refusal" do
    calls = 0
    app = ->(_env) { calls += 1; response("authentication_failed", 401) }
    with_journal(app) do |journal|
      expect(journal.call("claim:refused", "V4-13") { { "mutation_id" => SecureRandom.uuid } }.status).to eq(401)
      expect(journal.call("claim:refused", "V4-13").status).to eq(401)
      expect(journal.confirmed_source_refusal("claim:refused")).to eq(nil)
    end
    expect(calls).to eq(1)
    expect(@installation.mutations.sole.state).to eq("refused")
  end

  it "rejects changed route, bytes and corrupted retained digests before another dispatch" do
    raw = JSON.generate("mutation_id" => SecureRandom.uuid)
    calls = 0
    app = ->(_env) { calls += 1; [204, {}, []] }
    with_journal(app) do |journal|
      journal.call("claim:bound", "V4-13", retained_body: raw)
      expect { journal.call("claim:bound", "V4-01") }.to raise_error(DiscussionBridgeGhost::Error)
      expect { journal.call("claim:bound", "V4-13", retained_body: " #{raw}") }.to raise_error(DiscussionBridgeGhost::Error)
      @installation.mutations.sole.update!(request_sha256: "0" * 64)
      expect { journal.call("claim:bound", "V4-13") }.to raise_error(DiscussionBridgeGhost::Error)
    end
    expect(calls).to eq(1)
  end

  it "stops dispatch after disablement or configuration revision changes without deleting history" do
    calls = 0
    with_journal(->(_env) { calls += 1; [204, {}, []] }) do |journal|
      journal.call("claim:before-disable", "V4-13") { { "mutation_id" => SecureRandom.uuid } }
      @installation.update!(enabled: false)
      expect { journal.call("claim:after-disable", "V4-13") }.to raise_error(DiscussionBridgeGhost::Error, /disabled/)
      @installation.update!(enabled: true, configuration_revision: 2)
      expect { journal.call("claim:after-change", "V4-13") }.to raise_error(DiscussionBridgeGhost::Error, /disabled/)
    end
    expect(calls).to eq(1)
    expect(@installation.mutations.count).to eq(1)
    expect(@installation.operational_records.count).to eq(1)
  end
end
