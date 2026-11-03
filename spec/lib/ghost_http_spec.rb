# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridgeGhost::GhostHttp do
  def transport(origin = "https://ghost-native.example", guard: -> {})
    described_class.new(
      origin: origin,
      protocol: DiscussionBridgeGhost::WireProtocol.new,
      guard: guard,
      api_key: "a" * 24 + ":" + "12" * 32
    )
  end

  it "uses Core's filtered HTTP client with no environment proxy or ambient cookies" do
    client = FinalDestination::HTTP.new("ghost-native.example", 443, nil)
    FinalDestination::HTTP
      .expects(:new)
      .with("ghost-native.example", 443, nil)
      .returns(client)
    request =
      stub_request(:get, "https://ghost-native.example/ghost/api/admin/posts/")
        .with do |http|
          http.headers["Authorization"].start_with?("Ghost ") &&
            !http.headers.key?("Cookie")
        end
        .to_return(
          status: 200,
          headers: {
            "Content-Type" => "application/json"
          },
          body: '{"posts":[]}'
        )
    response =
      transport.request(
        "GET",
        "/ghost/api/admin/posts/",
        maximum_bytes: 100,
        authenticated: true
      )
    expect(response.bytes).to eq('{"posts":[]}')
    expect(request).to have_been_requested.once
    expect(client.use_ssl?).to eq(true)
    expect(client.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
    expect(client.proxy?).to eq(false)
    expect(client.max_retries).to eq(0)
  end

  it "uses the same pinned IDNA authority policy for the native Ghost connection" do
    request =
      stub_request(
        :get,
        "https://xn--bcher-kva.example/ghost/api/admin/posts/"
      ).to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json"
        },
        body: '{"posts":[]}'
      )
    result =
      transport("https://bücher.example").request(
        "GET",
        "/ghost/api/admin/posts/",
        maximum_bytes: 100,
        authenticated: true
      )
    expect(result.status).to eq(200)
    expect(request).to have_been_requested.once
  end

  it "does not make a native request after current authority is withdrawn" do
    request =
      stub_request(
        :get,
        "https://ghost-native.example/ghost/api/admin/posts/"
      ).to_return(status: 200)
    guard = -> { raise DiscussionBridgeGhost::Error.new("disabled") }
    expect {
      transport(guard: guard).request(
        "GET",
        "/ghost/api/admin/posts/",
        maximum_bytes: 100,
        authenticated: true
      )
    }.to raise_error(DiscussionBridgeGhost::Error, /disabled/)
    expect(request).not_to have_been_requested
  end

  it "leaves redirects unconsumed rather than forwarding the Ghost authorization header" do
    first =
      stub_request(
        :get,
        "https://ghost-native.example/ghost/api/admin/posts/"
      ).to_return(
        status: 302,
        headers: {
          "Location" => "https://foreign.example/"
        }
      )
    destination = stub_request(:get, "https://foreign.example/")
    expect {
      transport.request(
        "GET",
        "/ghost/api/admin/posts/",
        maximum_bytes: 100,
        authenticated: true
      )
    }.to raise_error(described_class::Failure)
    expect(first).to have_been_requested.once
    expect(destination).not_to have_been_requested
  end
end
