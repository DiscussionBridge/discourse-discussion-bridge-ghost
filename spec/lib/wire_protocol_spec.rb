# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridgeGhost::WireProtocol do
  it "rejects nonempty bodies on every GET route before transport dispatch" do
    protocol = described_class.new
    DiscussionBridge::CmsProtocol::SCHEMA
      .fetch("routes")
      .select { |route| route.fetch("method") == "GET" }
      .each do |route|
        fields = route.fetch("path").scan(/\{([^}]+)\}/).flatten
        path =
          fields.to_h do |field|
            [
              field,
              field == "source_id" ?
                "topic:12" :
                field == "source_revision" ? "revision:one" : SecureRandom.uuid
            ]
          end
        ["null", " ", "{}", "[]"].each do |raw|
          expect {
            protocol.prepare(route.fetch("id"), path: path, retained_body: raw)
          }.to raise_error(DiscussionBridgeGhost::Error)
        end
      end
    expect(protocol.prepare("V4-01").body_bytes).to eq(nil)
    expect(protocol.prepare("V4-01", retained_body: "").body_bytes).to eq(nil)
  end
end
