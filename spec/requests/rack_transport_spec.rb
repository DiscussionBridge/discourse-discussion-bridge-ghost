# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridgeGhost::RackTransport do
  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.force_https = true
  end

  def protocol
    @protocol ||= DiscussionBridgeGhost::WireProtocol.new
  end

  def transport(app: Rails.application)
    described_class.new(
      protocol: protocol,
      connection_id: "dbc_#{'a' * 24}",
      connection_secret: "SYNTHETIC-unknown-secret-#{'x' * 20}",
      app: app
    )
  end

  it "uses the real controller authentication without inheriting an ambient administrator" do
    sign_in(Fabricate(:admin))
    result = transport.execute(protocol.prepare("V4-01"))
    expect(result.value.fetch("outcome")).to eq("rejected")
    expect(result.value.fetch("code")).to eq("authentication_failed")
  end

  it "starts a fresh request without cookie, user API, global API or shared-session authority" do
    captured = nil
    reply = {
      "outcome" => "rejected", "code" => "authentication_failed", "retryable" => false,
      "retry_after_seconds" => nil, "correlation_id" => nil, "core_fallback" => false
    }
    status = DiscussionBridge::CmsProtocol::ERRORS.fetch("authentication_failed").fetch("http")
    fake_app = lambda do |env|
      captured = env
      [status, { "content-type" => "application/json" }, [JSON.generate(reply)]]
    end
    transport(app: fake_app).execute(protocol.prepare("V4-01"))
    expect(captured.fetch("HTTPS")).to eq("on")
    expect(captured.fetch("HTTP_HOST")).to eq(URI.parse(Discourse.base_url).host)
    %w[HTTP_COOKIE HTTP_API_KEY HTTP_API_USERNAME HTTP_USER_API_KEY HTTP_X_SHARED_SESSION_KEY _DISCOURSE_CURRENT_USER].each do |key|
      expect(captured).not_to have_key(key)
    end
  end

  it "rejects a manufactured request packet and foreign base URL before dispatch" do
    called = false
    fake_app = ->(_env) { called = true; raise "must not dispatch" }
    forged = DiscussionBridgeGhost::WireProtocol::Packet.new(
      owner: protocol,
      route: { "id" => "V4-01", "method" => "GET" },
      path: "/admin/users.json", query: "", body_bytes: nil
    )
    expect { transport(app: fake_app).execute(forged) }.to raise_error(DiscussionBridgeGhost::Error)
    expect(called).to eq(false)
    expect {
      described_class.new(protocol: protocol, connection_id: "dbc_#{'a' * 24}", connection_secret: "x" * 43, base_url: "https://foreign.example")
    }.to raise_error(DiscussionBridgeGhost::Error)
  end
end
