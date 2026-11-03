# frozen_string_literal: true
# SPDX-License-Identifier: GPL-2.0-or-later
# Exact-number handling adapted from the DiscussionBridge receiver; see NOTICE.md
# and COPYING. This file's license is not replaced by the root MIT notice.

require "json"

module DiscussionBridgeGhost
  # Requests and responses have distinct transport budgets. Do not reuse the
  # receiver's 64 KiB request parser for valid 256 KiB response envelopes.
  # Preserve integer semantics BEFORE any parsed float is used by a caller.
  module WireJson
    MAX_COUNTER = 9_007_199_254_740_991
    TOKEN = /"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/

    class StrictObject < Hash
      def []=(key, value)
        raise Error.new("response_invalid") if key?(key)
        super
      end
    end

    def self.parse(input, maximum_bytes:)
      unless input.is_a?(String) && maximum_bytes.is_a?(Integer) &&
               maximum_bytes >= 0 && input.bytesize <= maximum_bytes
        raise Error.new("response_invalid")
      end
      text = input.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding? && !text.start_with?("\uFEFF")
        raise Error.new("response_invalid")
      end
      # JSON.parse does not perform JSON additions. Unlike the older parser,
      # the pinned json3 runtime rejects the removed create_additions option.
      parsed = JSON.parse(text, object_class: StrictObject)
      numbers =
        text
          .scan(TOKEN)
          .reject { |token| token.start_with?('"') }
          .map { |token| integer(token) }
      index = 0
      convert =
        lambda do |value|
          case value
          when Hash
            value.transform_values { |member| convert.call(member) }
          when Array
            value.map { |member| convert.call(member) }
          when Numeric
            number = numbers.fetch(index)
            index += 1
            number
          else
            value
          end
        end
      result = convert.call(parsed)
      raise Error.new("response_invalid") unless index == numbers.length
      result
    rescue JSON::ParserError, JSON::NestingError, EncodingError, IndexError
      raise Error.new("response_invalid"), cause: nil
    end

    def self.integer(token)
      raise Error.new("response_invalid") if token.start_with?("-")
      mantissa, exponent = token.split(/[eE]/, 2)
      whole, fraction = mantissa.split(".", 2)
      digits = (whole + fraction.to_s).sub(/\A0+/, "")
      return 0 if digits.empty?
      exponent ||= "0"
      exponent_digits = exponent.sub(/\A[+-]/, "").sub(/\A0+/, "")
      raise Error.new("response_invalid") if exponent_digits.length > 6
      power = exponent.to_i - fraction.to_s.length
      if power.negative?
        places = -power
        if places > digits.length || digits[-places, places].match?(/[1-9]/)
          raise Error.new("response_invalid")
        end
        digits = digits[0, digits.length - places]
      else
        if digits.length + power > MAX_COUNTER.to_s.length
          raise Error.new("response_invalid")
        end
        digits += "0" * power
      end
      digits = digits.sub(/\A0+/, "")
      if digits.length > MAX_COUNTER.to_s.length ||
           (
             digits.length == MAX_COUNTER.to_s.length &&
               digits > MAX_COUNTER.to_s
           )
        raise Error.new("response_invalid")
      end
      digits.to_i
    end
    private_class_method :integer
  end
end
