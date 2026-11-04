# frozen_string_literal: true

require "digest"
require_relative "work_authority"
require_relative "native_document"
require_relative "native_managed_baseline"

module DiscussionBridgeGhost
  # Descriptive history only. One bounded genuine receiver GET per advance.
  # Raw pages are immutable; progress and the page commit atomically. No Ghost
  # mutation, native completion, ownership receipt or receiver ACK is produced.
  class PolicyHistoryIntake
    include ProtectedDiagnostics

    ENTRY = "policy_history_intake"
    PAGE = "policy_history_page"
    # Prior proof formats remain historical; never promote or fall back to them.
    VERIFICATION = "policy_history_verification_v2"
    VERIFIED = "policy_history_verified_v2"
    REVISION = "policy_history_revision_v2"
    GENERATION_SQL = "split_part(record_key, ':', 3) COLLATE \"C\""
    FIELDS = %w[
      format
      binding
      mapping
      work
      after_policy_revision
      through_policy_revision
      next_policy_revision
      complete
      pages
      previous_sha256
      released
    ].sort.freeze

    def initialize(context:, authority:, baseline:)
      unless context.is_a?(ExecutionContext) &&
               authority.is_a?(WorkAuthority) && authority.bound_to?(context) &&
               baseline.is_a?(NativeManagedBaseline) &&
               baseline.value.fetch("binding") == context.binding
        raise Error.new("identity_conflict")
      end
      @context, @authority, @baseline = context, authority, baseline
      @installation, @protocol = context.installation, context.protocol
      @after = baseline.value.fetch("content_policy_revision")
    end

    def advance
      bind!
      previous = read
      state = previous || initial
      if state.fetch("complete")
        return { "complete" => true, "pages" => state.fetch("pages") }.freeze
      end
      result =
        @context.read(
          "V4-37",
          query: {
            "after_policy_revision" => state.fetch("next_policy_revision"),
            "through_policy_revision" => @through
          }
        )
      raise Error.new("response_invalid") unless result.status == 200
      page = result.value
      unless page.fetch("connection_id") ==
               @installation.connection_public_id &&
               page.fetch("after_policy_revision") ==
                 state.fetch("next_policy_revision") &&
               page.fetch("through_policy_revision") == @through
        raise Error.new("identity_conflict")
      end
      current!
      # Strict wire objects are immutable decoding values, not working hashes.
      after = plain(state)
      after["pages"] += 1
      page_value = {
        "format" => "ghost-policy-history-page-1",
        "binding" => @context.binding,
        "intake_key" => @key,
        "ordinal" => after.fetch("pages"),
        "previous_sha256" => state.fetch("previous_sha256"),
        "body" => page
      }
      after["previous_sha256"] = Digest::SHA256.hexdigest(
        JSON.generate(page_value)
      )
      after["complete"] = page.fetch("next_policy_revision").nil?
      after["next_policy_revision"] = page.fetch("next_policy_revision") ||
        @through
      after["released"] |= releases(page)
      @context.commit do
        existing = row(ENTRY, @key)
        unless existing&.private_payload == previous
          raise Error.new("identity_conflict")
        end
        page_key = page_key(after.fetch("pages"))
        raise Error.new("identity_conflict") if row(PAGE, page_key)
        create(PAGE, page_key, page_value)
        if existing
          existing.update!(encrypted_payload: encrypt(ENTRY, @key, after))
        else
          create(ENTRY, @key, after)
        end
      end
      current!
      {
        "complete" => after.fetch("complete"),
        "pages" => after.fetch("pages")
      }.freeze
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    # Bounded independent replay of the immutable pages. The caller supplies a
    # continuation offset, never release facts. No partial interval is usable.
    def verified_page(ordinal)
      bind!
      state = read
      unless state && state.fetch("complete") && ordinal.is_a?(Integer) &&
               ordinal.between?(1, state.fetch("pages"))
        raise Error.new("native_state_not_ready")
      end
      page = row(PAGE, page_key(ordinal))&.private_payload
      validate_page!(page, ordinal)
      snapshot(page)
    end

    def progress
      bind!
      state = read || initial
      snapshot(state)
    end

    # A second, bounded pass verifies every immutable page's exact predecessor
    # digest and revision. Download completion alone cannot release a field.
    def verify_next
      bind!
      downloaded = read || initial
      unless downloaded.fetch("complete")
        raise Error.new("native_state_not_ready")
      end
      if downloaded.fetch("pages").zero?
        return { "complete" => true, "pages" => 0 }.freeze
      end
      @raw_guard = guard_revision!("pages:#{@key}")
      @verification_key = "#{@key}:#{@raw_guard}"
      prior_row = row(VERIFICATION, @verification_key)
      prior = prior_row&.private_payload
      verified = prior || initial_verification
      validate_verification!(verified, downloaded)
      if (completed = row(VERIFIED, @verification_key))
        unless completed.private_payload == verified &&
                 verified.fetch("pages") == downloaded.fetch("pages") &&
                 verified.fetch("cursor") == @through &&
                 verified.fetch("sha256") == downloaded.fetch("previous_sha256")
          raise Error.new("identity_conflict")
        end
        return { "complete" => true, "pages" => verified.fetch("pages") }.freeze
      end
      ordinal = verified.fetch("pages") + 1
      page = verified_page(ordinal)
      unless page.fetch("previous_sha256") == verified.fetch("sha256") &&
               page.dig("body", "after_policy_revision") ==
                 verified.fetch("cursor")
        raise Error.new("identity_conflict")
      end
      after = plain(verified)
      after["pages"] = ordinal
      after["sha256"] = Digest::SHA256.hexdigest(JSON.generate(page))
      after["cursor"] = page.dig("body", "next_policy_revision") || @through
      releases(page.fetch("body")).each do |relation|
        after.fetch("releases")[relation] = {
          "ordinal" => ordinal,
          "sha256" => after.fetch("sha256")
        }
      end
      complete = ordinal == downloaded.fetch("pages")
      if complete &&
           (
             after.fetch("cursor") != @through ||
               after.fetch("sha256") != downloaded.fetch("previous_sha256")
           )
        raise Error.new("identity_conflict")
      end
      current!
      @context.commit do
        guard_revision!("pages:#{@key}", expected: @raw_guard, lock: true)
        revision_guard = "revisions:#{@verification_key}"
        token =
          guard_revision!(
            revision_guard,
            expected: verified.fetch("revision_guard"),
            lock: true,
            missing: verified.fetch("pages").zero?
          )
        if verified.fetch("pages").zero? && token
          raise Error.new("identity_conflict")
        end
        existing = row(VERIFICATION, @verification_key)
        unless existing&.private_payload == prior
          raise Error.new("identity_conflict")
        end
        # Anchor/event sightings and progress commit atomically. Their own
        # mutation guard prevents lost sightings resetting uniqueness memory.
        remember_revision!(@after, 0) if verified.fetch("pages").zero?
        page
          .fetch("body")
          .fetch("items")
          .each do |event|
            remember_revision!(event.fetch("policy_revision"), ordinal)
          end
        after["revision_guard"] = guard_revision!(revision_guard, lock: true)
        if existing
          existing.update!(
            encrypted_payload: encrypt(VERIFICATION, @verification_key, after)
          )
        else
          create(VERIFICATION, @verification_key, after)
        end
        if complete
          if row(VERIFIED, @verification_key)
            raise Error.new("identity_conflict")
          end
          create(VERIFIED, @verification_key, after)
        end
      end
      current!
      { "complete" => complete, "pages" => ordinal }.freeze
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    # Indexed guards keep all retained dependencies live without an unbounded
    # byte rescan. Bracket witness reads and retain tokens through subsequent
    # ownership/pre-write checks. Neither partial nor legacy proof is usable.
    def self.released_relations(
      context:,
      identity:,
      after_revision:,
      after_generation:,
      through_generation:,
      before_record_id: nil
    )
      context.outside_transaction!
      context.assert!
      protocol = context.protocol
      protocol.validate!("Revision", after_revision)
      protocol.validate!("UInt", after_generation)
      protocol.validate!("PositiveUInt", through_generation)
      if after_generation > through_generation
        raise Error.new("identity_conflict")
      end
      mapping = identity.fetch("mapping_id")
      protocol.validate!("UUID", mapping)
      prefix = "#{mapping}:#{Digest::SHA256.hexdigest(after_revision)}:"
      scope =
        context
          .installation
          .operational_records
          .where(kind: VERIFIED, mapping_public_id: mapping)
          .where(
            "split_part(record_key, ':', 2) = ?",
            Digest::SHA256.hexdigest(after_revision)
          )
          .where(
            "#{GENERATION_SQL} > ? AND #{GENERATION_SQL} <= ?",
            after_generation.to_s.rjust(16, "0"),
            through_generation.to_s.rjust(16, "0")
          )
      if before_record_id
        unless before_record_id.is_a?(Integer) && before_record_id.positive?
          raise Error.new("identity_conflict")
        end
        scope = scope.where("id < ?", before_record_id)
      end
      record = scope.order(Arel.sql("#{GENERATION_SQL} DESC"), id: :desc).first
      return [] unless record
      proof = record.private_payload
      unless proof.is_a?(Hash) &&
               proof.keys.sort ==
                 %w[
                   after_policy_revision
                   binding
                   cursor
                   format
                   mapping
                   pages
                   raw_guard
                   releases
                   revision_guard
                   sha256
                   work
                 ] &&
               proof.fetch("format") == "ghost-policy-history-verification-2" &&
               proof.fetch("binding") == context.binding &&
               proof.fetch("after_policy_revision") == after_revision &&
               proof.fetch("mapping").slice(
                 "mapping_id",
                 "resource_id",
                 "external_id"
               ) ==
                 identity.slice("mapping_id", "resource_id", "external_id") &&
               proof.fetch("mapping").fetch("connection_id") ==
                 context.installation.connection_public_id &&
               proof.dig("work", "mapping_id") == mapping &&
               proof.fetch("cursor") == proof.dig("work", "policy_revision") &&
               proof.fetch("pages").is_a?(Integer) &&
               proof.fetch("pages").positive? &&
               proof.fetch("sha256").is_a?(String) &&
               /\A[a-f0-9]{64}\z/.match?(proof.fetch("sha256")) &&
               proof.fetch("releases").is_a?(Hash) &&
               (proof.fetch("releases").keys - %w[authors taxonomy]).empty?
        raise Error.new("identity_conflict")
      end
      generation = proof.dig("work", "lease_generation")
      protocol.validate!("PositiveUInt", generation)
      unless generation > after_generation &&
               generation <= through_generation &&
               proof.fetch("raw_guard").is_a?(String) &&
               SecretEnvelope::UUID.match?(proof.fetch("raw_guard")) &&
               proof.fetch("revision_guard").is_a?(String) &&
               SecretEnvelope::UUID.match?(proof.fetch("revision_guard")) &&
               record.record_key ==
                 prefix + generation.to_s.rjust(16, "0") +
                   ":#{proof.fetch("raw_guard")}"
        raise Error.new("identity_conflict")
      end
      intake_key = prefix + generation.to_s.rjust(16, "0")
      context.retain_history_guard!(
        "pages:#{intake_key}",
        proof.fetch("raw_guard")
      )
      context.retain_history_guard!(
        "revisions:#{record.record_key}",
        proof.fetch("revision_guard")
      )
      proof
        .fetch("releases")
        .each do |relation, witness|
          unless witness.is_a?(Hash) &&
                   witness.keys.sort == %w[ordinal sha256] &&
                   witness.fetch("ordinal").is_a?(Integer) &&
                   witness.fetch("ordinal").between?(1, proof.fetch("pages"))
            raise Error.new("identity_conflict")
          end
          key = "#{intake_key}:#{witness.fetch("ordinal").to_s.rjust(16, "0")}"
          page_row =
            context.installation.operational_records.find_by(
              kind: PAGE,
              record_key: key,
              mapping_public_id: mapping
            )
          page = page_row&.private_payload
          unless page &&
                   Digest::SHA256.hexdigest(JSON.generate(page)) ==
                     witness.fetch("sha256") &&
                   page.fetch("binding") == context.binding &&
                   page.fetch("intake_key") == intake_key &&
                   page.fetch("ordinal") == witness.fetch("ordinal")
            raise Error.new("identity_conflict")
          end
          protocol.validate!("PolicyHistoryPage", page.fetch("body"))
          field = relation == "authors" ? "author_ids" : "taxonomy_ids"
          unless page.dig("body", "connection_id") ==
                   context.installation.connection_public_id &&
                   page.dig("body", "through_policy_revision") ==
                     proof.fetch("cursor") &&
                   page
                     .fetch("body")
                     .fetch("items")
                     .any? { |event| event.fetch(field).empty? }
            raise Error.new("identity_conflict")
          end
        end
      context.assert!
      proof.fetch("releases").keys.freeze
    rescue KeyError, ArgumentError, TypeError, JSON::GeneratorError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def bind!
      @context.outside_transaction!
      state =
        @authority.guard!(
          operation: :mutate,
          native_id: @authority.initial_native_id
        )
      @work = state.fetch("work").slice(*WorkAuthority::WORK_FIELDS)
      @mapping = state.fetch("mapping").slice(*WorkAuthority::MAPPING_FIELDS)
      identity = @baseline.value.fetch("identity")
      unless @mapping.slice("mapping_id", "resource_id", "external_id") ==
               identity.slice("mapping_id", "resource_id", "external_id")
        raise Error.new("identity_conflict")
      end
      @through = @work.fetch("policy_revision")
      @key =
        "#{@mapping.fetch("mapping_id")}:#{Digest::SHA256.hexdigest(@after)}:#{@work.fetch("lease_generation").to_s.rjust(16, "0")}"
      current!
    end

    def current!
      @authority.guard!(
        operation: :mutate,
        native_id: @authority.initial_native_id
      )
    end

    def initial
      {
        "format" => "ghost-policy-history-intake-1",
        "binding" => @context.binding,
        "mapping" => @mapping,
        "work" => @work,
        "after_policy_revision" => @after,
        "through_policy_revision" => @through,
        "next_policy_revision" => @after,
        "complete" => @after == @through,
        "pages" => 0,
        "previous_sha256" => nil,
        "released" => []
      }
    end

    def initial_verification
      {
        "format" => "ghost-policy-history-verification-2",
        "binding" => @context.binding,
        "mapping" => @mapping,
        "work" => @work,
        "after_policy_revision" => @after,
        "pages" => 0,
        "raw_guard" => @raw_guard,
        "revision_guard" => nil,
        "sha256" => nil,
        "cursor" => @after,
        "releases" => {
        }
      }
    end

    def validate_verification!(state, downloaded)
      expected = initial_verification
      unless state.is_a?(Hash) && state.keys.sort == expected.keys.sort &&
               state.slice(
                 "format",
                 "binding",
                 "mapping",
                 "work",
                 "after_policy_revision"
               ) ==
                 expected.slice(
                   "format",
                   "binding",
                   "mapping",
                   "work",
                   "after_policy_revision"
                 ) && state.fetch("pages").is_a?(Integer) &&
               state.fetch("pages").between?(0, downloaded.fetch("pages")) &&
               state.fetch("releases").is_a?(Hash) &&
               (state.fetch("releases").keys - %w[authors taxonomy]).empty?
        raise Error.new("identity_conflict")
      end
      if state.fetch("pages").zero?
        raise Error.new("identity_conflict") unless state == expected
      else
        unless state.fetch("raw_guard") == @raw_guard &&
                 state.fetch("revision_guard").is_a?(String) &&
                 SecretEnvelope::UUID.match?(state.fetch("revision_guard"))
          raise Error.new("identity_conflict")
        end
        guard_revision!("pages:#{@key}", expected: state.fetch("raw_guard"))
        guard_revision!(
          "revisions:#{@verification_key}",
          expected: state.fetch("revision_guard")
        )
        page = verified_page(state.fetch("pages"))
        expected_cursor = page.dig("body", "next_policy_revision") || @through
        unless Digest::SHA256.hexdigest(JSON.generate(page)) ==
                 state.fetch("sha256") &&
                 state.fetch("cursor") == expected_cursor
          raise Error.new("identity_conflict")
        end
      end
    end

    def read
      record = row(ENTRY, @key)
      return unless record
      state = record.private_payload
      unless state.is_a?(Hash) && state.keys.sort == FIELDS &&
               state.slice(
                 "format",
                 "binding",
                 "mapping",
                 "work",
                 "after_policy_revision",
                 "through_policy_revision"
               ) ==
                 initial.slice(
                   "format",
                   "binding",
                   "mapping",
                   "work",
                   "after_policy_revision",
                   "through_policy_revision"
                 ) && state.fetch("pages").is_a?(Integer) &&
               state.fetch("pages").positive? &&
               [true, false].include?(state.fetch("complete")) &&
               state.fetch("released").is_a?(Array) &&
               (state.fetch("released") - %w[authors taxonomy]).empty? &&
               state.fetch("released").uniq == state.fetch("released") &&
               record.mapping_public_id == @mapping.fetch("mapping_id")
        raise Error.new("identity_conflict")
      end
      last = row(PAGE, page_key(state.fetch("pages")))&.private_payload
      validate_page!(last, state.fetch("pages"))
      body = last.fetch("body")
      expected_cursor = body.fetch("next_policy_revision") || @through
      unless Digest::SHA256.hexdigest(JSON.generate(last)) ==
               state.fetch("previous_sha256") &&
               state.fetch("complete") ==
                 body.fetch("next_policy_revision").nil? &&
               state.fetch("next_policy_revision") == expected_cursor
        raise Error.new("identity_conflict")
      end
      state
    end

    def validate_page!(page, ordinal)
      unless page.is_a?(Hash) &&
               page.keys.sort ==
                 %w[binding body format intake_key ordinal previous_sha256] &&
               page.fetch("format") == "ghost-policy-history-page-1" &&
               page.fetch("binding") == @context.binding &&
               page.fetch("intake_key") == @key &&
               page.fetch("ordinal") == ordinal
        raise Error.new("identity_conflict")
      end
      @protocol.validate!("PolicyHistoryPage", page.fetch("body"))
      first_page_valid =
        ordinal != 1 ||
          (
            page.fetch("previous_sha256").nil? &&
              page.dig("body", "after_policy_revision") == @after
          )
      unless page.dig("body", "connection_id") ==
               @installation.connection_public_id &&
               page.dig("body", "through_policy_revision") == @through &&
               first_page_valid
        raise Error.new("identity_conflict")
      end
    end

    def releases(page)
      %w[authors taxonomy].select do |relation|
        field = relation == "authors" ? "author_ids" : "taxonomy_ids"
        page.fetch("items").any? { |item| item.fetch(field).empty? }
      end
    end

    def plain(value)
      case value
      when Hash
        value.transform_values { |member| plain(member) }
      when Array
        value.map { |member| plain(member) }
      else
        value
      end
    end

    def snapshot(value)
      case value
      when Hash
        value.to_h { |key, member| [key.dup.freeze, snapshot(member)] }.freeze
      when Array
        value.map { |member| snapshot(member) }.freeze
      when String
        value.dup.freeze
      else
        value.freeze
      end
    end

    def page_key(ordinal)
      "#{@key}:#{ordinal.to_s.rjust(16, "0")}"
    end

    def row(kind, key)
      @installation.operational_records.find_by(kind: kind, record_key: key)
    end

    def guard_revision!(key, expected: nil, lock: false, missing: false)
      HistoryGuard.revision!(
        installation_id: @installation.id,
        key: key,
        expected: expected,
        lock: lock,
        missing: missing
      )
    end

    def remember_revision!(revision, ordinal)
      key = "#{@verification_key}:#{Digest::SHA256.hexdigest(revision)}"
      raise Error.new("identity_conflict") if row(REVISION, key)
      create(
        REVISION,
        key,
        {
          "format" => "ghost-policy-history-revision-2",
          "binding" => @context.binding,
          "verification_key" => @verification_key,
          "revision" => revision,
          "ordinal" => ordinal
        }
      )
    end

    def encrypt(kind, key, value)
      @installation.envelope.encrypt(
        "operational_record",
        value,
        binding: JSON.generate([kind, key])
      )
    end

    def create(kind, key, value)
      @installation.operational_records.create!(
        kind: kind,
        record_key: key,
        mapping_public_id: @mapping.fetch("mapping_id"),
        encrypted_payload: encrypt(kind, key, value)
      )
    end
  end
end
