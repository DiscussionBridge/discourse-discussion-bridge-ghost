# frozen_string_literal: true

require "rails_helper"
require "cgi"

RSpec.describe DiscussionBridgeGhost::OwnedFragment do
  def fragment(
    native_id: "1234567890abcdef12345678",
    nonce: "ab" * 32,
    kind: "post",
    maximum_bytes: 1_048_576
  )
    described_class.new(
      resource_id: "a4147162-a4ab-4a43-99af-bbbf335189bd",
      native_id: native_id,
      nonce: nonce,
      kind: kind,
      maximum_bytes: maximum_bytes
    )
  end

  def publication(parser, body = "<p>Body</p>", revision: "source-1")
    attrs =
      parser.attributes.merge(
        "data-discussionbridge-source-revision" => revision,
        "data-discussionbridge-mode" => "full"
      )
    section =
      "<section #{attrs.map { |name, value| "#{name}=\"#{CGI.escapeHTML(value)}\"" }.join(" ")}>#{body}</section>"
    parser.wrap(section)
  end

  def current(parser, html)
    {
      "id" => "1234567890abcdef12345678",
      "type" => parser.kind,
      "html" => html,
      "updated_at" => "2026-11-03T12:00:00.000Z",
      "lexical" =>
        DiscussionBridgeGhost::OwnedLexical.new(fragment: parser).create(html)
    }
  end

  it "binds canonical UTF-8 tokens to an independently assembled v2 golden vector" do
    parser = fragment
    html =
      publication(
        parser,
        '<p title="A &amp; B">Café &amp; B&#160;<span class="math">\(x^2\)</span></p>'
      )
    observed = parser.extract(html)
    expect(observed.sha256).to eq(
      "ed1708f4fe9e7eded147302c8a8ba9d94ef10a1c933e822f4ce9029ad7e20d19"
    )
    expect(observed.canonical_bytes.encoding).to eq(Encoding::UTF_8)
    expect(observed.canonical_bytes).to include("Café & B\u00a0")
    expect(observed.inspect).not_to include("Body", "Café")
    expect(observed.frozen?).to eq(true)
  end

  it "compares actual full document and card spans without hashing unrelated wrappers" do
    parser = fragment
    html =
      publication(
        parser,
        "<table><tr><th>A</th></tr><tr><td>B &amp; C</td></tr></table>"
      )
    expected = parser.extract(html)
    page =
      "<!doctype html><html><head><title>Theme</title></head><body><article>#{html}</article><footer>Unrelated</footer></body></html>"
    actual =
      parser.extract(
        page,
        context: :document,
        expected: {
          "data-discussionbridge-mode" => "full"
        }
      )
    expect(actual.sha256).to eq(expected.sha256)
    expect(actual.html).to eq(html)
    expect(actual.start_byte).to eq(page.b.index(html.b))
    expect {
      parser.extract(
        page,
        context: :document,
        expected: {
          "data-discussionbridge-source-revision" => "wrong"
        }
      )
    }.to raise_error(DiscussionBridgeGhost::Error)
    expect(
      parser.extract(publication(parser, "<p>Changed</p>")).sha256
    ).not_to eq(expected.sha256)
  end

  it "preserves decoded entities and text while ignoring only incidental comments" do
    parser = fragment
    left =
      publication(
        parser,
        '<p title="A &amp; B">A &amp; B\n<code>graph TD; A--&gt;B</code></p>'
      )
    right =
      publication(
        parser,
        '<p title="A &#38; B">A &#38; B\n<!-- incidental --><code>graph TD; A--&gt;B</code></p>'
      )
    expect(parser.extract(left).sha256).to eq(parser.extract(right).sha256)
    expect(parser.extract(publication(parser, "<p>A\r\nB</p>")).sha256).to eq(
      parser.extract(publication(parser, "<p>A\nB</p>")).sha256
    )
  end

  it "requires unique active comment-node ownership rather than matching raw strings" do
    parser = fragment
    html = publication(parser)
    adversaries = [
      html + html,
      "<template>#{html}</template>",
      "<noscript>#{html}</noscript>",
      "<script>#{html}</script>",
      "<textarea>#{html}</textarea>",
      "<svg>#{html}</svg>",
      "<div hidden>#{html}</div>",
      "<div inert>#{html}</div>",
      "<div aria-hidden=TRUE>#{html}</div>",
      "<div style='display:none'>#{html}</div>",
      "<div style='visibility:hidden'>#{html}</div>",
      "<table>#{html}</table>",
      html.sub("<!--discussionbridge-owned:v2:end", "<!--broken-end"),
      html +
        '<section data-discussionbridge-owned="ghost-owned-fragment-v1"></section>',
      '<div title="' + html.gsub('"', "&quot;") + '"></div>',
      html.sub(
        "<p>Body</p>",
        "<!--discussionbridge-owned:unrelated--><p>Body</p>"
      )
    ]
    adversaries.each do |value|
      expect { parser.extract(value) }.to raise_error(
        DiscussionBridgeGhost::Error
      ),
      "unexpected ownership acceptance"
    end
    expect { fragment(nonce: "cd" * 32).extract(html) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    expect { fragment(kind: "page").extract(html) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
  end

  it "fails closed on legacy profiles, encoding, over-budget content and unavailable parser" do
    parser = fragment
    [
      "\xFF".b,
      "\uFEFF" + publication(parser),
      publication(parser) + "\x00",
      publication(parser).sub(
        "ghost-owned-fragment-v2",
        "ghost-owned-fragment-v1"
      ),
      publication(parser).sub(
        'data-discussionbridge-mode="full"',
        'data-discussionbridge-mode="unknown"'
      ),
      publication(parser).sub(
        'data-discussionbridge-source-revision="source-1"',
        'data-discussionbridge-source-revision=""'
      )
    ].each do |value|
      expect { parser.extract(value) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect {
      fragment(maximum_bytes: 10).extract(publication(parser))
    }.to raise_error(DiscussionBridgeGhost::Error)
    stub_const(Nokogiri, :VERSION, "incompatible") do
      expect { fragment }.to raise_error(DiscussionBridgeGhost::Error, /parser/)
    end
  end

  it "keeps exact multibyte prefix and suffix bytes when replacing an owned span" do
    parser = fragment
    before = publication(parser)
    after = publication(parser, "<p>Updated</p>", revision: "source-2")
    prefix, suffix = "<p>é🐕</p><!-- outside -->", "<p>尾</p>\r\n"
    result =
      parser.replace_span(
        prefix + before + suffix,
        after,
        baseline_sha256: parser.extract(before).sha256
      )
    expect(result.b).to eq(prefix.b + after.b + suffix.b)
    expect {
      parser.replace_span(
        prefix + before + suffix,
        after,
        baseline_sha256: "0" * 64
      )
    }.to raise_error(DiscussionBridgeGhost::Error)
  end

  it "updates only one native Lexical HTML span and preserves every unrelated value" do
    parser = fragment
    before = publication(parser)
    after = publication(parser, "<p>Updated</p>", revision: "source-2")
    native = current(parser, before)
    data = JSON.parse(native.fetch("lexical"))
    card = data.fetch("root").fetch("children").first
    prefix, suffix = "<p>é🐕</p><!-- before -->", "<!-- after --><p>尾</p>"
    card["html"] = prefix + before + suffix
    card["custom-property"] = { "values" => [1, 1.5, false, nil] }
    other = {
      "type" => "paragraph",
      "version" => 1,
      "children" => [{ "type" => "text", "text" => "Unrelated 🐕" }]
    }
    data["root"]["children"] << other
    native["lexical"] = JSON.generate(data)
    encoded =
      DiscussionBridgeGhost::OwnedLexical.new(fragment: parser).replace(
        current: native,
        html: after,
        expected_revision: native.fetch("updated_at"),
        baseline_sha256: parser.extract(before).sha256
      )
    expected = JSON.parse(JSON.generate(data))
    expected["root"]["children"][0]["html"] = prefix + after + suffix
    expect(JSON.parse(encoded)).to eq(expected)
    expect(JSON.parse(native["lexical"])).to eq(data)
  end

  it "refuses CAS, baseline, card ambiguity, hidden native edits and native type changes" do
    parser = fragment
    html = publication(parser)
    native = current(parser, html)
    writer = DiscussionBridgeGhost::OwnedLexical.new(fragment: parser)
    call = ->(record, revision, baseline) do
      writer.replace(
        current: record,
        html: html,
        expected_revision: revision,
        baseline_sha256: baseline
      )
    end
    baseline = parser.extract(html).sha256
    expect { call.call(native, "wrong", baseline) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    expect { call.call(native, native["updated_at"], "0" * 64) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    expect {
      call.call(native.merge("type" => "page"), native["updated_at"], baseline)
    }.to raise_error(DiscussionBridgeGhost::Error)
    data = JSON.parse(native["lexical"])
    data["root"]["children"] *= 2
    expect {
      call.call(
        native.merge("lexical" => JSON.generate(data)),
        native["updated_at"],
        baseline
      )
    }.to raise_error(DiscussionBridgeGhost::Error)
    expect {
      call.call(
        native.merge("lexical" => '{"root":{},"root":{}}'),
        native["updated_at"],
        baseline
      )
    }.to raise_error(DiscussionBridgeGhost::Error)
    expect {
      call.call(
        native.merge("html" => publication(parser, "<p>Native edit</p>")),
        native["updated_at"],
        baseline
      )
    }.to raise_error(DiscussionBridgeGhost::Error)
  end

  it "requires the retained draft binding for an explicit pending-to-real native ID transition" do
    draft = fragment(native_id: "pending")
    parser = fragment
    old_html = publication(draft)
    expect { draft.extract(old_html, context: :document) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    native = current(draft, old_html)
    writer = DiscussionBridgeGhost::OwnedLexical.new(fragment: parser)
    args = {
      current: native,
      html: publication(parser),
      expected_revision: native["updated_at"],
      baseline_sha256: draft.extract(old_html).sha256
    }
    expect { writer.replace(**args) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    result = writer.replace(**args, prior_fragment: draft)
    expect(JSON.parse(result)["root"]["children"][0]["html"]).to eq(
      publication(parser)
    )
    expect {
      writer.replace(
        **args,
        prior_fragment: fragment(native_id: "pending", nonce: "cd" * 32)
      )
    }.to raise_error(DiscussionBridgeGhost::Error)
  end
end
