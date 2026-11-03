# frozen_string_literal: true

require_relative "native_document"

module DiscussionBridgeGhost
  # Private immutable command intent, never a Ghost body/wire field or current
  # authority. Retaining the original policy prevents recovery from guessing
  # which native metadata an old command was meant to manage. A current real
  # WorkAuthority must independently check it before dispatch.
  class NativeManagement
    include ProtectedDiagnostics

    FORMAT = "ghost-native-management-1"
    SCALARS = %w[title slug status visibility published_at].map(&:freeze).freeze
    FIELDS = %w[
      format
      policy_revision
      stage
      scalar_fields
      author_ids
      taxonomy_ids
    ].sort.freeze
    STAGES = {
      "create_draft" => %w[title slug status visibility].freeze,
      "publish" => SCALARS,
      "withdraw" => %w[status].freeze
    }.freeze
    INTERNAL_TAGS = %w[
      #discussionbridge-source
      #discussionbridge-simple
      #discussionbridge-full
      #discussionbridge-interactive
    ].freeze

    attr_reader :value

    def self.for_policy(protocol:, policy:, stage:)
      raise Error.new("identity_conflict") unless protocol.is_a?(WireProtocol)
      protocol.validate!("Policy", policy)
      raise Error.new("identity_conflict") unless STAGES.key?(stage)
      authors =
        (
          if stage == "publish" && !policy.fetch("author_ids").empty?
            policy.fetch("author_ids")
          else
            nil
          end
        )
      taxonomy =
        (
          if stage == "publish" && !policy.fetch("taxonomy_ids").empty?
            policy.fetch("taxonomy_ids")
          else
            nil
          end
        )
      new(
        protocol: protocol,
        value: {
          "format" => FORMAT,
          "policy_revision" => policy.fetch("policy_revision"),
          "stage" => stage,
          "scalar_fields" => STAGES.fetch(stage),
          "author_ids" => authors,
          "taxonomy_ids" => taxonomy
        }
      )
    end

    def initialize(protocol:, value:)
      raise Error.new("identity_conflict") unless protocol.is_a?(WireProtocol)
      @protocol = protocol
      @value =
        WireJson.parse(
          JSON.generate(value),
          maximum_bytes: WireProtocol::RESPONSE_MAXIMUM
        )
      unless @value.is_a?(Hash) && @value.keys.sort == FIELDS &&
               @value["format"] == FORMAT && STAGES.key?(@value["stage"]) &&
               @value["scalar_fields"] == STAGES.fetch(@value["stage"])
        raise Error.new("identity_conflict")
      end
      @protocol.validate!("Revision", @value.fetch("policy_revision"))
      authors = @value.fetch("author_ids")
      ids!(authors) unless authors.nil?
      raise Error.new("identity_conflict") if authors == []
      taxonomy = @value.fetch("taxonomy_ids")
      ids!(taxonomy) unless taxonomy.nil?
      if taxonomy == [] ||
           (
             @value.fetch("stage") != "publish" &&
               (!authors.nil? || !taxonomy.nil?)
           )
        raise Error.new("identity_conflict")
      end
      deep_freeze(@value)
      freeze
    rescue JSON::GeneratorError, KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def assert_policy!(policy)
      unless self
               .class
               .for_policy(
                 protocol: @protocol,
                 policy: policy,
                 stage: @value.fetch("stage")
               )
               .value == @value
        raise Error.new("work_authority_unavailable")
      end
      true
    end

    def validate_command!(command)
      fields = NativeDocument.new(command).fields
      owner = command.fetch("owner")
      allowed = @value.fetch("scalar_fields") + %w[id updated_at]
      allowed << "lexical" unless @value.fetch("stage") == "withdraw"
      allowed += %w[authors tags] if @value.fetch("stage") == "publish"
      allowed << "tags" if @value.fetch("stage") == "create_draft"
      unless owner.fetch("direction") == "from_discourse" &&
               owner.fetch("action") == @value.fetch("stage") &&
               owner.fetch("move_id").nil? && owner.fetch("proof_nonce").nil? &&
               command.dig("candidate", "management") == @value &&
               (fields.keys - allowed).empty? &&
               @value.fetch("scalar_fields").all? { |name| fields.key?(name) }
        raise Error.new("identity_conflict")
      end
      # An absent operator selection means preserve native authors, not an
      # invitation to substitute a forum user or silently select a default.
      authors = @value.fetch("author_ids")
      if authors.nil?
        raise Error.new("identity_conflict") if fields.key?("authors")
      else
        actual = fields.fetch("authors") { command.dig("baseline", "authors") }
        unless relation_ids(actual) == authors
          raise Error.new("identity_conflict")
        end
      end
      tags = fields.fetch("tags") { command.dig("baseline", "tags") }
      unless tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(Hash) }
        raise Error.new("identity_conflict")
      end
      resource =
        "#discussionbridge-resource-#{command.dig("identity", "resource_id")}"
      if tags.any? { |tag|
           tag["name"].is_a?(String) &&
             tag["name"].start_with?("#discussionbridge-resource-") &&
             tag["name"] != resource
         }
        raise Error.new("identity_conflict")
      end
      unless tags.any? { |tag| tag["name"] == resource }
        raise Error.new("identity_conflict")
      end
      non_automation =
        tags.reject do |tag|
          tag["name"] == resource || INTERNAL_TAGS.include?(tag["name"])
        end
      taxonomy = @value.fetch("taxonomy_ids")
      if taxonomy
        unless relation_ids(non_automation) == taxonomy
          raise Error.new("identity_conflict")
        end
      elsif @value.fetch("stage") == "create_draft"
        raise Error.new("identity_conflict") unless non_automation.empty?
      elsif fields.key?("tags")
        baseline = command.fetch("baseline").fetch("tags")
        unless baseline.is_a?(Array) && baseline.all? { |tag| tag.is_a?(Hash) }
          raise Error.new("identity_conflict")
        end
        previous =
          baseline.reject do |tag|
            tag["name"] == resource || INTERNAL_TAGS.include?(tag["name"])
          end
        unless relation_ids(non_automation) == relation_ids(previous)
          raise Error.new("identity_conflict")
        end
      end
      true
    rescue KeyError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def ids!(values)
      @protocol.validate!("IdList", values)
      unless values.is_a?(Array) && values.uniq == values &&
               values.all? { |id|
                 id.is_a?(String) && /\A[a-f0-9]{24}\z/.match?(id)
               }
        raise Error.new("identity_conflict")
      end
    end

    def relation_ids(values)
      unless values.is_a?(Array) && values.all? { |entry| entry.is_a?(Hash) }
        return nil
      end
      ids = values.map { |entry| entry["id"] }
      ids!(ids)
      ids
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
  end
end
