# frozen_string_literal: true

require "json"

module DiscussionBridgeGhost
  # Pure preparation only: no HTTP, receipt, native write or adoption. A future
  # durable native-command coordinator must retain intent and authority before
  # applying this payload with Ghost's exact updated_at CAS.
  class OwnedLexical
    include ProtectedDiagnostics

    def initialize(fragment:)
      raise Error.new("identity_conflict") unless fragment.is_a?(OwnedFragment)
      @fragment = fragment
    end

    def create(html)
      exact = @fragment.extract(html)
      check!(exact.start_byte.zero? && exact.end_byte == html.bytesize)
      encoded =
        JSON.generate(
          "root" => {
            "children" => [
              {
                "type" => "html",
                "version" => 1,
                "html" => html,
                "visibility" => {
                  "web" => {
                    "nonMember" => true,
                    "memberSegment" => "status:free,status:-free"
                  },
                  "email" => {
                    "memberSegment" => "status:free,status:-free"
                  }
                }
              }
            ],
            "direction" => nil,
            "format" => "",
            "indent" => 0,
            "type" => "root",
            "version" => 1
          }
        )
      check!(encoded.bytesize <= @fragment.maximum_bytes)
      encoded
    end

    def replace(
      current:,
      html:,
      expected_revision:,
      baseline_sha256:,
      prior_fragment: @fragment
    )
      check!(
        current.is_a?(Hash) && current["id"] == @fragment.native_id &&
          @fragment.native_id != "pending" &&
          current["type"] == @fragment.kind &&
          expected_revision.is_a?(String) && !expected_revision.empty? &&
          current["updated_at"] == expected_revision
      )
      check!(
        prior_fragment.is_a?(OwnedFragment) &&
          prior_fragment.resource_id == @fragment.resource_id &&
          prior_fragment.kind == @fragment.kind &&
          prior_fragment.nonce == @fragment.nonce &&
          ["pending", @fragment.native_id].include?(prior_fragment.native_id)
      )
      desired = @fragment.extract(html)
      check!(desired.start_byte.zero? && desired.end_byte == html.bytesize)
      rendered = prior_fragment.extract(current["html"])
      check!(rendered.sha256 == baseline_sha256)
      # Other native HTML cards can contribute surrounding parse context too.
      # Validate the proposed span in the actual retained rendered context as
      # well as in its selected card, before preparing any native payload.
      @fragment.replace_span(
        current["html"],
        html,
        baseline_sha256: baseline_sha256,
        prior_fragment: prior_fragment
      )
      document = parse(current["lexical"])
      root = document["root"]
      check!(
        root.is_a?(Hash) && root["type"] == "root" && root["version"] == 1 &&
          root["children"].is_a?(Array)
      )
      matches = []
      html_cards(root) do |node|
        unless node["html"].is_a?(String) &&
                 /data-discussionbridge-owned|discussionbridge-owned:/i.match?(
                   node["html"]
                 )
          next
        end
        check!(
          root["children"].any? { |child| child.equal?(node) } &&
            node["version"] == 1
        )
        span = prior_fragment.extract(node["html"])
        check!(span.sha256 == rendered.sha256)
        matches << [node, span]
      end
      check!(matches.length == 1)
      card, _span = matches.first
      # Replacement may change pending -> real native ID. Both exact bindings
      # are explicit above; no other native object, nonce or profile is admitted.
      card["html"] = @fragment.replace_span(
        card["html"],
        html,
        baseline_sha256: rendered.sha256,
        prior_fragment: prior_fragment
      )
      encoded = JSON.generate(document)
      check!(encoded.bytesize <= @fragment.maximum_bytes)
      encoded
    rescue Error
      raise
    rescue StandardError
      raise Error.new("native_fragment_invalid"), cause: nil
    end

    private

    def check!(condition)
      raise Error.new("native_fragment_invalid") unless condition
    end

    def parse(value)
      check!(value.is_a?(String) && value.bytesize <= @fragment.maximum_bytes)
      bytes = value.dup.force_encoding(Encoding::UTF_8)
      check!(bytes.valid_encoding? && !bytes.start_with?("\uFEFF"))
      result = JSON.parse(bytes, object_class: WireJson::StrictObject)
      check!(result.is_a?(Hash) && finite?(result))
      # StrictObject refuses duplicate assignments while parsing. Its purpose
      # ends after validation: surgery needs an ordinary PRIVATE mutable tree,
      # not removal/reinsertion that bypasses duplicate-key detection.
      mutable_tree(result)
    end

    def mutable_tree(value)
      case value
      when Hash
        value.each_with_object({}) do |(name, member), result|
          result[name] = mutable_tree(member)
        end
      when Array
        value.map { |member| mutable_tree(member) }
      else
        value
      end
    end

    def finite?(value)
      case value
      when Hash
        value.values.all? { |member| finite?(member) }
      when Array
        value.all? { |member| finite?(member) }
      when Float
        value.finite?
      else
        true
      end
    end

    def html_cards(value, &block)
      case value
      when Hash
        yield value if value["type"] == "html"
        value.each_value { |member| html_cards(member, &block) }
      when Array
        value.each { |member| html_cards(member, &block) }
      end
    end
  end
end
