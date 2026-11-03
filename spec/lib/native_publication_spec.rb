# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/discussion_bridge_ghost/native_publication"
require_relative "../../lib/discussion_bridge_ghost/native_owned_command"

RSpec.describe DiscussionBridgeGhost::NativePublication do
  let(:protocol) { DiscussionBridgeGhost::WireProtocol.new }
  let(:source_html) do
    '<h2 id="proof">Rich content</h2><p>Full café source.</p><pre><code class="language-mermaid">flowchart LR&#10;A --&gt; B</code></pre><table><tbody><tr><td>42</td></tr></tbody></table>'
  end
  let(:source) do
    {
      "source_id" => "topic:15",
      "source_revision" => "post:24:version:2",
      "topic_id" => "15",
      "topic_url" => "https://forum.example/t/article/15",
      "title" => '<Original & "title">',
      "content_sha256" => Digest::SHA256.hexdigest(source_html),
      "content_bytes" => source_html.bytesize,
      "source_created_at" => "2026-11-02T10:00:00.123Z",
      "source_updated_at" => "2026-11-03T12:00:00.987Z",
      "source_authors" => [{ "id" => "7", "name" => '<Original & "author">' }]
    }
  end
  let(:article) do
    DiscussionBridgeGhost::NativeArticle.new(
      protocol: protocol,
      forum_origin: "https://forum.example",
      source: source,
      html: source_html,
      maximum_bytes: 1_048_576
    )
  end
  let(:mapping) do
    {
      "mapping_id" => SecureRandom.uuid,
      "resource_id" => SecureRandom.uuid,
      "connection_id" => "dbc_#{"a" * 24}",
      "source_id" => source.fetch("source_id"),
      "external_id" => "article",
      "mapping_revision" => SecureRandom.uuid,
      "destination_native_id" => nil,
      "canonical_url" => "https://ghost.example/article/",
      "retired_url_count" => 0,
      "mapping_state" => "pending",
      "presentation_mode" => "simple",
      "desired_source_revision" => source.fetch("source_revision"),
      "synchronized_source_revision" => nil,
      "publicly_verified_source_revision" => nil,
      "destination_native_revision" => nil,
      "source_created_at" => source.fetch("source_created_at"),
      "source_updated_at" => source.fetch("source_updated_at"),
      "synchronized_at" => nil,
      "publicly_verified_at" => nil
    }
  end
  let(:work) do
    {
      "work_id" => SecureRandom.uuid,
      "mapping_id" => mapping.fetch("mapping_id"),
      "source_id" => source.fetch("source_id"),
      "source_revision" => source.fetch("source_revision"),
      "policy_revision" => SecureRandom.uuid,
      "action" => "publish_revision",
      "state" => "leased",
      "attempt_cycle" => SecureRandom.uuid,
      "attempt" => 1,
      "lease_generation" => 3,
      "retry_at" => nil,
      "last_failure_code" => nil
    }
  end
  let(:fragment) do
    DiscussionBridgeGhost::OwnedFragment.new(
      resource_id: mapping.fetch("resource_id"),
      kind: "post",
      native_id: "pending",
      nonce: "ab" * 32,
      maximum_bytes: 1_048_576
    )
  end
  let(:command_id) { SecureRandom.uuid }

  def prepare(**changes)
    described_class.new(
      **{
        protocol: protocol,
        article: article,
        fragment: fragment,
        mapping: mapping,
        work: work,
        forum_name: '<Forum & "name">',
        command_id: command_id
      }.merge(changes)
    )
  end

  it "assembles complete owned content, escaped attribution and its chosen comments host without inventing a script endpoint" do
    value = prepare
    root = Nokogiri::HTML5.fragment(value.html)
    expect(root.at_css("h2").text).to eq("Rich content")
    expect(root.at_css("table td").text).to eq("42")
    expect(root.at_css("code")["class"]).to eq("language-mermaid")
    aside = root.at_css("aside.discussionbridge-publication")
    expect(aside.at_css("a").text).to eq('<Forum & "name">')
    expect(aside.at_css("a")["href"]).to eq(source.fetch("topic_url"))
    expect(aside.text).to include(
      '<Original & "author">',
      "post:24:version:2",
      DiscussionBridgeGhost::VERSION
    )
    expect(root.css("script,iframe")).to be_empty
    expect(
      root.at_css("[data-discussionbridge-comments]")[
        "data-discussionbridge-comments"
      ]
    ).to eq("simple")
    expect(
      fragment.extract(
        value.html,
        expected: {
          "data-discussionbridge-command" => command_id
        }
      ).html
    ).to eq(value.html)
    expect(value.representation).to eq(
      "kind" => "full",
      "source_content_sha256" => source.fetch("content_sha256")
    )
    expect(value.title).to eq(source.fetch("title"))
    expect(value.publication_date).to eq("2026-11-03T12:00:00.000Z")
    expect(aside.css("time").map { |node| node["datetime"] }).to eq(
      [source.fetch("source_created_at"), source.fetch("source_updated_at")]
    )
  end

  it "feeds the actual owned-card validator without losing article markup or granting native ownership" do
    value = prepare
    fields = {
      "title" => value.title,
      "slug" => "article",
      "status" => "draft",
      "lexical" =>
        DiscussionBridgeGhost::OwnedLexical.new(fragment: fragment).create(
          value.html
        ),
      "tags" => [
        {
          "name" => "#discussionbridge-resource-#{mapping.fetch("resource_id")}"
        }
      ]
    }
    command = {
      "command_id" => command_id,
      "identity" => {
        "resource_id" => mapping.fetch("resource_id"),
        "kind" => "post",
        "native_id" => nil
      },
      "owner" => {
        "direction" => "from_discourse",
        "action" => "create_draft",
        "source_revision" => source.fetch("source_revision")
      },
      "baseline" => nil,
      "candidate" => fields,
      "request" => {
        "maximum_bytes" => 1_048_576,
        "body_bytes" => JSON.generate("posts" => [fields])
      }
    }
    expect(
      DiscussionBridgeGhost::NativeOwnedCommand.new(
        command: command,
        expected_mode: "simple"
      ).validate!
    ).to eq(true)
    expect(
      JSON
        .parse(fields.fetch("lexical"))
        .dig("root", "children")
        .first
        .fetch("html")
    ).to eq(value.html)
  end

  it "keeps output independent of later caller edits and omits an actually unknown source creation time" do
    source["source_created_at"] = nil
    value = prepare
    original = value.html.dup
    source["source_authors"].first["name"] = "Different caller"
    mapping["presentation_mode"] = "full"
    work["source_revision"] = "later"
    expect(value.html).to eq(original)
    expect(value.html).to be_frozen
    expect(value.source).to be_frozen
    expect(value.representation).to be_frozen
    expect(value.inspect).not_to include("café", "Original", "Forum")
    expect(Nokogiri::HTML5.fragment(value.html).css("time").length).to eq(1)
  end

  it "supports all declared modes and page/post fragments, without converting preparation to authority" do
    %w[simple full interactive].each do |mode|
      mapping["presentation_mode"] = mode
      %w[post page].each do |kind|
        parser =
          DiscussionBridgeGhost::OwnedFragment.new(
            resource_id: mapping.fetch("resource_id"),
            kind: kind,
            native_id: "a" * 24,
            nonce: "ab" * 32,
            maximum_bytes: 1_048_576
          )
        value = prepare(fragment: parser)
        expect(parser.extract(value.html).html).to eq(value.html)
        expect(value.html).to include(
          "data-discussionbridge-comments=\"#{mode}\""
        )
      end
    end
  end

  it "rejects another mapping, source edition, resource or existing native identity instead of rekeying" do
    work # Materialize identity before mutating its defining mapping.
    other = mapping.merge("mapping_id" => SecureRandom.uuid)
    expect { prepare(mapping: other) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    other = mapping.merge("source_id" => "topic:16")
    expect { prepare(mapping: other) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    expect {
      prepare(work: work.merge("source_revision" => "changed"))
    }.to raise_error(DiscussionBridgeGhost::Error)
    expect {
      prepare(mapping: mapping.merge("desired_source_revision" => "changed"))
    }.to raise_error(DiscussionBridgeGhost::Error)
    expect {
      prepare(mapping: mapping.merge("resource_id" => SecureRandom.uuid))
    }.to raise_error(DiscussionBridgeGhost::Error)
    expect {
      prepare(mapping: mapping.merge("destination_native_id" => "a" * 24))
    }.to raise_error(DiscussionBridgeGhost::Error)
    expect {
      prepare(mapping: mapping.merge("mapping_state" => "withdrawn"))
    }.to raise_error(DiscussionBridgeGhost::Error)
  end

  it "refuses withdrawal, terminal/unclaimed work and invalid labels/IDs before generating markup" do
    expect {
      prepare(
        work: work.merge("action" => "withdraw", "source_revision" => nil)
      )
    }.to raise_error(DiscussionBridgeGhost::Error)
    %w[pending synchronized verified failed].each do |state|
      expect { prepare(work: work.merge("state" => state)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect {
      prepare(work: work.merge("lease_generation" => 0))
    }.to raise_error(DiscussionBridgeGhost::Error)
    expect { prepare(command_id: "not-a-command") }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    expect { prepare(forum_name: "") }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    expect { prepare(article: Object.new) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
  end

  it "does not silently truncate a full source when assembled attribution exceeds the native card bound" do
    tiny =
      DiscussionBridgeGhost::OwnedFragment.new(
        resource_id: mapping.fetch("resource_id"),
        kind: "post",
        native_id: "pending",
        nonce: "ab" * 32,
        maximum_bytes: 256
      )
    expect { prepare(fragment: tiny) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    expect(article.original_html).to eq(source_html)
    expect(article.source.fetch("content_bytes")).to eq(source_html.bytesize)
  end
end
