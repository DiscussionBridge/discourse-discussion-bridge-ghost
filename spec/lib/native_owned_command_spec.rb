# frozen_string_literal: true

require "rails_helper"
require "cgi"
require_relative "../../lib/discussion_bridge_ghost/native_owned_command"

RSpec.describe DiscussionBridgeGhost::NativeOwnedCommand do
  RESOURCE = "a4147162-a4ab-4a43-99af-bbbf335189bd"
  NATIVE = "1234567890abcdef12345678"

  def fragment(native_id)
    DiscussionBridgeGhost::OwnedFragment.new(
      resource_id: RESOURCE,
      kind: "post",
      native_id: native_id,
      nonce: "ab" * 32,
      maximum_bytes: 262_144
    )
  end

  def publication(parser, command_id)
    attributes =
      parser.attributes.merge(
        "data-discussionbridge-source-revision" => "post:24:version:1",
        "data-discussionbridge-mode" => "full"
      )
    parser.stamp_command(
      parser.wrap(
        "<section #{attributes.map { |key, value| "#{key}=\"#{CGI.escapeHTML(value)}\"" }.join(" ")}><p>Owned body</p></section>"
      ),
      command_id: command_id
    )
  end

  def command(create: false)
    id = SecureRandom.uuid
    parser = fragment(create ? "pending" : NATIVE)
    desired = publication(parser, id)
    baseline = nil
    fields = {
      "slug" => "article",
      "title" => "Article",
      "status" => create ? "draft" : "published"
    }
    if create
      fields["lexical"] = DiscussionBridgeGhost::OwnedLexical.new(
        fragment: parser
      ).create(desired)
      fields["tags"] = [{ "name" => "#discussionbridge-resource-#{RESOURCE}" }]
    else
      old_html = publication(parser, SecureRandom.uuid)
      old_card = "<p>Unrelated prefix</p>#{old_html}<p>Unrelated suffix</p>"
      tree =
        JSON.parse(
          DiscussionBridgeGhost::OwnedLexical.new(fragment: parser).create(
            old_html
          )
        )
      tree["root"]["children"].first["html"] = old_card
      tree["root"]["children"].first["customNativeProperty"] = 1.5
      tree["root"]["children"].unshift(
        {
          "type" => "paragraph",
          "children" => [
            { "type" => "text", "text" => "Unrelated editor content" }
          ]
        }
      )
      baseline = {
        "id" => NATIVE,
        "type" => "post",
        "html" => old_card,
        "lexical" => JSON.generate(tree),
        "updated_at" => "2026-11-03T10:00:00.000Z",
        "slug" => "article",
        "tags" => [
          {
            "id" => "c" * 24,
            "name" => "#discussionbridge-resource-#{RESOURCE}"
          }
        ]
      }
      fields["id"] = NATIVE
      fields["updated_at"] = baseline.fetch("updated_at")
      fields["lexical"] = DiscussionBridgeGhost::OwnedLexical.new(
        fragment: parser
      ).replace(
        current: baseline,
        html: desired,
        expected_revision: baseline.fetch("updated_at"),
        baseline_sha256: parser.extract(old_card).sha256
      )
    end
    {
      "command_id" => id,
      "identity" => {
        "resource_id" => RESOURCE,
        "kind" => "post",
        "native_id" => create ? nil : NATIVE
      },
      "owner" => {
        "direction" => "from_discourse",
        "action" => create ? "create_draft" : "publish",
        "source_revision" => "post:24:version:1"
      },
      "baseline" => baseline,
      "candidate" => fields,
      "request" => {
        "maximum_bytes" => 262_144,
        "body_bytes" => JSON.generate("posts" => [fields])
      }
    }
  end

  def check(value, mode: "full")
    described_class.new(command: value, expected_mode: mode).validate!
  end

  def mutate_lexical(value)
    tree = JSON.parse(value.dig("candidate", "lexical"))
    yield tree
    value["candidate"]["lexical"] = JSON.generate(tree)
    value["request"]["body_bytes"] = JSON.generate(
      "posts" => [value.fetch("candidate")]
    )
  end

  it "binds each command inside the hashed fragment while retaining durable ownership nonce" do
    parser = fragment(NATIVE)
    first = publication(parser, SecureRandom.uuid)
    second = parser.stamp_command(first, command_id: SecureRandom.uuid)
    expect(parser.extract(first).sha256).not_to eq(
      parser.extract(second).sha256
    )
    expect(second).to include(
      "data-discussionbridge-fragment-nonce=\"#{parser.nonce}\""
    )
    expect(parser.extract(first).sha256).to eq(
      parser.extract(first + "<!--incidental-->").sha256
    )
  end

  it "accepts exact pending draft creation and preserves native cards, properties and raw surrounding HTML during an update" do
    expect(check(command(create: true))).to eq(true)
    value = command
    expect(check(value)).to eq(true)
    expect(value.dig("candidate", "lexical")).to include(
      "Unrelated editor content",
      "customNativeProperty",
      "Unrelated prefix",
      "Unrelated suffix"
    )
  end

  it "refuses removal of an unrelated editor node or native HTML-card property" do
    value = command
    mutate_lexical(value) { |tree| tree["root"]["children"].shift }
    expect { check(value) }.to raise_error(DiscussionBridgeGhost::Error)
    value = command
    mutate_lexical(value) do |tree|
      tree["root"]["children"].last.delete("customNativeProperty")
    end
    expect { check(value) }.to raise_error(DiscussionBridgeGhost::Error)
  end

  it "refuses a missing/wrong command marker, source revision, presentation mode or ownership nonce" do
    value = command
    value["command_id"] = SecureRandom.uuid
    expect { check(value) }.to raise_error(DiscussionBridgeGhost::Error)
    value = command
    value["owner"]["source_revision"] = "post:24:version:2"
    expect { check(value) }.to raise_error(DiscussionBridgeGhost::Error)
    expect { check(command, mode: "simple") }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    value = command
    mutate_lexical(value) do |tree|
      tree["root"]["children"].last["html"].gsub!("ab" * 32, "cd" * 32)
    end
    expect { check(value) }.to raise_error(DiscussionBridgeGhost::Error)
  end

  it "does not repurpose a marker already present in the retained baseline" do
    value = command
    value["baseline"]["html"] = value
      .dig("candidate", "lexical")
      .then do |bytes|
        JSON.parse(bytes).dig("root", "children").last.fetch("html")
      end
    expect { check(value) }.to raise_error(DiscussionBridgeGhost::Error)
  end

  it "does not permit removing the native resource tag or inserting unrelated cards during creation" do
    value = command
    value["candidate"]["tags"] = []
    value["request"]["body_bytes"] = JSON.generate(
      "posts" => [value.fetch("candidate")]
    )
    expect { check(value) }.to raise_error(DiscussionBridgeGhost::Error)
    value = command
    value["baseline"]["tags"].first.delete("id")
    value["candidate"]["tags"] = [{ "name" => "Unrelated tag" }]
    value["request"]["body_bytes"] = JSON.generate(
      "posts" => [value.fetch("candidate")]
    )
    expect { check(value) }.to raise_error(DiscussionBridgeGhost::Error)
    value = command(create: true)
    mutate_lexical(value) do |tree|
      tree["root"]["children"].unshift(
        { "type" => "paragraph", "children" => [] }
      )
    end
    expect { check(value) }.to raise_error(DiscussionBridgeGhost::Error)
  end
end
