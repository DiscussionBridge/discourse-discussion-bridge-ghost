# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/discussion_bridge_ghost/native_article"

RSpec.describe DiscussionBridgeGhost::NativeArticle do
  def source(html)
    {
      "source_id" => "post:24",
      "source_revision" => "post:24:version:2",
      "topic_id" => "15",
      "topic_url" => "https://forum.example/t/source-article/15",
      "title" => "Original source title",
      "content_sha256" => Digest::SHA256.hexdigest(html),
      "content_bytes" => html.bytesize,
      "source_created_at" => "2026-11-02T10:00:00.000Z",
      "source_updated_at" => "2026-11-03T12:00:00.125Z",
      "source_authors" => [{ "id" => "7", "name" => "Source author" }]
    }
  end

  def prepare(html, record: source(html), maximum: 1_048_576)
    described_class.new(
      protocol: DiscussionBridgeGhost::WireProtocol.new,
      forum_origin: "https://forum.example",
      source: record,
      html: html,
      maximum_bytes: maximum
    )
  end

  it "preserves complete rich article structure and immutable authorship/source bytes" do
    html =
      '<h2 id="heading">Café &amp; proof</h2><p>A <strong>complete</strong> article.</p><pre><code class="language-mermaid">flowchart LR&#10;A --&gt; B</code></pre><p><span class="math">\(x^2\)</span></p><table><thead><tr><th scope="col">Value</th></tr></thead><tbody><tr><td>42</td></tr></tbody></table>'
    record = source(html)
    before = Marshal.load(Marshal.dump(record))
    html = html.dup
    article = prepare(html, record: record)
    expect(article.original_html).to eq(html)
    expect(article.source).to eq(before)
    expect(article.publication_date).to eq("2026-11-03T12:00:00.000Z")
    expect(article.html).to include(
      'class="language-mermaid"',
      'class="math"',
      'scope="col"'
    )
    expect(article.source).to be_frozen
    expect(
      article.source.fetch("source_authors").first.fetch("name")
    ).to be_frozen
    record["source_authors"].first["name"] = "Changed caller"
    html.replace("Changed caller body")
    expect(article.source).to eq(before)
    expect(article.html).to include("complete")
    expect(article.inspect).not_to include("Source author", "complete")
  end

  it "anchors relative, fragment, query and scheme-relative targets to the source article" do
    html =
      '<p><a href="../16">Other</a><a href="#heading">Heading</a><a href="?print=1&amp;x=2">Query</a><img src="/uploads/image.png" srcset="/uploads/small.png 1x, //cdn.example/large.png 2x" alt="Original image"></p>'
    article = prepare(html)
    root = Nokogiri::HTML5.fragment(article.html)
    expect(root.css("a").map { |node| node["href"] }).to eq(
      %w[
        https://forum.example/t/16
        https://forum.example/t/source-article/15#heading
        https://forum.example/t/source-article/15?print=1&x=2
      ]
    )
    expect(root.at_css("img")["src"]).to eq(
      "https://forum.example/uploads/image.png"
    )
    expect(root.at_css("img")["srcset"]).to eq(
      "https://forum.example/uploads/small.png 1x, https://cdn.example/large.png 2x"
    )
  end

  it "anchors international relative paths and network authorities without rekeying original metadata" do
    html =
      '<p><a href="../café">Path</a><img src="//bücher.example/日本.png" alt="Unicode"></p>'
    article = prepare(html)
    root = Nokogiri::HTML5.fragment(article.html)
    expect(root.at_css("a")["href"]).to eq("https://forum.example/t/caf%C3%A9")
    expect(root.at_css("img")["src"]).to eq(
      "https://xn--bcher-kva.example/%E6%97%A5%E6%9C%AC.png"
    )
    expect(article.source).to eq(source(html))
  end

  it "retains absolute targets, author IDs and activity metadata without guessing replacements" do
    html = '<p><a href="https://other.example/exact?x=1#part">Link</a></p>'
    record = source(html)
    record["source_created_at"] = nil
    article = prepare(html, record: record)
    expect(article.html).to include(
      'href="https://other.example/exact?x=1#part"'
    )
    expect(article.source.fetch("source_created_at")).to eq(nil)
    expect(article.source.fetch("source_authors")).to eq(
      record.fetch("source_authors")
    )
    record["source_updated_at"] = nil
    expect { prepare(html, record: record) }.to raise_error(
      DiscussionBridgeGhost::Error
    ) { |e| expect(e.code).to eq("native_source_unavailable") }
  end

  it "rejects changed complete content, invalid UTF-8 and budget overflow before producing a publication" do
    html = "<p>Original source</p>"
    [
      source(html).merge("content_sha256" => "0" * 64),
      source(html).merge("content_bytes" => html.bytesize + 1)
    ].each do |record|
      expect { prepare(html, record: record) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect { prepare(html, maximum: html.bytesize - 1) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    invalid = "<p>\xff</p>".b
    expect { prepare(invalid) }.to raise_error(DiscussionBridgeGhost::Error)
  end

  it "rejects source topic links with another origin, ID, query or fragment" do
    html = "<p>Source</p>"
    %w[
      https://other.example/t/source/15
      https://forum.example/t/source/16
      https://forum.example/t/source/15?x=1
      https://forum.example/t/source/15#x
    ].each do |url|
      expect {
        prepare(html, record: source(html).merge("topic_url" => url))
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
  end

  it "refuses lossy native conversions and retains safe protected limitation details" do
    [
      '<p onclick="secret()">Text</p>',
      "<script>PRIVATE_SCRIPT</script><p>Text</p>",
      '<iframe src="https://other.example/"></iframe>',
      '<p data-private-function="PRIVATE_DATA">Text</p>',
      '<form action="https://other.example/"><input name="answer"></form>'
    ].each do |html|
      original = html.dup
      expect { prepare(html) }.to raise_error(
        described_class::Limitation
      ) do |error|
        expect(error.code).to eq("native_content_unrepresentable")
        expect(error.functions).not_to be_empty
        expect(error.inspect).not_to include(
          "PRIVATE_SCRIPT",
          "PRIVATE_DATA",
          "secret()"
        )
      end
      expect(html).to eq(original)
    end
  end

  it "rejects reserved publication identities in actual markup but permits quoted documentation text" do
    [
      '<p data-discussionbridge-resource="forged">Text</p>',
      "<!--discussionbridge-owned:forged--><p>Text</p>"
    ].each do |html|
      expect { prepare(html) }.to raise_error(described_class::Limitation)
    end
    article =
      prepare(
        '<pre><code>&lt;section data-discussionbridge-owned="example"&gt;</code></pre>'
      )
    expect(article.html).to include("data-discussionbridge-owned")
  end

  it "does not silently retarget unsupported CSS, malformed srcset, backslashes or unsafe schemes" do
    [
      '<p style="background:url(/uploads/image.png)">Text</p>',
      '<img src="/safe.png" srcset="/unsafe.png 0x">',
      '<a href="\\\\other.example/path">Wrong</a>',
      '<a href="javascript:alert(1)">Wrong</a>',
      '<img src="data:image/svg+xml,wrong">',
      '<a href="/broken%XX">Wrong</a>'
    ].each do |html|
      expect { prepare(html) }.to raise_error(described_class::Limitation)
    end
  end

  it "refuses parser repair and foreign namespaces rather than claiming complete native preservation" do
    [
      '<p a="one" a="two">Text</p>',
      '<svg><a href="https://other.example/">Text</a></svg>',
      "<table><p>Outside</p><tr><td>Cell</td></tr></table>"
    ].each do |html|
      expect { prepare(html) }.to raise_error(described_class::Limitation)
    end
  end

  it "does not turn browser-trimmed absolute URL whitespace into another relative path" do
    [
      '<a href=" https://other.example/exact">Wrong target risk</a>',
      '<img src="/upload.png ">'
    ].each do |html|
      expect { prepare(html) }.to raise_error(described_class::Limitation)
    end
  end
end
