# frozen_string_literal: true

require_relative "native_document"

module DiscussionBridgeGhost
  # Validate the prepared native surgery before any write. The original owned
  # nonce/identity and unrelated cards/properties must survive. A fresh command
  # attribute also makes a real effect participate in Ghost's model collision
  # check, including otherwise relations-only updates. No-op coordinators must
  # skip dispatch; stamping is not a reason to manufacture an unnecessary write.
  class NativeOwnedCommand
    include ProtectedDiagnostics

    def initialize(command:, expected_mode:)
      @command, @mode = command, expected_mode
      @document = NativeDocument.new(command)
      @fields = @document.fields
      @identity = command.fetch("identity")
      @maximum = command.dig("request", "maximum_bytes")
    end

    def validate!
      unless @command.dig("owner", "direction") == "from_discourse"
        raise Error.new("work_authority_unavailable")
      end
      lexical =
        NativeDocument.parse(@fields.fetch("lexical"), maximum_bytes: @maximum)
      root = lexical.fetch("root")
      unless root.is_a?(Hash) && root["type"] == "root" &&
               root["children"].is_a?(Array)
        raise Error.new("native_fragment_invalid")
      end
      cards = []
      find_cards(root) do |node|
        if node["html"].is_a?(String) &&
             /discussionbridge-owned:|data-discussionbridge-owned/i.match?(
               node["html"]
             )
          cards << node
        end
      end
      unless cards.length == 1 &&
               root["children"].any? { |child| child.equal?(cards.first) }
        raise Error.new("native_fragment_invalid")
      end
      card = cards.first
      fragment =
        fragment_for(
          card.fetch("html"),
          native_id: @identity["native_id"] || "pending"
        )
      expected = {
        "data-discussionbridge-command" => @command.fetch("command_id"),
        "data-discussionbridge-mode" => @mode
      }
      revision = @command.dig("owner", "source_revision")
      expected["data-discussionbridge-source-revision"] = revision if revision
      desired = fragment.extract(card.fetch("html"), expected: expected)
      baseline = @command.fetch("baseline")
      if baseline.nil?
        unless @fields
                 .fetch("tags")
                 .any? { |tag|
                   tag["name"] ==
                     "#discussionbridge-resource-#{@identity.fetch("resource_id")}"
                 }
          raise Error.new("identity_conflict")
        end
        exact = OwnedLexical.new(fragment: fragment).create(desired.html)
      else
        old_html = baseline.fetch("html")
        if @fields.key?("tags")
          retained_tag =
            Array(baseline["tags"]).find do |tag|
              tag["name"] ==
                "#discussionbridge-resource-#{@identity.fetch("resource_id")}"
            end
          retained_id = retained_tag && retained_tag["id"]
          valid_id =
            retained_id.is_a?(String) && /\A[a-f0-9]{24}\z/.match?(retained_id)
          preserved_tag =
            retained_tag &&
              @fields["tags"].any? do |tag|
                (valid_id && tag["id"] == retained_id) ||
                  tag["name"] == retained_tag["name"]
              end
          raise Error.new("identity_conflict") unless preserved_tag
        end
        old_root = Nokogiri::HTML5.fragment(old_html, **OwnedFragment::OPTIONS)
        old_section = old_root.at_css("section[data-discussionbridge-owned]")
        if old_section.nil? ||
             old_section["data-discussionbridge-command"] ==
               @command.fetch("command_id")
          raise Error.new("native_fragment_invalid")
        end
        prior_id = old_section["data-discussionbridge-native-id"]
        if ["pending", @identity.fetch("native_id")].exclude?(prior_id)
          raise Error.new("identity_conflict")
        end
        prior = fragment_for(old_html, native_id: prior_id)
        raise Error.new("identity_conflict") if prior.nonce != fragment.nonce
        old = prior.extract(old_html)
        exact =
          OwnedLexical.new(fragment: fragment).replace(
            current: baseline,
            html: desired.html,
            expected_revision: baseline.fetch("updated_at"),
            baseline_sha256: old.sha256,
            prior_fragment: prior
          )
      end
      unless NativeDocument.parse(exact, maximum_bytes: @maximum) == lexical
        raise Error.new("native_fragment_invalid")
      end
      true
    rescue Error
      raise
    rescue StandardError
      raise Error.new("native_fragment_invalid"), cause: nil
    end

    private

    def fragment_for(html, native_id:)
      root = Nokogiri::HTML5.fragment(html, **OwnedFragment::OPTIONS)
      section = root.at_css("section[data-discussionbridge-owned]")
      raise Error.new("native_fragment_invalid") unless section
      OwnedFragment.new(
        resource_id: @identity.fetch("resource_id"),
        kind: @identity.fetch("kind"),
        native_id: native_id,
        nonce: section["data-discussionbridge-fragment-nonce"],
        maximum_bytes: @maximum
      )
    end

    def find_cards(value, &block)
      case value
      when Hash
        yield value if value["type"] == "html"
        value.each_value { |member| find_cards(member, &block) }
      when Array
        value.each { |member| find_cards(member, &block) }
      end
    end
  end
end
