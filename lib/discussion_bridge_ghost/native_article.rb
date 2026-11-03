# frozen_string_literal: true

require "rails-html-sanitizer"
require "cgi"
require "uri"
require_relative "owned_fragment"
require_relative "source_activity"
require_relative "wire_json"
require_relative "wire_protocol"

module DiscussionBridgeGhost
  # Pure From-content preparation, NOT publication/ownership authority. Keep the
  # entire immutable Source and original bytes. If the actual native conversion
  # loses authored structure/data/function, report a limitation instead of
  # publishing the stripped result. No Ghost/receiver request or state mutation.
  class NativeArticle
    include ProtectedDiagnostics

    EXTRA_TAGS = %w[
      table
      thead
      tbody
      tfoot
      tr
      th
      td
      caption
      colgroup
      col
      h1
      h2
      h3
      h4
      h5
      h6
      figure
      figcaption
      section
      time
    ].freeze
    EXTRA_ATTRIBUTES = %w[
      class
      id
      rel
      title
      alt
      width
      height
      colspan
      rowspan
      headers
      scope
      abbr
      start
      reversed
      type
      value
      datetime
      lang
      cite
      srcset
      loading
      decoding
    ].freeze
    SCALAR_REFERENCES = %w[href src poster cite background longdesc].freeze

    class Limitation < Error
      include ProtectedDiagnostics
      attr_reader :elements, :functions

      def initialize(elements: [], functions: [])
        super("native_content_unrepresentable")
        @elements =
          elements.uniq.sort.first(100).map { |value| value.dup.freeze }.freeze
        @functions =
          functions.uniq.sort.first(100).map { |value| value.dup.freeze }.freeze
      end
    end

    attr_reader :source, :original_html, :html, :publication_date

    def initialize(protocol:, forum_origin:, source:, html:, maximum_bytes:)
      unless protocol.is_a?(WireProtocol) && maximum_bytes.is_a?(Integer) &&
               maximum_bytes.positive?
        raise Error.new("identity_conflict")
      end
      @protocol, @maximum = protocol, maximum_bytes
      unless Nokogiri::VERSION == "1.19.4" &&
               Gem.loaded_specs["rails-html-sanitizer"]&.version&.to_s ==
                 "1.7.1" &&
               Gem.loaded_specs["loofah"]&.version&.to_s == "2.25.2" &&
               Gem.loaded_specs["crass"]&.version&.to_s == "1.0.7"
        raise Error.new("native_representation_unavailable")
      end
      @source =
        WireJson.parse(
          JSON.generate(source),
          maximum_bytes: WireProtocol::RESPONSE_MAXIMUM
        )
      @protocol.validate!("Source", @source)
      @original_html = utf8(html).freeze
      unless @original_html.bytesize == @source.fetch("content_bytes") &&
               Digest::SHA256.hexdigest(@original_html) ==
                 @source.fetch("content_sha256")
        raise Error.new("identity_conflict")
      end
      topic = @source.fetch("topic_url")
      suffix = topic.sub(%r{\Ahttps://[^/?#]+}i, "")
      unless @protocol.url_origin_key(topic) ==
               @protocol.origin_key(forum_origin) &&
               %r{\A/t/(?:[^/?#]+/)?#{Regexp.escape(@source.fetch("topic_id"))}/?\z}.match?(
                 suffix
               )
        raise Error.new("identity_conflict")
      end
      @base = @protocol.url_origin_key(topic) + escape_reference(suffix)
      @publication_date =
        SourceActivity.publication_date(
          created_at: @source.fetch("source_created_at"),
          updated_at: @source.fetch("source_updated_at")
        ).freeze
      root = parse(@original_html)
      root.traverse do |node|
        if node.comment? && /discussionbridge-owned:/i.match?(node.content)
          raise Limitation.new(functions: ["reserved publication markers"])
        end
        next unless node.element?
        if node.namespace &&
             node.namespace.href != OwnedFragment::HTML_NAMESPACE
          raise Limitation.new(
                  elements: [node.name],
                  functions: ["foreign-namespace content"]
                )
        end
        if node.attribute_nodes.any? { |attribute|
             attribute.name.start_with?("data-discussionbridge-")
           }
          raise Limitation.new(functions: ["reserved publication attributes"])
        end
        SCALAR_REFERENCES.each do |name|
          node[name] = anchor(node[name]) if node.key?(name)
        end
        node["srcset"] = anchor_srcset(node["srcset"]) if node.key?("srcset")
        reject_css_references!(node["style"]) if node.key?("style")
      end
      anchored = serialize(root)
      sanitizer = Rails::HTML5::SafeListSanitizer.new
      converted =
        sanitizer.sanitize(
          anchored,
          tags:
            (
              Rails::HTML5::SafeListSanitizer.allowed_tags.to_a + EXTRA_TAGS
            ).uniq,
          attributes:
            (
              Rails::HTML5::SafeListSanitizer.allowed_attributes.to_a +
                EXTRA_ATTRIBUTES
            ).uniq
        )
      after = parse(utf8(converted))
      unless tokens(root) == tokens(after)
        before_elements = root.css("*").map(&:name).tally
        after_elements = after.css("*").map(&:name).tally
        losses =
          before_elements.keys.select do |name|
            before_elements.fetch(name) > after_elements.fetch(name, 0)
          end
        raise Limitation.new(
                elements: losses,
                functions: ["source content, structure or attributes"]
              )
      end
      @html = utf8(converted).freeze
      freeze_value(@source)
      freeze
    rescue Error
      raise
    rescue LoadError, NameError
      raise Error.new("native_representation_unavailable"), cause: nil
    rescue StandardError
      raise Error.new("native_content_unrepresentable"), cause: nil
    end

    private

    def utf8(value)
      unless value.is_a?(String) && value.bytesize <= @maximum
        raise Error.new("identity_conflict")
      end
      bytes = value.dup.force_encoding(Encoding::UTF_8)
      unless bytes.valid_encoding? && !bytes.start_with?("\uFEFF") &&
               !bytes.include?("\x00")
        raise Error.new("identity_conflict")
      end
      bytes
    end

    def parse(value)
      result =
        Nokogiri::HTML5.fragment(
          value,
          context: "body",
          **OwnedFragment::OPTIONS
        )
      unless result.errors.empty?
        raise Limitation.new(functions: ["source HTML structure"])
      end
      result
    end

    def serialize(root)
      root.to_html(
        save_with:
          Nokogiri::XML::Node::SaveOptions::AS_HTML |
            Nokogiri::XML::Node::SaveOptions::NO_DECLARATION
      )
    end

    def escape_reference(value)
      if value.include?("\\") || value.match?(/[\p{Cc}]/) ||
           value.match?(/%(?![0-9a-f]{2})/i)
        raise Limitation.new(functions: ["source reference syntax"])
      end
      value
        .b
        .bytes
        .map { |byte| byte <= 32 || byte >= 127 ? "%%%02X" % byte : byte.chr }
        .join
    end

    def anchor(value)
      # Browsers trim leading/trailing ASCII URL spaces before resolving. Do
      # not percent-encode those into a different relative target.
      if value.start_with?(" ") || value.end_with?(" ")
        raise Limitation.new(functions: ["source reference syntax"])
      end
      result =
        if value.match?(/\A[a-z][a-z0-9+.-]*:/i)
          value
        elsif value.start_with?("//")
          absolute = "https:#{value}"
          before_fragment = absolute.split("#", 2).first
          origin = @protocol.url_origin_key(before_fragment)
          origin + escape_reference(absolute.sub(%r{\Ahttps://[^/?#]+}, ""))
        else
          URI.join(@base, escape_reference(value)).to_s
        end
      # These are browser references, never server fetch authority. Restrict the
      # actual target, not just the spelling seen by the sanitizer. Retain the
      # fragment separately; protocol Url comparison itself excludes fragments.
      @protocol.validate!("Url", result.split("#", 2).first)
      result
    rescue Error, URI::Error, ArgumentError
      raise Limitation.new(functions: ["source reference target"]), cause: nil
    end

    def anchor_srcset(value)
      candidates, position = [], 0
      while position < value.length
        position += 1 while position < value.length &&
          /[\t\n\f\r ,]/.match?(value[position])
        break if position == value.length
        first = position
        position += 1 while position < value.length &&
          !/[\t\n\f\r ]/.match?(value[position])
        url, descriptor = value[first...position], ""
        if url.end_with?(",")
          url = url.sub(/,+\z/, "")
        else
          first = position
          position += 1 while position < value.length && value[position] != ","
          descriptor = value[first...position].strip
          position += 1 if position < value.length
        end
        unless !url.empty? &&
                 (
                   descriptor.empty? ||
                     /\A(?:[1-9][0-9]*w|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)x)\z/.match?(
                       descriptor
                     ) &&
                       (!descriptor.end_with?("x") || descriptor.to_f.positive?)
                 )
          raise Limitation.new(functions: ["source srcset syntax"])
        end
        candidates << anchor(url) + (descriptor.empty? ? "" : " #{descriptor}")
      end
      candidates.join(", ")
    end

    def reject_css_references!(style)
      inspect_token =
        lambda do |value|
          case value
          when Hash
            if %i[error bad_string bad_url url at_rule].include?(
                 value[:node]
               ) ||
                 (
                   value[:node] == :function &&
                     %w[url image-set -webkit-image-set].include?(
                       value[:name].to_s.downcase
                     )
                 )
              raise Limitation.new(
                      functions: ["source CSS reference or syntax"]
                    )
            end
            value.each_value { |member| inspect_token.call(member) }
          when Array
            value.each { |member| inspect_token.call(member) }
          end
        end
      inspect_token.call(Crass.parse_properties(style, maximum_depth: 25))
    end

    def tokens(node)
      return "text", node.content if node.text?
      return nil if node.comment?
      if node.element?
        [
          node.name,
          node.attribute_nodes.map { |a| [a.name, a.value] }.sort,
          node.children.filter_map { |child| tokens(child) }
        ]
      else
        node.children.filter_map { |child| tokens(child) }
      end
    end

    def freeze_value(value)
      case value
      when Hash
        value.each do |key, member|
          key.freeze
          freeze_value(member)
        end
      when Array
        value.each { |member| freeze_value(member) }
      end
      value.freeze
    end
  end
end
