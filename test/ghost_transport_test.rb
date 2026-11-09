# frozen_string_literal: true

# Run with ruby test/ghost_transport_test.rb. The network is replaced in memory.
require "minitest/autorun"
require_relative "../lib/discussion_bridge_ghost/ghost_site"

class GhostTransportTest < Minitest::Test
  ID = "1234567890abcdef12345678"
  OTHER_ID = "abcdef1234567890abcdef12"
  URL = "https://ghost.example.test/hello/"
  UPDATED_AT = "2026-11-08T10:30:51.573Z"
  ARTICLE = {
    "id" => ID, "slug" => "hello", "title" => "Hello", "html" => "<p>Hello</p>",
    "status" => "published", "url" => URL, "updated_at" => UPDATED_AT,
  }.freeze

  def setup
    @requests = []
    @ghost = stub_transport(DiscussionBridgeGhost::GhostSite.new(URL, "#{'a' * 24}:#{'b' * 64}"))
  end

  def test_malformed_successful_article_is_classified
    respond_with("posts" => [ARTICLE])
    assert_equal ARTICLE, @ghost.article("post", ID)
    [ARTICLE.reject { |name, _| name == "updated_at" },
     ARTICLE.merge("updated_at" => "invalid"),
     ARTICLE.merge("html" => nil),
     ARTICLE.merge("id" => OTHER_ID)].each do |article|
      respond_with("posts" => [article])
      assert_invalid_response { @ghost.article("post", ID) }
    end
  end

  def test_update_uses_exact_ghost_revision_and_checks_returned_identity
    assert_invalid_response do
      @ghost.publish("post", ARTICLE.merge("updated_at" => nil), title: "Changed", html: "<p>Changed</p>")
    end
    assert_empty @requests

    respond_with("posts" => [ARTICLE.merge("id" => OTHER_ID)])
    assert_invalid_response do
      @ghost.publish("post", ARTICLE, title: "Changed", html: "<p>Changed</p>")
    end
    method, uri, options = @requests.fetch(0)
    assert_equal Net::HTTP::Put, method
    assert_match %r{/posts/#{ID}/\z}, uri.path
    assert_equal UPDATED_AT, options.fetch(:body).fetch("posts").first.fetch(:updated_at)
  end

  def test_current_content_lookup_requires_native_id_and_tag
    content_key = "a" * 26
    @ghost = stub_transport(DiscussionBridgeGhost::GhostSite.new(URL, content_key: content_key))
    respond_with("posts" => [ARTICLE])
    assert_equal ARTICLE, @ghost.public_entry("post", id: ID, tag: "bridge-topic")
    method, uri, options = @requests.fetch(0)
    assert_equal Net::HTTP::Get, method
    assert_match %r{/ghost/api/content/posts/\z}, uri.path
    query = URI.decode_www_form(uri.query).to_h
    assert_equal "visibility:public+tag:bridge-topic+id:'#{ID}'", query.fetch("filter")
    assert_equal content_key, query.fetch("key")
    refute options.fetch(:headers).key?("Authorization")

    respond_with("posts" => [])
    assert_nil @ghost.public_entry("post", id: ID, tag: "bridge-topic")
    respond_with("posts" => [ARTICLE.merge("id" => OTHER_ID)])
    assert_invalid_response { @ghost.public_entry("post", id: ID, tag: "bridge-topic") }
  end

  def test_public_article_uses_a_credential_free_https_request
    public_ghost = Class.new(DiscussionBridgeGhost::GhostSite)
    requests = []
    public_ghost.define_singleton_method(:request) do |method, uri, **options|
      requests << [method, uri, options]
      [200, "<p>Hello</p>"]
    end
    assert_equal [200, "<p>Hello</p>"], public_ghost.public_article(URL)
    method, uri, options = requests.fetch(0)
    assert_equal Net::HTTP::Get, method
    assert_equal URL, uri.to_s
    assert_equal({ "Accept" => "text/html" }, options.fetch(:headers))
    error = assert_raises(DiscussionBridgeGhost::Error) { public_ghost.public_article("http://ghost.example.test/hello/") }
    assert_equal "ghost_url_invalid", error.code
    assert_equal 1, requests.size
  end

  private

  def stub_transport(ghost)
    requests = @requests
    ghost.define_singleton_method(:request) do |method, uri, **options|
      requests << [method, uri, options]
      [200, @fake_body]
    end
    ghost
  end

  def respond_with(payload)
    @ghost.instance_variable_set(:@fake_body, JSON.generate(payload))
  end

  def assert_invalid_response(&block)
    error = assert_raises(DiscussionBridgeGhost::Error, &block)
    assert_equal "ghost_response_invalid", error.code
  end
end
