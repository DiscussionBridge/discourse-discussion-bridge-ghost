# frozen_string_literal: true

require_relative "native_command_journal"
require_relative "native_management"
require_relative "native_owned_command"
require_relative "native_field_control_journal"

module DiscussionBridgeGhost
  # A detached last-PROVEN managed state, derived only from the real journal's
  # validated completion history. Neither this value nor a matching current
  # document is a current work grant, public proof, ownership receipt or ACK.
  # The protected baseline journal retains/reconstructs these observations; it
  # must not call today's native document or desired policy the old baseline.
  class NativeManagedBaseline
    include ProtectedDiagnostics

    attr_reader :value, :sha256

    def self.from_completed(
      journal:,
      command_id:,
      previous: nil,
      before_record_id: nil
    )
      unless journal.is_a?(NativeCommandJournal)
        raise Error.new("identity_conflict")
      end
      retained = journal.retained(command_id)
      command = retained.fetch("command")
      completion = retained.dig("state", "completion")
      unless completion && command.fetch("binding") == journal.context.binding
        raise Error.new("identity_conflict")
      end
      new(
        protocol: journal.context.protocol,
        command: command,
        completion: completion,
        previous: previous,
        released_relations:
          (
            if previous.is_a?(self)
              previous.released_relations(
                journal: journal,
                through_generation: command.dig("owner", "generation"),
                before_record_id: before_record_id
              )
            else
              []
            end
          )
      )
    rescue KeyError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def released_relations(journal:, through_generation:, before_record_id: nil)
      self.class.release_history(
        journal: journal,
        value: @value,
        through_generation: through_generation,
        before_record_id: before_record_id
      )
    end

    # Used only with an enrolled baseline/protected predecessor projection.
    # Returned historical facts are never a current authorization grant.
    def self.release_history(
      journal:,
      value:,
      through_generation:,
      before_record_id: nil
    )
      unless journal.is_a?(NativeCommandJournal) &&
               journal.context.binding == value.fetch("binding")
        raise Error.new("identity_conflict")
      end
      source = journal.retained(value.fetch("content_command_id"))
      command = source.fetch("command")
      unless source.dig("state", "completion") &&
               command.fetch("binding") == value.fetch("binding") &&
               command.dig("owner", "mapping_id") ==
                 value.dig("identity", "mapping_id") &&
               command.dig("identity", "resource_id") ==
                 value.dig("identity", "resource_id")
        raise Error.new("identity_conflict")
      end
      NativeFieldControlJournal.new(
        context: journal.context
      ).released_relations(
        identity: value.fetch("identity"),
        after_generation: command.dig("owner", "generation"),
        through_generation: through_generation,
        before_record_id: before_record_id
      )
    end

    # Pure comparison, not authority. Release facts passed here must originate
    # in the protected field-control journal at the exact caller's generation.
    def assert_current!(native, management: nil, released_relations: [])
      unless management.nil? || management.is_a?(NativeManagement)
        raise Error.new("identity_conflict")
      end
      unless released_relations.is_a?(Array) &&
               (released_relations - %w[authors taxonomy]).empty? &&
               released_relations.uniq == released_relations
        raise Error.new("identity_conflict")
      end
      released =
        released_relations + (management ? management.released_relations : [])
      current = snapshot(native)
      identity = @value.fetch("identity")
      unless current["id"] == identity.fetch("native_id") &&
               current["type"] == identity.fetch("kind")
        raise Error.new("identity_conflict")
      end
      @value
        .fetch("scalars")
        .each do |key, expected|
          actual = current.fetch(key)
          same =
            if key == "published_at"
              Time.iso8601(expected) == Time.iso8601(actual)
            else
              expected == actual
            end
          raise Error.new("identity_conflict") unless same
        end
      %w[authors taxonomy].each do |relation|
        expected = @value.fetch(relation)
        next if expected.nil? || released.include?(relation)
        actual =
          if relation == "authors"
            relation_ids(current.fetch("authors"))
          else
            relation_ids(non_automation_tags(current))
          end
        raise Error.new("identity_conflict") unless actual == expected
      end
      unless automation_tags(current) == @value.fetch("automation_tags") &&
               fragment_state(current) == @value.fetch("fragment")
        raise Error.new("identity_conflict")
      end
      true
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def initialize(
      protocol:,
      command:,
      completion:,
      previous:,
      released_relations:
    )
      @maximum = command.dig("request", "maximum_bytes")
      management =
        NativeManagement.new(
          protocol: protocol,
          value: command.fetch("candidate").fetch("management")
        )
      management.validate_command!(command)
      native = snapshot(completion.fetch("native"))
      @identity = {
        "mapping_id" => command.dig("owner", "mapping_id"),
        "external_id" => command.dig("owner", "external_id"),
        "resource_id" => command.dig("identity", "resource_id"),
        "native_id" => completion.fetch("native_id"),
        "kind" => completion.fetch("kind")
      }
      if management.value.fetch("stage") == "create_draft"
        raise Error.new("identity_conflict") unless previous.nil?
      else
        unless previous.is_a?(self.class) &&
                 previous.value.fetch("binding") == command.fetch("binding") &&
                 previous.value.fetch("identity") == @identity
          raise Error.new("identity_conflict")
        end
        previous.assert_current!(
          command.fetch("baseline"),
          management: management,
          released_relations: released_relations
        )
      end
      fragment = fragment_state(native)
      NativeOwnedCommand.new(
        command: command,
        expected_mode: fragment.fetch("mode")
      ).validate!
      scalars =
        if management.value.fetch("stage") == "withdraw"
          previous
            .value
            .fetch("scalars")
            .merge("status" => native.fetch("status"))
        else
          management
            .value
            .fetch("scalar_fields")
            .to_h { |field| [field, native.fetch(field)] }
        end
      prior_profile = management.value.fetch("stage") == "withdraw"
      @value =
        build_value(
          command: command,
          completion: completion,
          management: management,
          native: native,
          previous_sha256: previous&.sha256,
          content_command_id:
            (
              if prior_profile
                previous.value.fetch("content_command_id")
              else
                command.fetch("command_id")
              end
            ),
          content_policy_revision:
            (
              if prior_profile
                previous.value.fetch("content_policy_revision")
              else
                management.value.fetch("policy_revision")
              end
            ),
          scalars: scalars,
          authors:
            (
              if prior_profile
                if (
                     management.released_relations + released_relations
                   ).include?("authors")
                  nil
                else
                  previous.value.fetch("authors")
                end
              else
                management.value.fetch("author_ids")
              end
            ),
          taxonomy:
            (
              if prior_profile
                if (
                     management.released_relations + released_relations
                   ).include?("taxonomy")
                  nil
                else
                  previous.value.fetch("taxonomy")
                end
              else
                management.value.fetch("taxonomy_ids")
              end
            )
        )
      # Withdrawal has no new article edition or metadata profile. A status-only
      # completion must not bless preexisting managed edits as a new baseline.
      if prior_profile && fragment != previous.value.fetch("fragment")
        raise Error.new("identity_conflict")
      end
      finish!(native)
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end
    private_class_method :new

    # Only NativeBaselineJournal invokes this private restoration hook AFTER
    # reading authenticated, installation/key-bound retained rows and validating
    # their head, root, direct predecessor and content-command references. This
    # is not a public importer for caller-provided hashes. Rebuild every managed
    # field from real command completions, not from the saved projection alone.
    def self.restore(
      protocol:,
      command:,
      completion:,
      content_command:,
      content_completion:,
      previous_value:,
      released_relations:,
      value:
    )
      restored = allocate
      restored.send(
        :initialize_saved,
        protocol: protocol,
        command: command,
        completion: completion,
        content_command: content_command,
        content_completion: content_completion,
        previous_value: previous_value,
        released_relations: released_relations,
        value: value
      )
      restored
    end
    private_class_method :restore

    def initialize_saved(
      protocol:,
      command:,
      completion:,
      content_command:,
      content_completion:,
      previous_value:,
      released_relations:,
      value:
    )
      @maximum = command.dig("request", "maximum_bytes")
      @identity = {
        "mapping_id" => command.dig("owner", "mapping_id"),
        "external_id" => command.dig("owner", "external_id"),
        "resource_id" => command.dig("identity", "resource_id"),
        "native_id" => completion.fetch("native_id"),
        "kind" => completion.fetch("kind")
      }
      management =
        NativeManagement.new(
          protocol: protocol,
          value: command.fetch("candidate").fetch("management")
        )
      content_management =
        NativeManagement.new(
          protocol: protocol,
          value: content_command.fetch("candidate").fetch("management")
        )
      management.validate_command!(command)
      content_management.validate_command!(content_command)
      if content_management.value.fetch("stage") == "withdraw" ||
           content_command.fetch("binding") != command.fetch("binding") ||
           content_command.dig("owner", "mapping_id") !=
             @identity.fetch("mapping_id") ||
           content_command.dig("owner", "external_id") !=
             @identity.fetch("external_id") ||
           content_command.dig("identity", "resource_id") !=
             @identity.fetch("resource_id") ||
           content_completion.fetch("native_id") !=
             @identity.fetch("native_id") ||
           content_completion.fetch("kind") != @identity.fetch("kind")
        raise Error.new("identity_conflict")
      end
      withdrawal = management.value.fetch("stage") == "withdraw"
      if withdrawal
        unless previous_value.is_a?(Hash) &&
                 previous_value.fetch("binding") == command.fetch("binding") &&
                 previous_value.fetch("identity") == @identity &&
                 Digest::SHA256.hexdigest(JSON.generate(previous_value)) ==
                   value.fetch("previous_sha256")
          raise Error.new("identity_conflict")
        end
      end
      same_effect =
        content_command == command && content_completion == completion
      raise Error.new("identity_conflict") unless withdrawal || same_effect
      native = snapshot(completion.fetch("native"))
      content_native = snapshot(content_completion.fetch("native"))
      fragment = fragment_state(native)
      NativeOwnedCommand.new(
        command: command,
        expected_mode: fragment.fetch("mode")
      ).validate!
      NativeOwnedCommand.new(
        command: content_command,
        expected_mode: fragment_state(content_native).fetch("mode")
      ).validate!
      scalars =
        content_management
          .value
          .fetch("scalar_fields")
          .to_h { |field| [field, content_native.fetch(field)] }
      scalars = scalars.merge("status" => native.fetch("status")) if withdrawal
      @value =
        build_value(
          command: command,
          completion: completion,
          management: management,
          native: native,
          previous_sha256: value.fetch("previous_sha256"),
          content_command_id: content_command.fetch("command_id"),
          content_policy_revision:
            content_management.value.fetch("policy_revision"),
          scalars: scalars,
          authors:
            (
              if withdrawal &&
                   (
                     management.released_relations + released_relations
                   ).include?("authors")
                nil
              else
                if withdrawal
                  previous_value.fetch("authors")
                else
                  content_management.value.fetch("author_ids")
                end
              end
            ),
          taxonomy:
            (
              if withdrawal &&
                   (
                     management.released_relations + released_relations
                   ).include?("taxonomy")
                nil
              else
                if withdrawal
                  previous_value.fetch("taxonomy")
                else
                  content_management.value.fetch("taxonomy_ids")
                end
              end
            )
        )
      same_fragment = !withdrawal || fragment == fragment_state(content_native)
      unless @value == value && same_fragment
        raise Error.new("identity_conflict")
      end
      finish!(native)
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    def build_value(
      command:,
      completion:,
      management:,
      native:,
      previous_sha256:,
      content_command_id:,
      content_policy_revision:,
      scalars:,
      authors:,
      taxonomy:
    )
      snapshot(
        "format" => "ghost-native-managed-baseline-1",
        "binding" => command.fetch("binding"),
        "identity" => @identity,
        "command_id" => command.fetch("command_id"),
        "command_sha256" => completion.fetch("command_sha256"),
        "effect_sha256" => Digest::SHA256.hexdigest(JSON.generate(completion)),
        "previous_sha256" => previous_sha256,
        "management" => management.value,
        "content_command_id" => content_command_id,
        "content_policy_revision" => content_policy_revision,
        "scalars" => scalars,
        "authors" => authors,
        "taxonomy" => taxonomy,
        "fragment" => fragment_state(native),
        "automation_tags" => automation_tags(native)
      )
    end

    def finish!(native)
      assert_current!(native)
      @sha256 = Digest::SHA256.hexdigest(JSON.generate(@value)).freeze
      freeze
    end

    def fragment_state(native)
      html = native.fetch("html")
      unless html.is_a?(String) && html.bytesize <= @maximum
        raise Error.new("native_fragment_invalid")
      end
      root = Nokogiri::HTML5.fragment(html, **OwnedFragment::OPTIONS)
      section = root.at_css("section[data-discussionbridge-owned]")
      raise Error.new("native_fragment_invalid") unless section
      native_id = section["data-discussionbridge-native-id"]
      if ["pending", @identity.fetch("native_id")].exclude?(native_id)
        raise Error.new("identity_conflict")
      end
      parser =
        OwnedFragment.new(
          resource_id: @identity.fetch("resource_id"),
          kind: @identity.fetch("kind"),
          native_id: native_id,
          nonce: section["data-discussionbridge-fragment-nonce"],
          maximum_bytes: @maximum
        )
      span = parser.extract(html)
      lexical =
        NativeDocument.parse(native.fetch("lexical"), maximum_bytes: @maximum)
      tree = lexical.fetch("root")
      unless tree.is_a?(Hash) && tree["type"] == "root" &&
               tree["version"] == 1 && tree["children"].is_a?(Array)
        raise Error.new("native_fragment_invalid")
      end
      cards = []
      find_cards(tree) do |node|
        if node["html"].is_a?(String) &&
             /discussionbridge-owned:|data-discussionbridge-owned/i.match?(
               node["html"]
             )
          cards << node
        end
      end
      unless cards.length == 1 && cards.first["version"] == 1 &&
               tree["children"].any? { |node| node.equal?(cards.first) } &&
               parser.extract(cards.first.fetch("html")).sha256 == span.sha256
        raise Error.new("native_fragment_invalid")
      end
      {
        "sha256" => span.sha256,
        "native_id" => native_id,
        "nonce" => parser.nonce,
        "mode" => section["data-discussionbridge-mode"],
        "source_revision" => section["data-discussionbridge-source-revision"],
        "card_properties" => cards.first.except("html")
      }
    end

    def tags(native)
      values = native.fetch("tags")
      relation_ids(values)
      unless values.all? { |tag| tag["name"].is_a?(String) }
        raise Error.new("identity_conflict")
      end
      resource = "#discussionbridge-resource-#{@identity.fetch("resource_id")}"
      resources =
        values.select do |tag|
          tag["name"].is_a?(String) &&
            tag["name"].start_with?("#discussionbridge-resource-")
        end
      unless resources.length == 1 && resources.first["name"] == resource
        raise Error.new("identity_conflict")
      end
      values
    end

    def automation?(tag)
      tag.fetch("name").start_with?("#discussionbridge-resource-") ||
        NativeManagement::INTERNAL_TAGS.include?(tag.fetch("name"))
    end

    def non_automation_tags(native)
      tags(native).reject { |tag| automation?(tag) }
    end

    def automation_tags(native)
      tags(native)
        .select { |tag| automation?(tag) }
        .map { |tag| { "id" => tag.fetch("id"), "name" => tag.fetch("name") } }
    end

    def relation_ids(values)
      unless values.is_a?(Array) &&
               values.all? { |entry|
                 entry.is_a?(Hash) && entry["id"].is_a?(String) &&
                   /\A[a-f0-9]{24}\z/.match?(entry["id"])
               }
        raise Error.new("identity_conflict")
      end
      ids = values.map { |entry| entry.fetch("id") }
      raise Error.new("identity_conflict") unless ids.uniq == ids
      ids
    end

    def snapshot(value)
      parsed =
        NativeDocument.parse(JSON.generate(value), maximum_bytes: @maximum)
      deep_freeze(parsed)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each do |key, member|
          key.freeze
          deep_freeze(member)
        end
      when Array
        value.each { |member| deep_freeze(member) }
      end
      value.freeze
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
