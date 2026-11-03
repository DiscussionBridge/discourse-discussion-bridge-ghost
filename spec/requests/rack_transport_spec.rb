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
      connection_id: "dbc_#{"a" * 24}",
      connection_secret: "SYNTHETIC-unknown-secret-#{"x" * 20}",
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
      "outcome" => "rejected",
      "code" => "authentication_failed",
      "retryable" => false,
      "retry_after_seconds" => nil,
      "correlation_id" => nil,
      "core_fallback" => false
    }
    status =
      DiscussionBridge::CmsProtocol::ERRORS.fetch(
        "authentication_failed"
      ).fetch("http")
    fake_app =
      lambda do |env|
        captured = env
        [
          status,
          { "content-type" => "application/json" },
          [JSON.generate(reply)]
        ]
      end
    transport(app: fake_app).execute(protocol.prepare("V4-01"))
    expect(captured.fetch("HTTPS")).to eq("on")
    expect(captured.fetch("HTTP_HOST")).to eq(
      URI.parse(Discourse.base_url).host
    )
    %w[
      HTTP_COOKIE
      HTTP_API_KEY
      HTTP_API_USERNAME
      HTTP_USER_API_KEY
      HTTP_X_SHARED_SESSION_KEY
      _DISCOURSE_CURRENT_USER
    ].each { |key| expect(captured).not_to have_key(key) }
  end

  it "keeps a real authenticated controller refusal identity-bound after GC while the result is held" do
    admin, author, category =
      Fabricate(:admin),
      Fabricate(:user),
      Fabricate(:category)
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_default_author_username = author.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    connection, secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Native Ghost refusal GC",
        platform: "ghost",
        author_user_id: author.id,
        allowed_origins: ["https://source.example"],
        allowed_directions: ["to_discourse"],
        allowed_lanes: ["news"]
      )
    connection.update!(
      cms_configuration: {
        "profile" => "ghost",
        "destination_origin" => "https://source.example",
        "publication_lane" => "news",
        "native_capabilities" => {
          "native_revision" => "native:gc",
          "supported_presentations" => ["simple"],
          "publication_kind" => "dynamic",
          "complete_content_supported" => true
        },
        "policy" => {
          "policy_revision" => SecureRandom.uuid,
          "enabled" => true,
          "selection" => "all_public",
          "category_ids" => [],
          "include_topic_ids" => [],
          "exclude_topic_ids" => [],
          "include_unlisted" => false,
          "publication_kind" => "dynamic",
          "presentation_mode" => "simple",
          "author_ids" => [],
          "taxonomy_ids" => []
        }
      }
    )
    html = "<p>Actual scoped controller rejection source.</p>"
    packet =
      protocol.prepare(
        "V4-02",
        body: {
          "mutation_id" => SecureRandom.uuid,
          "bridge_record" => {
            "direction" => "to_discourse",
            "external_id" => "gc-source",
            "canonical_url" => "https://source.example/gc-source/",
            "title" => "Native Ghost source proof",
            "content_html" => html,
            "published" => true,
            "source_revision" => "native:gc1",
            "expected_source_revision" => nil,
            "source_created_at" => "2026-11-03T10:00:00.000Z",
            "source_updated_at" => nil,
            "representation" => {
              "kind" => "full"
            },
            "source_content_sha256" => Digest::SHA256.hexdigest(html),
            "source_content_bytes" => html.bytesize
          }
        }
      )
    client =
      described_class.new(
        protocol: protocol,
        connection_id: connection.public_id,
        connection_secret: secret
      )
    handler = ->(post) do
      post.errors.add(:base, "Synthetic scoped native validation rejection")
    end
    DiscourseEvent.on(:validate_post, &handler)
    result = client.execute(packet)
    expect(result.status).to eq(422)
    expect(result.value.fetch("code")).to eq("invalid_field")
    expect(client.actual_source_refusal(result).nil?).to eq(false)
    3.times { GC.start(full_mark: true, immediate_sweep: true) }
    proof = client.actual_source_refusal(result)
    expect(proof.fetch("request_sha256")).to eq(packet.request_sha256)
    expect(proof.fetch("connection_id")).to eq(connection.public_id)
    expect(client.actual_source_refusal(result.dup)).to eq(nil)
    parsed_copy =
      protocol.response(
        packet,
        status: result.status,
        headers: result.response_headers,
        bytes: result.body_bytes
      )
    expect(client.actual_source_refusal(parsed_copy)).to eq(nil)
    expect(transport.actual_source_refusal(result)).to eq(nil)
  ensure
    DiscourseEvent.off(:validate_post, &handler) if handler
  end

  it "rejects a manufactured request packet and foreign base URL before dispatch" do
    called = false
    fake_app = ->(_env) do
      called = true
      raise "must not dispatch"
    end
    forged =
      DiscussionBridgeGhost::WireProtocol::Packet.new(
        owner: protocol,
        route: {
          "id" => "V4-01",
          "method" => "GET"
        },
        path: "/admin/users.json",
        query: "",
        body_bytes: nil
      )
    expect { transport(app: fake_app).execute(forged) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    expect(called).to eq(false)
    expect {
      described_class.new(
        protocol: protocol,
        connection_id: "dbc_#{"a" * 24}",
        connection_secret: "x" * 43,
        base_url: "https://foreign.example"
      )
    }.to raise_error(DiscussionBridgeGhost::Error)
  end
end
