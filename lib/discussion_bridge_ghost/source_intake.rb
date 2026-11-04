# frozen_string_literal: true

require "base64"
require "digest"
require_relative "execution_context"

module DiscussionBridgeGhost
  # Authenticated feed intake and immutable complete-source cache, NOT a grant
  # to write Ghost or acknowledge work. Each page stages every event and source
  # before its continuation commits. Content advances in bounded byte chunks;
  # native preparation cannot observe a partial or merely historical body.
  class SourceIntake
    include ProtectedDiagnostics

    STATE = "source_feed_state"
    EVENT = "source_feed_event"
    SOURCE = "source_revision"
    PROGRESS = "source_content_progress"
    CHUNK = "source_content_chunk"
    MAXIMUM_CONTENT = 32 * 1024 * 1024
    MAXIMUM_CHUNK = 32_768
    MAXIMUM_CHUNKS = 4096

    class Unavailable < Error
      attr_reader :receiver_code, :response_status

      def initialize(result)
        super("source_intake_unavailable")
        @receiver_code = result.value.fetch("code").dup.freeze
        @response_status = result.status
      end
    end

    def initialize(context:)
      unless context.is_a?(ExecutionContext)
        raise Error.new("identity_conflict")
      end
      @context, @installation = context, context.installation
    end

    # Exactly one GET/page per call. Failed/expired/scope-changed cursors are
    # retained, never reset here. A later reconciliation must preserve inventory.
    def advance
      check!
      before = read(STATE, "current")
      state = before || initial_state
      query = { "stream" => state.fetch("stream") }
      query["cursor"] = state.fetch("cursor") if state.fetch("cursor")
      page = success!(@context.read("V4-06", query: query))
      validate_page!(page, state)
      after = continuation(page, state)
      @context.commit do
        unless read(STATE, "current") == before
          raise Error.new("identity_conflict")
        end
        page
          .fetch("items")
          .each do |event|
            stage(EVENT, event.fetch("event_id"), "event" => event)
            if event.fetch("event_type") == "publication"
              source = event.fetch("source")
              stage(SOURCE, source_key(source), "source" => source)
            end
          end
        write(STATE, "current", after)
      end
      snapshot(page)
    rescue KeyError, TypeError, ArgumentError
      raise Error.new("identity_conflict"), cause: nil
    end

    def event(event_id)
      check!
      @context.protocol.validate!("UUID", event_id)
      value = read(EVENT, event_id)&.fetch("event")
      raise Error.new("identity_conflict") unless value
      @context.protocol.validate!("SourceEvent", value)
      unless value.fetch("event_id") == event_id
        raise Error.new("identity_conflict")
      end
      snapshot(value)
    end

    def source(event_id)
      value = event(event_id)
      unless value.fetch("event_type") == "publication"
        raise Error.new("identity_conflict")
      end
      metadata = value.fetch("source")
      retained = read(SOURCE, source_key(metadata))&.fetch("source")
      raise Error.new("identity_conflict") unless retained == metadata
      snapshot(metadata)
    end

    # Bounded work suitable for a scheduled job. The return value is progress,
    # not content/publication permission. No caller-supplied Source is accepted.
    def advance_content(
      event_id,
      chunk_budget: 1,
      maximum_bytes: MAXIMUM_CONTENT
    )
      unless chunk_budget.is_a?(Integer) && (1..8).cover?(chunk_budget)
        raise Error.new("configuration_invalid")
      end
      metadata = source(event_id)
      content_limit!(metadata, maximum_bytes)
      key = source_key(metadata)
      progress = content_progress(key, metadata)
      chunk_budget.times do
        break if progress.fetch("complete")
        if progress.fetch("chunks") >= MAXIMUM_CHUNKS
          raise Error.new("source_content_limit")
        end
        offset = progress.fetch("offset")
        chunk = fetch_chunk(metadata, offset)
        final = chunk.fetch("next_offset").nil?
        if final
          # Verify the entire byte stream BEFORE committing completion. A hash,
          # count or encoding failure cannot turn missing data into an excerpt.
          assembled(key, metadata, progress, final_chunk: chunk)
        end
        next_progress = {
          "offset" =>
            (
              if final
                metadata.fetch("content_bytes")
              else
                chunk.fetch("next_offset")
              end
            ),
          "complete" => final,
          "chunks" => progress.fetch("chunks") + 1
        }
        @context.commit do
          unless content_progress(key, metadata) == progress
            raise Error.new("identity_conflict")
          end
          stage(CHUNK, chunk_key(key, offset), "chunk" => chunk)
          write(PROGRESS, key, "source_key" => key, "progress" => next_progress)
        end
        progress = next_progress
      end
      snapshot(
        progress.merge("content_bytes" => metadata.fetch("content_bytes"))
      )
    rescue KeyError, TypeError, ArgumentError
      raise Error.new("identity_conflict"), cause: nil
    end

    # Even a complete local cache is NOT current eligibility. The end-boundary
    # GET rechecks the actual scoped receiver before returning complete bytes.
    # Current work/policy/native-ownership checks still belong to the coordinator.
    def content(event_id, maximum_bytes: MAXIMUM_CONTENT)
      metadata = source(event_id)
      content_limit!(metadata, maximum_bytes)
      key = source_key(metadata)
      progress = content_progress(key, metadata)
      raise Error.new("identity_conflict") unless progress.fetch("complete")
      terminal = fetch_chunk(metadata, metadata.fetch("content_bytes"))
      unless terminal.fetch("next_offset").nil? && decoded(terminal).empty?
        raise Error.new("identity_conflict")
      end
      text = assembled(key, metadata, progress)
      @context.assert!
      text.freeze
    rescue KeyError, TypeError, ArgumentError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def check!
      @context.outside_transaction!
      @context.assert!
    end

    def success!(result)
      raise Unavailable.new(result) unless result.status == 200
      result.value
    end

    def initial_state
      {
        "stream" => "initial",
        "cursor" => nil,
        "last_source_id" => nil,
        "last_sequence" => nil,
        "pages" => 0
      }
    end

    def validate_page!(page, state)
      unless page.fetch("stream") == state.fetch("stream")
        raise Error.new("identity_conflict")
      end
      next_cursor, checkpoint =
        page.values_at("next_cursor", "checkpoint_cursor")
      if page.fetch("stream") == "initial"
        unless (next_cursor.nil? && checkpoint) ||
                 (next_cursor && checkpoint.nil?)
          raise Error.new("identity_conflict")
        end
        previous = state.fetch("last_source_id")
        page
          .fetch("items")
          .each do |item|
            unless item.fetch("event_type") == "publication"
              raise Error.new("identity_conflict")
            end
            id = item.fetch("source").fetch("source_id")
            if previous && id.b <= previous.b
              raise Error.new("identity_conflict")
            end
            previous = id
          end
      else
        raise Error.new("identity_conflict") unless checkpoint
        previous = state.fetch("last_sequence")
        page
          .fetch("items")
          .each do |item|
            sequence = item.fetch("event_sequence")
            if previous && sequence <= previous
              # A previously staged exact event can be delivered again harmlessly.
              unless read(EVENT, item.fetch("event_id"))&.fetch("event") == item
                raise Error.new("identity_conflict")
              end
            else
              previous = sequence
            end
          end
      end
    end

    def continuation(page, state)
      initial = page.fetch("stream") == "initial"
      more = page.fetch("next_cursor")
      {
        "stream" => more && initial ? "initial" : "changes",
        "cursor" => more || page.fetch("checkpoint_cursor"),
        "last_source_id" =>
          (
            if initial
              page.fetch("items").last&.dig("source", "source_id") ||
                state.fetch("last_source_id")
            else
              nil
            end
          ),
        "last_sequence" =>
          (
            if initial
              nil
            else
              [
                state.fetch("last_sequence"),
                *page.fetch("items").map { |item| item.fetch("event_sequence") }
              ].compact.max
            end
          ),
        "pages" => state.fetch("pages") + 1
      }
    end

    def content_limit!(metadata, maximum)
      unless maximum.is_a?(Integer) && (1..MAXIMUM_CONTENT).cover?(maximum)
        raise Error.new("configuration_invalid")
      end
      if metadata.fetch("content_bytes") > maximum
        raise Error.new("source_content_limit")
      end
    end

    def content_progress(key, metadata)
      retained = read(PROGRESS, key)
      unless retained
        return { "offset" => 0, "complete" => false, "chunks" => 0 }
      end
      progress = retained.fetch("progress")
      unless retained.fetch("source_key") == key &&
               progress.keys.sort == %w[chunks complete offset] &&
               [true, false].include?(progress["complete"]) &&
               progress["offset"].is_a?(Integer) &&
               (0..metadata.fetch("content_bytes")).cover?(
                 progress["offset"]
               ) && progress["chunks"].is_a?(Integer) &&
               (1..MAXIMUM_CHUNKS).cover?(progress["chunks"]) &&
               (
                 !progress["complete"] ||
                   progress["offset"] == metadata.fetch("content_bytes")
               )
        raise Error.new("identity_conflict")
      end
      progress
    end

    def fetch_chunk(metadata, offset)
      chunk =
        success!(
          @context.read(
            "V4-07",
            path: metadata.slice("source_id", "source_revision"),
            query: {
              "offset" => offset
            }
          )
        )
      validate_chunk!(chunk, metadata, offset)
      chunk
    end

    def validate_chunk!(chunk, metadata, offset)
      @context.protocol.validate!("ContentChunk", chunk)
      unless chunk.slice(
               "source_id",
               "source_revision",
               "content_sha256",
               "content_bytes"
             ) ==
               metadata.slice(
                 "source_id",
                 "source_revision",
                 "content_sha256",
                 "content_bytes"
               ) && chunk.fetch("offset") == offset
        raise Error.new("identity_conflict")
      end
      size = decoded(chunk).bytesize
      finish = offset + size
      next_offset = chunk.fetch("next_offset")
      unless size <= MAXIMUM_CHUNK &&
               finish <= metadata.fetch("content_bytes") &&
               (
                 if next_offset
                   size.positive? && next_offset == finish
                 else
                   finish == metadata.fetch("content_bytes")
                 end
               )
        raise Error.new("identity_conflict")
      end
    end

    def assembled(key, metadata, progress, final_chunk: nil)
      bytes = +"".b
      offset = 0
      count = progress.fetch("chunks")
      count.times do |index|
        chunk = read(CHUNK, chunk_key(key, offset))&.fetch("chunk")
        raise Error.new("identity_conflict") unless chunk
        validate_chunk!(chunk, metadata, offset)
        bytes << decoded(chunk)
        offset = bytes.bytesize
        if chunk.fetch("next_offset").nil? &&
             (final_chunk || index != count - 1)
          raise Error.new("identity_conflict")
        end
      end
      unless offset == progress.fetch("offset")
        raise Error.new("identity_conflict")
      end
      bytes << decoded(final_chunk) if final_chunk
      bytes.force_encoding(Encoding::UTF_8)
      unless bytes.bytesize == metadata.fetch("content_bytes") &&
               Digest::SHA256.hexdigest(bytes) ==
                 metadata.fetch("content_sha256") && bytes.valid_encoding?
        raise Error.new("identity_conflict")
      end
      bytes
    end

    def decoded(chunk)
      Base64.strict_decode64(chunk.fetch("content_base64"))
    end

    def source_key(metadata)
      Digest::SHA256.hexdigest(
        JSON.generate(metadata.values_at("source_id", "source_revision"))
      )
    end

    def chunk_key(key, offset)
      "#{key}:#{offset}"
    end

    def row(kind, key)
      @installation.operational_records.find_by(kind: kind, record_key: key)
    end

    def read(kind, key)
      record = row(kind, key)
      return unless record
      value = record.private_payload
      unless value.is_a?(Hash) && value["format"] == "ghost-source-intake-1" &&
               value["binding"] == @context.binding && value["kind"] == kind &&
               value["key"] == key && value["value"].is_a?(Hash)
        raise Error.new("identity_conflict")
      end
      value.fetch("value")
    end

    def stage(kind, key, value)
      previous = read(kind, key)
      if previous
        raise Error.new("identity_conflict") unless previous == value
      else
        write(kind, key, value)
      end
    end

    def write(kind, key, value)
      payload = {
        "format" => "ghost-source-intake-1",
        "binding" => @context.binding,
        "kind" => kind,
        "key" => key,
        "value" => value
      }
      encrypted =
        @installation.envelope.encrypt(
          "operational_record",
          payload,
          binding: JSON.generate([kind, key])
        )
      existing = row(kind, key)
      if existing
        existing.update!(encrypted_payload: encrypted)
      else
        @installation.operational_records.create!(
          kind: kind,
          record_key: key,
          encrypted_payload: encrypted
        )
      end
    end

    def snapshot(value)
      case value
      when Hash
        value.to_h { |key, item| [key.dup.freeze, snapshot(item)] }.freeze
      when Array
        value.map { |item| snapshot(item) }.freeze
      when String
        value.dup.freeze
      else
        value.freeze
      end
    end
  end
end
