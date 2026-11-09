# frozen_string_literal: true

require "json"

module DiscussionBridgeGhost
  class SupervisedScope
    ENV_KEY = "DISCOURSE_DISCUSSION_BRIDGE_GHOST_SCOPE"
    DIRECTIONS = %w[outbound inbound].freeze
    CONNECTION_ID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
    TAG = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

    def initialize(value)
      @unrestricted = value == "unrestricted"
      @directions = parse(value)
    end

    def active?(direction)
      @unrestricted || @directions.key?(direction)
    end

    def connection?(direction, connection_id)
      rule = @directions[direction]
      @unrestricted || (rule && rule.fetch("connection_id") == connection_id)
    end

    def category(direction)
      @directions.dig(direction, "category_id")
    end

    def outbound?(connection_id, category_id)
      @unrestricted || connection?("outbound", connection_id) && category("outbound") == category_id
    end

    def inbound?(connection_id, category_id, tag)
      @unrestricted || connection?("inbound", connection_id) && category("inbound") == category_id &&
        @directions.dig("inbound", "tag") == tag
    end

    private

    def parse(value)
      return {} unless value.is_a?(String) && value.bytesize <= 2048 && value.start_with?("{")

      directions = JSON.parse(value)
      return {} unless directions.is_a?(Hash) && (directions.keys - DIRECTIONS).empty? &&
        directions.all? { |direction, rule| valid?(direction, rule) }

      directions.each_value(&:freeze).freeze
    rescue JSON::ParserError
      {}
    end

    def valid?(direction, rule)
      fields = direction == "inbound" ? %w[category_id connection_id tag] : %w[category_id connection_id]
      return false unless rule.is_a?(Hash) && rule.keys.sort == fields &&
        rule["connection_id"].is_a?(String) && CONNECTION_ID.match?(rule["connection_id"]) &&
        rule["category_id"].is_a?(Integer) && rule["category_id"].positive?

      direction == "outbound" ||
        (rule["tag"].is_a?(String) && rule["tag"].bytesize <= 100 && TAG.match?(rule["tag"]))
    end

    CURRENT = new(ENV[ENV_KEY]).freeze
  end
end
