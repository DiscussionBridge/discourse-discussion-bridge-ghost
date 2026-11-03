# frozen_string_literal: true

require "date"
require "time"
require_relative "error"

module DiscussionBridgeGhost
  # Source activity, never native-save/build time. Ghost stores whole seconds;
  # chronology is checked at full source precision before that projection.
  class SourceActivity
    def self.publication_date(created_at:, updated_at:)
      created = created_at.nil? ? nil : instant(created_at)
      updated = instant(updated_at)
      if created && updated < created
        raise Error.new("native_source_unavailable")
      end
      Time.at(updated.to_r.floor).utc.iso8601(3)
    end

    def self.instant(value)
      parts =
        value.is_a?(String) &&
          /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})\z/.match(
            value
          )
      valid =
        parts &&
          Date.valid_date?(
            parts[1].to_i,
            parts[2].to_i,
            parts[3].to_i,
            Date::GREGORIAN
          ) && parts[4].to_i <= 23 && parts[5].to_i <= 59 &&
          parts[6].to_i <= 59 &&
          (
            parts[8] == "Z" ||
              (parts[8][1, 2].to_i <= 23 && parts[8][4, 2].to_i <= 59)
          )
      raise Error.new("native_source_unavailable") unless valid
      Time.iso8601(value).utc
    rescue ArgumentError, TypeError
      raise Error.new("native_source_unavailable"), cause: nil
    end
    private_class_method :instant
  end
end
