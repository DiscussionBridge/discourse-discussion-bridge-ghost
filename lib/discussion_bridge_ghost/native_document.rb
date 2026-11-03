# frozen_string_literal: true

require "json"
require "time"

module DiscussionBridgeGhost
  # Native Ghost JSON, not receiver wire JSON. Compare complete retained native
  # state, including unrelated editor/settings fields, without comparing native
  # derived HTML to Lexical source or treating a content match as dispatch proof.
  class NativeDocument
    include ProtectedDiagnostics

    GENERATED = %w[
      updated_at
      updated_by
      html
      plaintext
      url
      reading_time
      primary_author
      primary_tag
      count
    ].freeze
    WRITABLE = %w[
      id
      updated_at
      title
      slug
      status
      visibility
      lexical
      authors
      tags
      published_at
      custom_excerpt
      feature_image
      feature_image_alt
      feature_image_caption
      featured
      meta_title
      meta_description
      og_image
      og_title
      og_description
      twitter_image
      twitter_title
      twitter_description
      canonical_url
      codeinjection_head
      codeinjection_foot
      custom_template
    ].freeze
    MAXIMUM_BYTES = 33_554_432

    attr_reader :fields

    def self.parse(bytes, maximum_bytes:)
      unless bytes.is_a?(String) && bytes.bytesize <= maximum_bytes
        raise Error.new("response_invalid")
      end
      exact = bytes.dup.force_encoding(Encoding::UTF_8)
      unless exact.valid_encoding? && !exact.start_with?("\uFEFF")
        raise Error.new("response_invalid")
      end
      value = JSON.parse(exact, object_class: WireJson::StrictObject)
      raise Error.new("response_invalid") unless finite?(value)
      value
    rescue JSON::ParserError, EncodingError, ArgumentError
      raise Error.new("response_invalid"), cause: nil
    end

    def self.finite?(value)
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

    def initialize(command)
      @command = command
      @kind = command.fetch("identity").fetch("kind")
      @maximum = command.fetch("request").fetch("maximum_bytes")
      body =
        self.class.parse(
          command.dig("request", "body_bytes"),
          maximum_bytes: MAXIMUM_BYTES
        )
      @fields = body.fetch("#{@kind}s").fetch(0)
      unless @fields.is_a?(Hash) && (@fields.keys - WRITABLE).empty? &&
               @fields.all? { |key, value|
                 command.fetch("candidate")[key] == value
               }
        raise Error.new("identity_conflict")
      end
    rescue KeyError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    def response_object(bytes)
      body = self.class.parse(bytes, maximum_bytes: @maximum)
      key = "#{@kind}s"
      other = @kind == "post" ? "pages" : "posts"
      unless body.is_a?(Hash) && !body.key?(other) && body[key].is_a?(Array) &&
               body[key].length == 1
        raise Error.new("response_invalid")
      end
      object = body.fetch(key).first
      identity!(object)
      object.merge("type" => @kind)
    end

    def verify!(response:, current:)
      identity!(response)
      identity!(current)
      unless current["id"] == response["id"] &&
               current["updated_at"] == response["updated_at"]
        raise Error.new("identity_conflict")
      end
      # A response may omit Lexical unless formats were requested. The exact
      # subsequent native lookup must contain every field actually written.
      @fields.each do |key, expected|
        next if %w[id updated_at].include?(key)
        same!(key, expected, current)
        same!(key, expected, response) if response.key?(key)
      end
      # A request cannot silently erase an unrelated card, metadata field or
      # relationship. Fields deliberately changed are verified above. Derived
      # fields are checked by the owned-fragment/public verifier, not guessed.
      baseline = @command.fetch("baseline")
      if baseline
        baseline.each do |key, expected|
          next if @fields.key?(key) || GENERATED.include?(key)
          same!(key, expected, current)
        end
      end
      response.each do |key, expected|
        next if GENERATED.include?(key)
        same!(key, expected, current)
      end
      true
    end

    def baseline_matches!(current)
      baseline = @command.fetch("baseline")
      unless baseline.is_a?(Hash) && current.is_a?(Hash) &&
               current["id"] == baseline["id"] && current["type"] == @kind &&
               current["updated_at"] == baseline["updated_at"] &&
               current["html"] == baseline["html"]
        raise Error.new("identity_conflict")
      end
      baseline.each do |key, expected|
        next if GENERATED.include?(key)
        same!(key, expected, current)
      end
      true
    end

    private

    def identity!(object)
      valid =
        object.is_a?(Hash) && object["id"].is_a?(String) &&
          /\A[a-f0-9]{24}\z/.match?(object["id"]) &&
          (!object.key?("type") || object["type"] == @kind) &&
          object["updated_at"].is_a?(String)
      raise Error.new("identity_conflict") unless valid
      Time.iso8601(object.fetch("updated_at"))
      native_id = @command.dig("identity", "native_id")
      if native_id && native_id != object.fetch("id")
        raise Error.new("identity_conflict")
      end
    rescue ArgumentError
      raise Error.new("response_invalid"), cause: nil
    end

    def same!(key, expected, object)
      unless object.key?(key) && equivalent?(key, expected, object[key])
        raise Error.new("identity_conflict")
      end
    end

    def equivalent?(key, expected, actual)
      if key == "published_at" && expected.is_a?(String) && actual.is_a?(String)
        begin
          return Time.iso8601(expected) == Time.iso8601(actual)
        rescue ArgumentError
          return false
        end
      end
      if %w[authors tags].include?(key)
        unless expected.is_a?(Array) && actual.is_a?(Array) &&
                 expected.length == actual.length
          return false
        end
        # Relation order matters (the first author/tag is primary). Native API
        # relations may be requested by ID or, for a new internal tag, by name.
        return(
          expected
            .zip(actual)
            .all? do |wanted, observed|
              wanted.is_a?(Hash) && observed.is_a?(Hash) &&
                if wanted["id"]
                  observed["id"] == wanted["id"]
                else
                  key == "tags" && wanted["name"].is_a?(String) &&
                    observed["name"] == wanted["name"]
                end
            end
        )
      end
      if key == "lexical" && expected.is_a?(String) && actual.is_a?(String)
        return(
          self.class.parse(expected, maximum_bytes: @maximum) ==
            self.class.parse(actual, maximum_bytes: @maximum)
        )
      end
      expected == actual
    end
  end
end
