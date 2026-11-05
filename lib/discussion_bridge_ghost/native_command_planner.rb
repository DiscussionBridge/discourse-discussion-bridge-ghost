# frozen_string_literal: true

require_relative "native_executor"
require_relative "native_metadata_selection"
require_relative "source_intake"
require_relative "native_publication"

module DiscussionBridgeGhost
  # Production preparation, not a writer or receiver acknowledgement. Save an
  # exact stage plan BEFORE enrolling its native command. A crash between those
  # two local commits resumes the same ID, nonce, body and baseline. Execution
  # still performs its separate current-authority/native-CAS checks.
  class NativeCommandPlanner
    include ProtectedDiagnostics

    ENTRY = "native_command_plan"
    FIELDS = %w[
      format
      binding
      work
      mapping
      stage
      event_id
      arguments
    ].sort.freeze
    ARGUMENTS = %w[
      command_id
      identity
      owner
      request
      baseline
      candidate
    ].sort.freeze

    def initialize(context:, commands:, authority:, api_key:, factory: nil)
      unless context.is_a?(ExecutionContext) &&
               commands.is_a?(NativeCommandJournal) &&
               commands.context.equal?(context) &&
               authority.is_a?(WorkAuthority) && authority.bound_to?(context)
        raise Error.new("identity_conflict")
      end
      @context, @commands, @authority = context, commands, authority
      @installation, @protocol = context.installation, context.protocol
      @baselines =
        NativeBaselineJournal.new(context: context, journal: commands)
      @intake = SourceIntake.new(context: context)
      @metadata =
        NativeMetadataSelection.new(
          context: context,
          authority: authority,
          api_key: api_key,
          factory: factory
        )
      @client =
        GhostAdminClient.new(
          http:
            GhostHttp.new(
              protocol: @protocol,
              origin: context.binding.fetch("admin_origin"),
              guard: -> { current! },
              api_key: api_key,
              factory: factory
            )
        )
    end

    def prepare_draft(event_id:, kind:, slug:)
      bind!("create_draft")
      unless %w[post page].include?(kind) && slug.is_a?(String) &&
               slug.bytesize.between?(1, 191) &&
               /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.match?(slug) &&
               @mapping.fetch("canonical_url").end_with?("/#{slug}/")
        raise Error.new("configuration_invalid")
      end
      if (prior = retained)
        unless prior.fetch("event_id") == event_id &&
                 prior.dig("arguments", "identity", "kind") == kind &&
                 prior.dig("arguments", "candidate", "slug") == slug
          raise Error.new("identity_conflict")
        end
        return enroll(prior)
      end
      unless @authority.initial_native_id.nil? &&
               @mapping.fetch("destination_native_id").nil? &&
               @baselines.current(@mapping.fetch("mapping_id")).nil?
        raise Error.new("identity_conflict")
      end
      @metadata.selection # Complete descriptive selection first, never clipped.
      @management = @authority.native_management!(stage: @stage)
      @commands.assert_clear!(
        resource_id: @mapping.fetch("resource_id"),
        kind: kind,
        native_id: nil,
        slugs: [slug]
      )
      unless @client.find_by_resource(@mapping.fetch("resource_id")).empty? &&
               @client.find_by_slug(slug).empty?
        raise Error.new("identity_conflict")
      end
      id = SecureRandom.uuid
      fragment =
        OwnedFragment.new(
          resource_id: @mapping.fetch("resource_id"),
          kind: kind,
          native_id: "pending",
          nonce: SecureRandom.hex(32),
          maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES
        )
      publication = publication(event_id, fragment, id)
      fields = {
        "title" => publication.title,
        "slug" => slug,
        "status" => "draft",
        "visibility" => "public",
        "lexical" =>
          OwnedLexical.new(fragment: fragment).create(publication.html),
        "tags" => [{ "name" => resource_tag }]
      }
      enroll(save_plan(event_id, arguments(id, kind, nil, nil, fields, fields)))
    end

    def prepare_publication(event_id:)
      bind!("publish")
      if (prior = retained)
        unless prior.fetch("event_id") == event_id
          raise Error.new("identity_conflict")
        end
        return enroll(prior)
      end
      selected = @metadata.selection
      @management = @authority.native_management!(stage: @stage)
      baseline, native = owned_native
      identity = baseline.value.fetch("identity")
      prior_fragment =
        fragment_for(baseline, baseline.value.dig("fragment", "native_id"))
      fragment = fragment_for(baseline, identity.fetch("native_id"))
      id = SecureRandom.uuid
      publication = publication(event_id, fragment, id)
      fields = {
        "id" => native.fetch("id"),
        "updated_at" => native.fetch("updated_at"),
        "title" => publication.title,
        "slug" => native.fetch("slug"),
        "status" => "published",
        "visibility" => "public",
        "published_at" => publication.publication_date,
        "lexical" =>
          OwnedLexical.new(fragment: fragment).replace(
            current: native,
            html: publication.html,
            expected_revision: native.fetch("updated_at"),
            baseline_sha256: baseline.value.dig("fragment", "sha256"),
            prior_fragment: prior_fragment
          ),
        "tags" => publication_tags(native, selected.fetch("taxonomy"))
      }
      if selected.fetch("authors")
        fields["authors"] = selected
          .fetch("authors")
          .map { |item| { "id" => item.fetch("id") } }
      end
      candidate = native.merge(fields)
      enroll(
        save_plan(
          event_id,
          arguments(
            id,
            identity.fetch("kind"),
            native.fetch("id"),
            native,
            fields,
            candidate
          )
        )
      )
    end

    def prepare_withdrawal
      bind!("withdraw")
      if (prior = retained)
        return enroll(prior)
      end
      @management = @authority.native_management!(stage: @stage)
      baseline, native = owned_native
      fields = {
        "id" => native.fetch("id"),
        "updated_at" => native.fetch("updated_at"),
        "status" => "draft"
      }
      candidate = native.merge(fields)
      enroll(
        save_plan(
          nil,
          arguments(
            SecureRandom.uuid,
            baseline.value.dig("identity", "kind"),
            native.fetch("id"),
            native,
            fields,
            candidate
          )
        )
      )
    end

    private

    def bind!(stage)
      @context.outside_transaction!
      @stage, @management = stage, nil
      @state = current!
      @work, @mapping = @state.values_at("work", "mapping")
      expected = stage == "withdraw" ? "withdraw" : "publish_revision"
      unless @work.fetch("action") == expected
        raise Error.new("work_authority_unavailable")
      end
      @key =
        "#{@work.fetch("work_id")}:#{@work.fetch("lease_generation")}:#{stage}"
    end

    def current!
      @authority.guard!(
        operation: :mutate,
        native_id: @authority.initial_native_id,
        management: @management
      )
    end

    def publication(event_id, fragment, command_id)
      article =
        NativeArticle.new(
          protocol: @protocol,
          forum_origin: @context.binding.fetch("forum_origin"),
          source: @intake.source(event_id),
          html: @intake.content(event_id),
          maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES
        )
      connection = @context.read("V4-01")
      unless connection.status == 200
        raise Error.new("work_authority_unavailable")
      end
      NativePublication.new(
        protocol: @protocol,
        article: article,
        fragment: fragment,
        mapping: @mapping,
        work: @work,
        forum_name: connection.value.fetch("forum_name"),
        command_id: command_id
      )
    end

    def owned_native
      baseline = @baselines.current(@mapping.fetch("mapping_id"))
      raise Error.new("identity_conflict") unless baseline
      identity = baseline.value.fetch("identity")
      same_mapping =
        identity.slice("mapping_id", "resource_id", "external_id") ==
          @mapping.slice("mapping_id", "resource_id", "external_id")
      same_native_id =
        @authority.initial_native_id.nil? ||
          @authority.initial_native_id == identity.fetch("native_id")
      raise Error.new("identity_conflict") unless same_mapping && same_native_id
      @commands.assert_clear!(
        resource_id: @mapping.fetch("resource_id"),
        kind: identity.fetch("kind"),
        native_id: identity.fetch("native_id"),
        slugs: [baseline.value.dig("scalars", "slug")]
      )
      native =
        @client.get(
          identity.fetch("native_id"),
          kind: identity.fetch("kind"),
          maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES
        )
      baseline.assert_current!(
        native,
        management: @management,
        released_relations:
          baseline.released_relations(
            journal: @commands,
            through_generation: @work.fetch("lease_generation")
          )
      )
      matches =
        @client.find_by_resource(
          @mapping.fetch("resource_id"),
          maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES
        )
      unless matches.length == 1 && matches.first == native
        raise Error.new("identity_conflict")
      end
      current!
      [baseline, native]
    end

    def fragment_for(baseline, native_id)
      OwnedFragment.new(
        resource_id: @mapping.fetch("resource_id"),
        kind: baseline.value.dig("identity", "kind"),
        native_id: native_id,
        nonce: baseline.value.dig("fragment", "nonce"),
        maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES
      )
    end

    def resource_tag
      "#discussionbridge-resource-#{@mapping.fetch("resource_id")}"
    end

    def publication_tags(native, selected)
      tags = native.fetch("tags")
      resource = tags.select { |item| item["name"] == resource_tag }
      raise Error.new("identity_conflict") unless resource.length == 1
      editorial =
        selected ||
          tags.reject do |item|
            item["name"] == resource_tag ||
              NativeManagement::INTERNAL_TAGS.include?(item["name"])
          end
      flags =
        [
          "#discussionbridge-source",
          "#discussionbridge-#{@mapping.fetch("presentation_mode")}"
        ].map do |name|
          tags.find { |item| item["name"] == name } || { "name" => name }
        end
      resource + editorial + flags
    end

    def arguments(id, kind, native_id, baseline, fields, candidate)
      {
        "command_id" => id,
        "identity" => {
          "resource_id" => @mapping.fetch("resource_id"),
          "kind" => kind,
          "native_id" => native_id
        },
        "owner" => {
          "direction" => "from_discourse",
          "action" => @stage,
          "mapping_id" => @mapping.fetch("mapping_id"),
          "work_id" => @work.fetch("work_id"),
          "generation" => @work.fetch("lease_generation"),
          "source_revision" => @work.fetch("source_revision"),
          "external_id" => @mapping.fetch("external_id"),
          "move_id" => nil,
          "proof_nonce" => nil
        },
        "request" => {
          "method" => native_id ? "PUT" : "POST",
          "path" =>
            "/ghost/api/admin/#{kind}s/#{native_id ? "#{native_id}/" : ""}",
          "body_bytes" => JSON.generate("#{kind}s" => [fields]),
          "maximum_bytes" => NativeCommandJournal::MAXIMUM_BYTES,
          "allowed_statuses" => native_id ? [200] : [201]
        },
        "baseline" => baseline,
        "candidate" => candidate.merge("management" => @management.value)
      }
    end

    def save_plan(event_id, args)
      current!
      value =
        snapshot(
          "format" => "ghost-native-plan-1",
          "binding" => @context.binding,
          "work" => @work.slice(*WorkAuthority::WORK_FIELDS),
          "mapping" => @mapping.slice(*WorkAuthority::MAPPING_FIELDS),
          "stage" => @stage,
          "event_id" => event_id,
          "arguments" => args
        )
      @context.commit do
        raise Error.new("identity_conflict") if row
        @installation.operational_records.create!(
          kind: ENTRY,
          record_key: @key,
          mapping_public_id: @mapping.fetch("mapping_id"),
          encrypted_payload:
            @installation.envelope.encrypt(
              "operational_record",
              value,
              binding: JSON.generate([ENTRY, @key])
            )
        )
      end
      value
    end

    def row
      @installation.operational_records.find_by(kind: ENTRY, record_key: @key)
    end

    def retained
      saved = row
      return unless saved
      value = snapshot(saved.private_payload)
      unless value.is_a?(Hash) && value.keys.sort == FIELDS &&
               value["format"] == "ghost-native-plan-1" &&
               value["binding"] == @context.binding &&
               value["stage"] == @stage &&
               value["work"] == @work.slice(*WorkAuthority::WORK_FIELDS) &&
               value["mapping"] ==
                 @mapping.slice(*WorkAuthority::MAPPING_FIELDS) &&
               saved.mapping_public_id == @mapping.fetch("mapping_id") &&
               value["arguments"].is_a?(Hash) &&
               value["arguments"].keys.sort == ARGUMENTS
        raise Error.new("identity_conflict")
      end
      @protocol.validate!("UUID", value.dig("arguments", "command_id"))
      value
    end

    def enroll(value)
      @intake.content(value.fetch("event_id")) if value.fetch("event_id")
      prepared =
        @commands.prepare(**value.fetch("arguments").transform_keys(&:to_sym))
      NativeOwnedCommand.new(
        command: prepared,
        expected_mode: @mapping.fetch("presentation_mode")
      ).validate!
      @authority.guard_native!(prepared)
      prepared.fetch("command_id")
    end

    def snapshot(value)
      freeze_value(
        NativeDocument.parse(
          JSON.generate(value),
          maximum_bytes: NativeCommandJournal::MAXIMUM_BYTES
        )
      )
    end

    def freeze_value(value)
      case value
      when Hash
        value.each do |key, member|
          key.freeze
          freeze_value(member)
        end
      when Array
        value.each { |member| freeze_value(member) }
      end
      value.freeze
    end
  end
end
