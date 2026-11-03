# frozen_string_literal: true

require "digest"
require "json"
require "nokogiri"
require "crass"

module DiscussionBridgeGhost
  # Component-defined rendered-content proof, NOT an ownership grant or a
  # sanitizer. The caller must supply its retained binding and current authority.
  # Raw sentinels locate surgery bytes; actual DOM ancestry proves what they
  # delimit. Never relabel old v1 objects or infer ownership from public markers.
  class OwnedFragment
    include ProtectedDiagnostics

    PROFILE = "ghost-owned-fragment-v2"
    PARSER = "nokogiri-html5-1.19.4"
    HTML_NAMESPACE = "http://www.w3.org/1999/xhtml"
    XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/"
    RESERVED = /<!--discussionbridge-owned:/i
    INACTIVE = %w[
      template
      noscript
      textarea
      title
      xmp
      plaintext
      iframe
      script
      style
      svg
      math
    ].freeze
    OPTIONS = {
      encoding: "UTF-8",
      max_errors: 100,
      max_tree_depth: 400,
      max_attributes: 400,
      parse_noscript_content_as_text: true
    }.freeze

    Snapshot =
      Struct.new(
        :start_byte,
        :end_byte,
        :html,
        :canonical_bytes,
        :sha256,
        keyword_init: true
      ) { include ProtectedDiagnostics }

    attr_reader :resource_id, :kind, :native_id, :nonce, :maximum_bytes

    def initialize(resource_id:, kind:, native_id:, nonce:, maximum_bytes:)
      valid =
        resource_id.is_a?(String) && SecretEnvelope::UUID.match?(resource_id) &&
          %w[post page].include?(kind) && native_id.is_a?(String) &&
          /\A(?:[a-f0-9]{24}|pending)\z/.match?(native_id) &&
          nonce.is_a?(String) && /\A[a-f0-9]{64}\z/.match?(nonce) &&
          maximum_bytes.is_a?(Integer) && maximum_bytes.positive?
      raise Error.new("identity_conflict") unless valid
      unless Nokogiri::VERSION == "1.19.4" && Nokogiri.respond_to?(:HTML5) &&
               Gem.loaded_specs["crass"]&.version&.to_s == "1.0.7"
        raise Error.new("native_representation_unavailable")
      end
      @resource_id, @kind, @native_id, @nonce =
        [resource_id, kind, native_id, nonce].map { |value| value.dup.freeze }
      @maximum_bytes = maximum_bytes
      suffix = "#{@resource_id}:#{@kind}:#{@native_id}:#{@nonce}"
      @begin_marker = "<!--discussionbridge-owned:v2:begin:#{suffix}-->".freeze
      @end_marker = "<!--discussionbridge-owned:v2:end:#{suffix}-->".freeze
    end

    def attributes
      {
        "data-discussionbridge-owned" => PROFILE,
        "data-discussionbridge-resource" => @resource_id,
        "data-discussionbridge-native-id" => @native_id,
        "data-discussionbridge-fragment-nonce" => @nonce
      }.freeze
    end

    def wrap(section_html)
      html = @begin_marker + utf8(section_html) + @end_marker
      result = extract(html)
      assert!(result.start_byte.zero? && result.end_byte == html.bytesize)
      html.freeze
    end

    def extract(html, context: :card, expected: {})
      source = utf8(html)
      assert!(%i[card document].include?(context) && expected.is_a?(Hash))
      assert!(@native_id != "pending") if context == :document
      bytes = source.b
      assert!(bytes.scan(RESERVED).length == 2)
      first = bytes.index(@begin_marker.b)
      last = bytes.index(@end_marker.b)
      assert!(
        !first.nil? && !last.nil? && last >= first + @begin_marker.bytesize
      )
      finish = last + @end_marker.bytesize
      root = parse(source, context)
      owned, comments = [], []
      root.traverse do |node|
        if node.element? && node.key?("data-discussionbridge-owned")
          owned << node
        end
        comments << node if node.comment?
      end
      assert!(owned.length == 1)
      section = owned.first
      beginning =
        comments.select { |node| node.content == @begin_marker[4...-3] }
      ending = comments.select { |node| node.content == @end_marker[4...-3] }
      assert!(beginning.length == 1 && ending.length == 1)
      assert!(
        beginning.first.next_sibling == section &&
          section.next_sibling == ending.first &&
          beginning.first.parent == section.parent &&
          section.parent == ending.first.parent
      )
      assert!(section.name == "section" && namespace(section) == HTML_NAMESPACE)
      revision = section["data-discussionbridge-source-revision"]
      assert!(revision.is_a?(String) && !revision.empty?)
      assert!(
        %w[simple full interactive].include?(
          section["data-discussionbridge-mode"]
        )
      )
      attributes
        .merge(expected)
        .each do |name, value|
          assert!(
            name.is_a?(String) && value.is_a?(String) && section[name] == value
          )
        end
      # Expected properties may add revision/mode, never override retained keys.
      attributes.each { |name, value| assert!(section[name] == value) }
      ([section] + section.ancestors.to_a).each { |node| assert_active!(node) }

      span =
        bytes.byteslice(first, finish - first).force_encoding(Encoding::UTF_8)
      isolated = parse(span, :card)
      children = isolated.children.to_a
      assert!(
        children.length == 3 && children[0].comment? && children[1].element? &&
          children[2].comment?
      )
      assert!(
        children[0].content == @begin_marker[4...-3] &&
          children[2].content == @end_marker[4...-3]
      )
      full_tokens = tokens(section)
      assert!(full_tokens == tokens(children[1]))
      canonical =
        JSON.generate(
          [
            PROFILE,
            PARSER,
            @resource_id,
            @kind,
            @native_id,
            @nonce,
            full_tokens
          ]
        ).freeze
      Snapshot.new(
        start_byte: first,
        end_byte: finish,
        html: span.freeze,
        canonical_bytes: canonical,
        sha256: Digest::SHA256.hexdigest(canonical).freeze
      ).freeze
    rescue Error
      raise
    rescue StandardError
      raise Error.new("native_fragment_invalid"), cause: nil
    end

    # Re-derive both spans from actual bytes. A caller cannot pass an invented
    # offset or snapshot to write outside the validated owned section.
    def replace_span(
      original,
      replacement,
      baseline_sha256:,
      prior_fragment: self
    )
      original = utf8(original).freeze
      replacement = utf8(replacement).freeze
      assert!(
        prior_fragment.is_a?(OwnedFragment) &&
          prior_fragment.resource_id == @resource_id &&
          prior_fragment.kind == @kind && prior_fragment.nonce == @nonce &&
          ["pending", @native_id].include?(prior_fragment.native_id)
      )
      before = prior_fragment.extract(original)
      after = extract(replacement)
      assert!(
        before.sha256 == baseline_sha256 && after.start_byte.zero? &&
          after.end_byte == replacement.bytesize
      )
      bytes = original.b
      changed =
        bytes.byteslice(0, before.start_byte) + after.html.b +
          bytes.byteslice(before.end_byte, bytes.bytesize - before.end_byte)
      changed = utf8(changed).freeze
      # Validity of the operands does not establish validity of their combined
      # HTML5 context. Reject repair, relocation or loss before returning bytes.
      observed = extract(changed)
      assert!(
        observed.sha256 == after.sha256 && observed.html.b == after.html.b &&
          observed.start_byte == before.start_byte &&
          observed.end_byte == before.start_byte + after.html.bytesize
      )
      changed
    end

    private

    def assert!(condition)
      raise Error.new("native_fragment_invalid") unless condition
    end

    def utf8(value)
      assert!(value.is_a?(String) && value.bytesize <= @maximum_bytes)
      bytes = value.dup.force_encoding(Encoding::UTF_8)
      assert!(
        bytes.valid_encoding? && !bytes.start_with?("\uFEFF") &&
          !bytes.include?("\x00")
      )
      bytes
    end

    def parse(html, context)
      root =
        (
          if context == :document
            Nokogiri::HTML5.parse(html, **OPTIONS)
          else
            Nokogiri::HTML5.fragment(html, context: "body", **OPTIONS)
          end
        )
      assert!(root.errors.empty?) if context == :card
      root
    end

    def namespace(node)
      node.namespace&.href || HTML_NAMESPACE
    end

    def assert_active!(node)
      return unless node.element?
      style = node["style"].to_s
      hidden =
        INACTIVE.include?(node.name) || namespace(node) != HTML_NAMESPACE ||
          node.key?("hidden") || node.key?("inert") ||
          node["aria-hidden"].to_s.strip.downcase == "true" ||
          inline_hidden?(style)
      assert!(!hidden)
    end

    # Existing Core dependency, inspection only. CSS escape/comment spelling
    # does not change the explicitly rejected display/visibility keywords.
    # Variables, stylesheets, media queries and computed visibility are NOT
    # established here and still need actual browser qualification.
    def inline_hidden?(style)
      return false if style.empty?
      declarations =
        Crass.parse_properties(
          style,
          maximum_depth: 25,
          preserve_comments: false,
          preserve_hacks: false
        )
      assert!(declarations.is_a?(Array) && !css_error?(declarations))
      declarations.any? do |declaration|
        next false unless declaration[:node] == :property
        keyword =
          { "display" => "none", "visibility" => "hidden" }[
            declaration[:name].to_s.downcase
          ]
        next false unless keyword
        parts =
          declaration
            .fetch(:children)
            .reject { |token| %i[whitespace comment].include?(token[:node]) }
        parts.length == 1 && parts.first[:node] == :ident &&
          parts.first[:value].to_s.downcase == keyword
      end
    end

    def css_error?(value)
      case value
      when Hash
        %i[error bad_string bad_url].include?(value[:node]) ||
          value.values.any? { |member| css_error?(member) }
      when Array
        value.any? { |member| css_error?(member) }
      else
        false
      end
    end

    def tokens(node, result = [])
      if node.text?
        result << ["text", node.content]
      elsif node.element?
        pairs =
          node.attribute_nodes.map do |attribute|
            [attribute.namespace&.href || "", attribute.name, attribute.value]
          end
        pairs.concat(
          node.namespace_definitions.map do |definition|
            [XMLNS_NAMESPACE, definition.prefix || "xmlns", definition.href]
          end
        )
        pairs.sort_by! { |uri, name, _value| [uri.b, name.b] }
        result << ["open", namespace(node), node.name, pairs]
        node.children.each { |child| tokens(child, result) }
        result << ["close", namespace(node), node.name]
      else
        assert!(node.comment?)
      end
      result
    end
  end
end
