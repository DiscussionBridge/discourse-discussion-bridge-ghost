# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/discussion_bridge_ghost/native_command_journal"
require_relative "../../lib/discussion_bridge_ghost/native_executor"
require_relative "../../lib/discussion_bridge_ghost/native_ownership_journal"
require_relative "../../lib/discussion_bridge_ghost/native_acknowledgements"

RSpec.describe DiscussionBridgeGhost::WorkAuthority do
  self.use_transactional_tests = false

  # Only synthetic rows in the native CI database. Fixture setup constructs an
  # owned mapping directly; all authority under test uses the real V4 router.
  before do
    freeze_time(Time.utc(2026, 11, 3, 16))
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.discussion_bridge_ghost_enabled = true
    SiteSetting.force_https = true
    SiteSetting.login_required = false
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(
      :wake_connection
    ).and_return(false)
    suffix = SecureRandom.hex(8)
    origin = "https://ghost-authority-#{suffix}.example"
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Ghost work authority #{suffix}",
        platform: "ghost",
        allowed_origins: [origin],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"]
      )
    @connection.update!(
      cms_configuration: {
        "profile" => "ghost",
        "destination_origin" => origin,
        "publication_lane" => "news",
        "native_capabilities" => {
          "native_revision" => "native:synthetic-authority",
          "supported_presentations" => %w[simple full interactive],
          "publication_kind" => "dynamic",
          "complete_content_supported" => true
        },
        "policy" => {
          "policy_revision" => SecureRandom.uuid,
          "enabled" => true,
          "selection" => "all_public",
          "category_ids" => [],
          "include_topic_ids" => [],
          "exclude_topic_ids" => [],
          "include_unlisted" => false,
          "publication_kind" => "dynamic",
          "presentation_mode" => "simple",
          "author_ids" => [],
          "taxonomy_ids" => []
        }
      }
    )
    @target =
      DiscussionBridgeGhost::NativeTarget.create!(
        public_id: SecureRandom.uuid,
        ghost_origin: origin,
        admin_origin: origin
      )
    id = SecureRandom.uuid
    envelope =
      DiscussionBridgeGhost::SecretEnvelope.new(
        application_key: Rails.application.secret_key_base,
        installation_id: id
      )
    @installation =
      DiscussionBridgeGhost::Installation.create!(
        public_id: id,
        native_target: @target,
        enabled: true,
        connection_public_id: @connection.public_id,
        encrypted_configuration:
          envelope.encrypt("configuration", { "secret" => @secret })
      )
    @admin = Fabricate(:admin)
    @topic = Fabricate(:topic, user: @admin)
    @source_post =
      Fabricate(
        :post,
        topic: @topic,
        user: @admin,
        post_number: 1,
        raw: "Synthetic native authority source.",
        cooked: "<p>Synthetic native authority source.</p>"
      )
    @record =
      DiscussionBridgeBridgeRecord.create!(
        resource_id: SecureRandom.uuid,
        direction: "from_discourse",
        lane: "news",
        state: "healthy",
        title: @topic.title,
        topic: @topic,
        effective_actor: @admin
      )
    @binding =
      DiscussionBridgeContentBinding.create!(
        bridge_record: @record,
        content_connection: @connection,
        role: "presentation",
        state: "active",
        external_id: "article",
        canonical_url: "#{origin}/article/",
        identity_digest: SecureRandom.hex(32),
        canonical_url_digest: SecureRandom.hex(32),
        presentation_mode: "simple"
      )
    @mapping =
      DiscussionBridgeCmsMapping.create!(
        content_connection: @connection,
        content_binding: @binding,
        source_id: "topic:#{@topic.id}",
        mapping_id: SecureRandom.uuid,
        mapping_revision: SecureRandom.uuid
      )
    @snapshot =
      DiscussionBridge::CmsSourceStore
        .new(@connection)
        .capture_snapshot(@topic)
        .metadata
    @work =
      DiscussionBridge::CmsWorkCoordinator.new(@connection).enqueue!(
        @mapping,
        source_snapshot: @snapshot
      )
  end

  after do
    if @installation&.persisted?
      DiscussionBridgeGhost::OperationalRecord.where(
        installation_id: @installation.id
      ).delete_all
      DiscussionBridgeGhost::Mutation.where(
        installation_id: @installation.id
      ).delete_all
      @installation.delete
    end
    @target.delete if @target&.persisted?
    if @connection&.persisted?
      streams =
        DiscussionBridgeCmsSourceStream.where(
          content_connection_id: @connection.id
        )
      intents =
        DiscussionBridgeCmsSourceIntent.where(
          cms_source_stream_id: streams.select(:id)
        )
      cursors =
        DiscussionBridgeCmsSourceCursor.where(
          cms_source_stream_id: streams.select(:id)
        )
      DiscussionBridgeCmsSourceSnapshotItem.where(
        snapshot_root_id: cursors.select(:id)
      ).delete_all
      cursors.delete_all
      DiscussionBridgeCmsSourceRevision.where(
        cms_source_intent_id: intents.select(:id)
      ).delete_all
      intents.update_all(publication_event_id: nil)
      DiscussionBridgeCmsSourceEvent.where(
        cms_source_stream_id: streams.select(:id)
      ).delete_all
      intents.delete_all
      streams.delete_all
      uploads =
        DiscussionBridgeCmsCatalogUpload.where(
          content_connection_id: @connection.id
        )
      snapshots =
        DiscussionBridgeCmsCatalogSnapshot.where(
          content_connection_id: @connection.id
        )
      DiscussionBridgeCmsCatalogCursor.where(
        catalog_snapshot_id: snapshots.select(:id)
      ).delete_all
      snapshots.delete_all
      DiscussionBridgeCmsCatalogEntry.where(
        catalog_upload_id: uploads.select(:id)
      ).delete_all
      DiscussionBridgeCmsCatalogPage.where(
        catalog_upload_id: uploads.select(:id)
      ).delete_all
      uploads.delete_all
      DiscussionBridgeCmsMutationReceipt.where(
        content_connection_id: @connection.id
      ).delete_all
      if @mapping&.persisted?
        DiscussionBridgeCmsWork.where(cms_mapping_id: @mapping.id).delete_all
      end
      @mapping.delete if @mapping&.persisted?
      @binding.delete if @binding&.persisted?
      @record.delete if @record&.persisted?
      @connection.delete
    end
  end

  def with_runtime(app: Rails.application)
    @installation.reload
    DiscussionBridgeGhost::NativeLock.synchronize(@target.public_id) do |lock|
      protocol = DiscussionBridgeGhost::WireProtocol.new
      transport =
        DiscussionBridgeGhost::RackTransport.new(
          protocol: protocol,
          connection_id: @connection.public_id,
          connection_secret: @secret,
          app: app
        )
      context =
        DiscussionBridgeGhost::ExecutionContext.new(
          installation: @installation,
          protocol: protocol,
          transport: transport,
          lease: lock
        )
      journal =
        DiscussionBridgeGhost::MutationJournal.new(
          installation: @installation,
          protocol: protocol,
          transport: transport,
          lease: lock,
          context: context
        )
      yield context, journal
    end
  end

  def claim(context, journal, key: "claim:fixture")
    result =
      journal.call(key, "V4-13") do
        {
          "mutation_id" => SecureRandom.uuid,
          "mapping_id" => @mapping.mapping_id
        }
      end
    expect(result.status).to eq(200)
    result.value
  end

  def authority(context, journal, lease)
    descriptor = context.read("V4-01")
    expect(descriptor.status).to eq(200)
    mapping =
      context.read("V4-11", path: { "mapping_id" => @mapping.mapping_id })
    expect(mapping.status).to eq(200)
    described_class.new(
      context: context,
      journal: journal,
      lease: lease,
      mapping: mapping.value,
      scope_revision: descriptor.value.fetch("scope_revision")
    )
  end

  def state
    @installation
      .operational_records
      .find_by!(kind: "work_authority")
      .private_payload
  end

  def rewrite_record(row, payload)
    row.update!(
      encrypted_payload:
        @installation.envelope.encrypt(
          "operational_record",
          payload,
          binding: JSON.generate([row.kind, row.record_key])
        )
    )
  end

  def retained_evidence
    [
      @installation
        .operational_records
        .order(:id)
        .pluck(:id, :kind, :record_key, :mapping_public_id, :encrypted_payload),
      @installation
        .mutations
        .order(:id)
        .pluck(
          :id,
          :operation_key,
          :request_ciphertext,
          :response_ciphertext,
          :state
        )
    ]
  end

  def next_work!
    @work.update!(
      state: "cancelled",
      lease_verifier: nil,
      lease_expires_at: nil
    )
    @mapping.work_items.create!(
      work_id: SecureRandom.uuid,
      attempt_cycle: SecureRandom.uuid,
      action: "publish_revision",
      source_revision: @work.source_revision,
      policy_revision: @work.policy_revision,
      source_snapshot: @snapshot
    )
  end

  def observed_app(requests, &after_response)
    lambda do |env|
      if env.fetch("PATH_INFO").end_with?("/renew.json")
        requests << env.fetch("rack.input").read
        env.fetch("rack.input").rewind
        result = Rails.application.call(env)
        after_response ? after_response.call(result) : result
      else
        Rails.application.call(env)
      end
    end
  end

  def owned_execution_html(fragment, command_id)
    attributes =
      fragment.attributes.merge(
        "data-discussionbridge-source-revision" =>
          @work.source_revision || "prior-source-revision",
        "data-discussionbridge-mode" => "simple"
      )
    section =
      "<section #{attributes.map { |key, value| "#{key}=\"#{CGI.escapeHTML(value)}\"" }.join(" ")}><p>Native execution body.</p></section>"
    fragment.stamp_command(fragment.wrap(section), command_id: command_id)
  end

  def seed_native_binding!(withdraw: false)
    with_runtime do |context, mutations|
      authority(context, mutations, claim(context, mutations)).guard!(
        operation: :mutate
      )
    end
    @mapping.update!(destination_native_id: "a" * 24)
    if withdraw
      @work.update!(state: "cancelled")
      config = @connection.cms_configuration.deep_dup
      config.fetch("policy")["exclude_topic_ids"] = [@topic.id.to_s]
      @connection.update_columns(cms_configuration: config)
      @work =
        DiscussionBridge::CmsWorkCoordinator.new(@connection).enqueue!(
          @mapping,
          source_snapshot: nil,
          action: "withdraw"
        )
    else
      @work = next_work!
    end
  end

  def native_arguments(
    context,
    lease,
    native_id: "a" * 24,
    kind: "post",
    create: false
  )
    id = SecureRandom.uuid
    fragment =
      DiscussionBridgeGhost::OwnedFragment.new(
        resource_id: @record.resource_id,
        kind: kind,
        native_id: native_id || "pending",
        nonce: "ab" * 32,
        maximum_bytes: 262_144
      )
    old_html = owned_execution_html(fragment, SecureRandom.uuid)
    baseline =
      (
        if create
          nil
        else
          {
            "id" => native_id,
            "type" => kind,
            "html" => old_html,
            "lexical" =>
              DiscussionBridgeGhost::OwnedLexical.new(
                fragment: fragment
              ).create(old_html),
            "title" => "Owned native fixture",
            "slug" => "article",
            "status" => "published",
            "updated_at" => "2026-11-03T16:00:00.000Z",
            "tags" => [
              {
                "id" => "c" * 24,
                "name" => "#discussionbridge-resource-#{@record.resource_id}"
              }
            ]
          }
        end
      )
    html = owned_execution_html(fragment, id)
    lexical =
      if create
        DiscussionBridgeGhost::OwnedLexical.new(fragment: fragment).create(html)
      else
        DiscussionBridgeGhost::OwnedLexical.new(fragment: fragment).replace(
          current: baseline,
          html: html,
          expected_revision: baseline.fetch("updated_at"),
          baseline_sha256: fragment.extract(old_html).sha256
        )
      end
    action =
      (
        if create
          "create_draft"
        else
          (@work.action == "withdraw" ? "withdraw" : "publish")
        end
      )
    fields = {
      "title" => "Owned native fixture",
      "slug" => "article",
      "status" => action == "publish" ? "published" : "draft",
      "lexical" => lexical
    }
    if action == "withdraw"
      fields = { "status" => "draft" }
      html = baseline.fetch("html")
    end
    if create
      fields["tags"] = [
        { "name" => "#discussionbridge-resource-#{@record.resource_id}" }
      ]
    else
      fields.merge!(
        "id" => native_id,
        "updated_at" => baseline.fetch("updated_at")
      )
    end
    [
      {
        command_id: id,
        identity: {
          "resource_id" => @record.resource_id,
          "kind" => kind,
          "native_id" => native_id
        },
        owner: {
          "direction" => "from_discourse",
          "action" => action,
          "mapping_id" => @mapping.mapping_id,
          "work_id" => @work.work_id,
          "generation" => lease.fetch("lease_generation"),
          "source_revision" => @work.source_revision,
          "external_id" => @binding.external_id,
          "move_id" => nil,
          "proof_nonce" => nil
        },
        request: {
          "method" => create ? "POST" : "PUT",
          "path" =>
            "/ghost/api/admin/#{kind}s/#{create ? "" : "#{native_id}/"}",
          "body_bytes" => JSON.generate("#{kind}s" => [fields]),
          "maximum_bytes" => 262_144,
          "allowed_statuses" => create ? [201] : [200]
        },
        baseline: baseline,
        candidate:
          (
            if action == "withdraw"
              fields.merge("slug" => baseline.fetch("slug"))
            else
              fields
            end
          )
      },
      html
    ]
  end

  %w[
    wrong-native
    replacement-create
    missing-native
    wrong-kind
  ].each do |scenario|
    it "rejects #{scenario} before native writes on an existing receiver binding" do
      seed_native_binding!
      with_runtime do |context, mutations|
        lease = claim(context, mutations, key: "claim:#{scenario}")
        held = authority(context, mutations, lease)
        create = scenario == "replacement-create"
        id = create ? nil : (scenario == "wrong-native" ? "b" * 24 : "a" * 24)
        kind = scenario == "wrong-kind" ? "page" : "post"
        args, _html =
          native_arguments(
            context,
            lease,
            native_id: id,
            kind: kind,
            create: create
          )
        native_journal =
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
        native_journal.prepare(**args)
        if %w[missing-native wrong-kind].include?(scenario)
          stub_request(
            :get,
            %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/#{kind}s/#{id}/}
          ).to_return(
            status: 404,
            headers: {
              "Content-Type" => "application/json"
            },
            body: '{"errors":[]}'
          )
        end
        executor =
          DiscussionBridgeGhost::NativeExecutor.new(
            context: context,
            journal: native_journal,
            authority: held,
            api_key: "a" * 24 + ":" + "12" * 32
          )
        expect { executor.execute(args.fetch(:command_id)) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        expect(@mapping.reload.destination_native_id).to eq("a" * 24)
        expect(
          native_journal.retained(args.fetch(:command_id)).dig(
            "state",
            "pending_attempt"
          )
        ).to eq(nil)
      end
      expect(
        a_request(
          :post,
          %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/}
        )
      ).not_to have_been_made
      expect(
        a_request(
          :put,
          %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/}
        )
      ).not_to have_been_made
    end
  end

  %w[
    unique-post
    unique-page
    withdraw
    duplicate-resource
    lost-resource
    slug-conflict
  ].each do |scenario|
    it "enforces current preflight for #{scenario} under actual bound V4 work" do
      seed_native_binding!(withdraw: scenario == "withdraw")
      with_runtime do |context, mutations|
        lease = claim(context, mutations, key: "claim:preflight:#{scenario}")
        held = authority(context, mutations, lease)
        kind = scenario == "unique-page" ? "page" : "post"
        args, html = native_arguments(context, lease, kind: kind)
        native_journal =
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
        native_journal.prepare(**args)
        native = args.fetch(:baseline)
        origin = @target.admin_origin
        stub_request(
          :get,
          %r{#{Regexp.escape(origin)}/ghost/api/admin/#{kind}s/#{native.fetch("id")}/}
        ).to_return do
          {
            status: 200,
            headers: {
              "Content-Type" => "application/json"
            },
            body: JSON.generate("#{kind}s" => [native])
          }
        end
        %w[post page].each do |queried|
          stub_request(
            :get,
            %r{#{Regexp.escape(origin)}/ghost/api/admin/#{queried}s/\?filter=}
          ).to_return do
            values = queried == kind ? [native] : []
            values = [] if scenario == "lost-resource"
            values = [
              native.merge("id" => "b" * 24, "type" => queried)
            ] if scenario == "duplicate-resource" && queried != kind
            {
              status: 200,
              headers: {
                "Content-Type" => "application/json"
              },
              body: JSON.generate("#{queried}s" => values)
            }
          end
          stub_request(
            :get,
            %r{#{Regexp.escape(origin)}/ghost/api/admin/#{queried}s/\?filter=slug}
          ).to_return do
            values = queried == kind ? [native] : []
            values = [
              native.merge("id" => "b" * 24, "type" => queried)
            ] if scenario == "slug-conflict" && queried != kind
            {
              status: 200,
              headers: {
                "Content-Type" => "application/json"
              },
              body: JSON.generate("#{queried}s" => values)
            }
          end
        end
        update =
          stub_request(:put, origin + args.dig(:request, "path")).to_return do
            native =
              native.merge(args.fetch(:candidate)).merge(
                "html" => html,
                "updated_at" => "2026-11-03T16:00:01.000Z"
              )
            {
              status: 200,
              headers: {
                "Content-Type" => "application/json"
              },
              body: JSON.generate("#{kind}s" => [native])
            }
          end
        executor =
          DiscussionBridgeGhost::NativeExecutor.new(
            context: context,
            journal: native_journal,
            authority: held,
            api_key: "a" * 24 + ":" + "12" * 32
          )
        if %w[unique-post unique-page withdraw].include?(scenario)
          expect(
            executor.execute(args.fetch(:command_id)).dig("native", "id")
          ).to eq("a" * 24)
          expect(update).to have_been_requested.once
        else
          expect { executor.execute(args.fetch(:command_id)) }.to raise_error(
            DiscussionBridgeGhost::Error
          )
          expect(update).not_to have_been_requested
          expect(
            native_journal.retained(args.fetch(:command_id)).dig(
              "state",
              "pending_attempt"
            )
          ).to eq(nil)
        end
        expect(@mapping.reload.destination_native_id).to eq("a" * 24)
        expect(@work.reload.state).to eq("leased")
      end
    end
  end

  it "executes durable pending-draft and real-ID publish bytes under actual V4 authority without acknowledging receiver work" do
    with_runtime do |context, mutations|
      lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      native_journal =
        DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
      command_id = SecureRandom.uuid
      fragment =
        DiscussionBridgeGhost::OwnedFragment.new(
          resource_id: @record.resource_id,
          kind: "post",
          native_id: "pending",
          nonce: "ab" * 32,
          maximum_bytes: 262_144
        )
      html = owned_execution_html(fragment, command_id)
      fields = {
        "title" => "Native execution fixture",
        "slug" => "article",
        "status" => "draft",
        "lexical" =>
          DiscussionBridgeGhost::OwnedLexical.new(fragment: fragment).create(
            html
          ),
        "tags" => [
          { "name" => "#discussionbridge-resource-#{@record.resource_id}" }
        ]
      }
      exact = " #{JSON.generate("posts" => [fields])}\n"
      native_journal.prepare(
        command_id: command_id,
        identity: {
          "resource_id" => @record.resource_id,
          "kind" => "post",
          "native_id" => nil
        },
        owner: {
          "direction" => "from_discourse",
          "action" => "create_draft",
          "mapping_id" => @mapping.mapping_id,
          "work_id" => @work.work_id,
          "generation" => lease.fetch("lease_generation"),
          "source_revision" => @work.source_revision,
          "external_id" => @binding.external_id,
          "move_id" => nil,
          "proof_nonce" => nil
        },
        request: {
          "method" => "POST",
          "path" => "/ghost/api/admin/posts/",
          "body_bytes" => exact,
          "maximum_bytes" => 262_144,
          "allowed_statuses" => [201]
        },
        baseline: nil,
        candidate: fields
      )
      native =
        fields.merge(
          "id" => "a" * 24,
          "type" => "post",
          "updated_at" => "2026-11-03T16:00:00.000Z",
          "html" => html
        )
      origin = @target.admin_origin
      created = false
      post =
        stub_request(:post, origin + "/ghost/api/admin/posts/")
          .with(body: exact)
          .to_return do
            created = true
            {
              status: 201,
              headers: {
                "Content-Type" => "application/json"
              },
              body: JSON.generate("posts" => [native])
            }
          end
      stub_request(
        :get,
        %r{#{Regexp.escape(origin)}/ghost/api/admin/posts/#{native.fetch("id")}/}
      ).to_return do
        {
          status: 200,
          headers: {
            "Content-Type" => "application/json"
          },
          body: JSON.generate("posts" => [native])
        }
      end
      %w[post page].each do |kind|
        stub_request(
          :get,
          %r{#{Regexp.escape(origin)}/ghost/api/admin/#{kind}s/\?filter=}
        ).to_return do
          {
            status: 200,
            headers: {
              "Content-Type" => "application/json"
            },
            body:
              JSON.generate(
                "#{kind}s" => (kind == "post" && created ? [native] : [])
              )
          }
        end
        stub_request(
          :get,
          %r{#{Regexp.escape(origin)}/ghost/api/admin/#{kind}s/\?filter=slug}
        ).to_return do
          {
            status: 200,
            headers: {
              "Content-Type" => "application/json"
            },
            body:
              JSON.generate(
                "#{kind}s" => (kind == "post" && created ? [native] : [])
              )
          }
        end
      end
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: native_journal,
          authority: held,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      completion = executor.execute(command_id)
      expect(completion.dig("native", "status")).to eq("draft")
      expect(executor.execute(command_id)).to eq(completion)
      original = native_journal.retained(command_id).fetch("command")
      publish_id = SecureRandom.uuid
      real_fragment =
        DiscussionBridgeGhost::OwnedFragment.new(
          resource_id: @record.resource_id,
          kind: "post",
          native_id: native.fetch("id"),
          nonce: fragment.nonce,
          maximum_bytes: 262_144
        )
      published_html = owned_execution_html(real_fragment, publish_id)
      published_lexical =
        DiscussionBridgeGhost::OwnedLexical.new(
          fragment: real_fragment
        ).replace(
          current: native,
          html: published_html,
          expected_revision: native.fetch("updated_at"),
          baseline_sha256: fragment.extract(html).sha256,
          prior_fragment: fragment
        )
      update_fields = {
        "id" => native.fetch("id"),
        "updated_at" => native.fetch("updated_at"),
        "slug" => "article",
        "status" => "published",
        "lexical" => published_lexical
      }
      native_journal.prepare(
        command_id: publish_id,
        identity:
          original.fetch("identity").merge("native_id" => native.fetch("id")),
        owner: original.fetch("owner").merge("action" => "publish"),
        request: {
          "method" => "PUT",
          "path" => "/ghost/api/admin/posts/#{native.fetch("id")}/",
          "body_bytes" => JSON.generate("posts" => [update_fields]),
          "maximum_bytes" => 262_144,
          "allowed_statuses" => [200]
        },
        baseline: native,
        candidate: update_fields
      )
      update =
        stub_request(
          :put,
          origin + "/ghost/api/admin/posts/#{native.fetch("id")}/"
        ).to_return do
          native =
            native.merge(update_fields).merge(
              "updated_at" => "2026-11-03T16:00:01.000Z",
              "html" => published_html
            )
          {
            status: 200,
            headers: {
              "Content-Type" => "application/json"
            },
            body: JSON.generate("posts" => [native])
          }
        end
      expect(executor.execute(publish_id).dig("native", "status")).to eq(
        "published"
      )
      expect(
        native_journal.retained(command_id).dig(
          "command",
          "identity",
          "native_id"
        )
      ).to eq(nil)
      expect(update).to have_been_requested.once
      expect(post).to have_been_requested.once
      expect(@work.reload.state).to eq("leased")
      expect(@mapping.reload.destination_native_id).to eq(nil)
      expect(state.fetch("next_renewal")).to be >= 3
    end
  end

  it "checks private stage-management intent against actual current policy without changing the retained command or sending it as native data" do
    with_runtime do |context, mutations|
      lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      native_journal =
        DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
      args, = native_arguments(context, lease, native_id: nil, create: true)
      fields = args.fetch(:candidate).merge("visibility" => "public")
      management =
        DiscussionBridgeGhost::NativeManagement.for_policy(
          protocol: context.protocol,
          policy: @connection.reload.cms_configuration.fetch("policy"),
          stage: "create_draft"
        )
      args[:candidate] = fields.merge("management" => management.value)
      args[:request]["body_bytes"] = JSON.generate("posts" => [fields])
      command = native_journal.prepare(**args)
      before = native_journal.retained(args.fetch(:command_id))
      held.guard_native!(command)
      expect(native_journal.retained(args.fetch(:command_id))).to eq(before)
      expect(
        JSON.parse(command.dig("request", "body_bytes")).fetch("posts").first
      ).not_to have_key("management")
      altered = JSON.parse(JSON.generate(command))
      altered.fetch("candidate").fetch("management")[
        "policy_revision"
      ] = SecureRandom.uuid
      expect { held.guard_native!(altered) }.to raise_error(
        DiscussionBridgeGhost::Error
      ) { |error| expect(error.code).to eq("work_authority_unavailable") }
      expect(native_journal.retained(args.fetch(:command_id))).to eq(before)
      expect(@mapping.reload.destination_native_id).to eq(nil)
      expect(@work.reload.state).to eq("leased")
    end
    expect(a_request(:any, /ghost-authority-/)).not_to have_been_made
  end

  def managed_publish_arguments(context, lease, native)
    args, = native_arguments(context, lease)
    prior_section =
      Nokogiri::HTML5.fragment(
        native.fetch("html"),
        **DiscussionBridgeGhost::OwnedFragment::OPTIONS
      ).at_css("section[data-discussionbridge-owned]")
    fragment =
      DiscussionBridgeGhost::OwnedFragment.new(
        resource_id: @record.resource_id,
        kind: "post",
        native_id: native.fetch("id"),
        nonce: "ab" * 32,
        maximum_bytes: 262_144
      )
    prior_fragment =
      DiscussionBridgeGhost::OwnedFragment.new(
        resource_id: @record.resource_id,
        kind: "post",
        native_id: prior_section["data-discussionbridge-native-id"],
        nonce: "ab" * 32,
        maximum_bytes: 262_144
      )
    html = owned_execution_html(fragment, args.fetch(:command_id))
    fields =
      args.fetch(:candidate).merge(
        "visibility" => "public",
        "published_at" => "2026-11-03T15:00:00.000Z",
        "updated_at" => native.fetch("updated_at"),
        "lexical" =>
          DiscussionBridgeGhost::OwnedLexical.new(fragment: fragment).replace(
            current: native,
            html: html,
            expected_revision: native.fetch("updated_at"),
            baseline_sha256:
              prior_fragment.extract(native.fetch("html")).sha256,
            prior_fragment: prior_fragment
          )
      )
    management =
      DiscussionBridgeGhost::NativeManagement.for_policy(
        protocol: context.protocol,
        policy: @connection.reload.cms_configuration.fetch("policy"),
        stage: "publish"
      )
    fields["tags"] = native.fetch("tags")
    selected_authors = management.value.fetch("author_ids")
    if selected_authors
      fields["authors"] = selected_authors.map { |id| { "id" => id } }
    end
    selected_taxonomy = management.value.fetch("taxonomy_ids")
    if selected_taxonomy
      fields["tags"] = selected_taxonomy.map do |id|
        { "id" => id, "name" => "Selected #{id}" }
      end +
        native
          .fetch("tags")
          .select { |tag| tag.fetch("name").start_with?("#discussionbridge-") }
    end
    args[:baseline] = native
    args[:candidate] = native.merge(fields).merge(
      "management" => management.value
    )
    args[:request]["body_bytes"] = JSON.generate("posts" => [fields])
    args
  end

  it "obtains field releases from actual current V4 policy and rejects stale or wrong-stage descriptors" do
    # Real selected-catalog availability is a prerequisite for the real receiver
    # to lease this work. These are native synthetic catalog fixtures, not a
    # claim that Ghost catalogs were fetched or that the connector is installed.
    store =
      DiscussionBridge::CmsCatalogStore.new(
        @connection,
        authenticated_secret_digest: @connection.secret_digest
      )
    { "authors" => "1" * 24, "taxonomy" => "3" * 24 }.each do |kind, id|
      upload =
        store.begin_upload(
          {
            "mutation_id" => SecureRandom.uuid,
            "kind" => kind,
            "native_revision" => "native:field-control",
            "total_items" => 1
          }
        ).body
      upload_id = upload.fetch("upload_id")
      store.append_page(
        upload_id,
        {
          "mutation_id" => SecureRandom.uuid,
          "page" => 0,
          "items" => [
            { "id" => id, "label" => "Synthetic #{kind}", "available" => true }
          ]
        }
      )
      store.finalize(
        upload_id,
        {
          "mutation_id" => SecureRandom.uuid,
          "upload_id" => upload_id,
          "expected_total_items" => 1
        }
      )
    end
    config = @connection.cms_configuration.deep_dup
    config.fetch("policy")["author_ids"] = ["1" * 24]
    @connection.update_columns(cms_configuration: config)
    with_runtime do |context, mutations|
      held = authority(context, mutations, claim(context, mutations))
      current = held.native_management!(stage: "publish")
      expect(current.released_relations).to eq(["taxonomy"])
      expect(current.value.fetch("author_ids")).to eq(["1" * 24])
      expect { held.native_management!(stage: "withdraw") }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      # A real policy/scope change invalidates the old authority. It must not
      # manufacture a fresh descriptor under the earlier leased work either.
      config.fetch("policy")["author_ids"] = []
      config.fetch("policy")["taxonomy_ids"] = ["3" * 24]
      config.fetch("policy")["policy_revision"] = SecureRandom.uuid
      @connection.update_columns(cms_configuration: config)
      expect {
        held.guard!(operation: :mutate, management: current)
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect { held.native_management!(stage: "publish") }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(current.value.fetch("author_ids")).to eq(["1" * 24])
      # The receiver's actual intent path supersedes old work and creates a new
      # policy-bound lease; the test does not rebase the old checkpoint.
      @work =
        DiscussionBridge::CmsWorkCoordinator.new(@connection).enqueue!(
          @mapping,
          source_snapshot: @snapshot
        )
    end
    with_runtime do |context, mutations|
      lease = claim(context, mutations, key: "claim:field-release-policy")
      released =
        authority(context, mutations, lease).native_management!(
          stage: "publish"
        )
      expect(released.released_relations).to eq(["authors"])
      expect(released.value.fetch("taxonomy_ids")).to eq(["3" * 24])
    end
    expect(a_request(:any, /ghost-authority-/)).not_to have_been_made
  end

  it "executes a managed publish under real V4 authority, advances its head, and reaches the prewrite safeguard before rejecting an edited update" do
    kept_key = kept_receipt = nil
    with_runtime do |context, mutations|
      lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      native_journal =
        DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
      args, html =
        native_arguments(context, lease, native_id: nil, create: true)
      fields = args.fetch(:candidate).merge("visibility" => "public")
      management =
        DiscussionBridgeGhost::NativeManagement.for_policy(
          protocol: context.protocol,
          policy: @connection.reload.cms_configuration.fetch("policy"),
          stage: "create_draft"
        )
      args[:candidate] = fields.merge("management" => management.value)
      args[:request]["body_bytes"] = JSON.generate("posts" => [fields])
      native =
        fields.merge(
          "id" => "a" * 24,
          "type" => "post",
          "html" => html,
          "authors" => [{ "id" => "b" * 24 }],
          "tags" =>
            fields.fetch("tags").map { |tag| tag.merge("id" => "c" * 24) },
          "updated_at" => "2026-11-03T16:01:00.000Z"
        )
      created = false
      %w[post page].each do |kind|
        stub_request(
          :get,
          %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/#{kind}s/\?filter=}
        ).to_return do
          {
            status: 200,
            headers: {
              "Content-Type" => "application/json"
            },
            body:
              JSON.generate(
                "#{kind}s" => (created && kind == "post" ? [native] : [])
              )
          }
        end
      end
      stub_request(
        :post,
        @target.admin_origin + args.dig(:request, "path")
      ).to_return do
        created = true
        {
          status: 201,
          headers: {
            "Content-Type" => "application/json"
          },
          body: JSON.generate("posts" => [native])
        }
      end
      stub_request(
        :get,
        %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/#{native.fetch("id")}/}
      ).to_return do
        {
          status: 200,
          headers: {
            "Content-Type" => "application/json"
          },
          body: JSON.generate("posts" => [native])
        }
      end
      native_journal.prepare(**args)
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: native_journal,
          authority: held,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      completed = executor.execute(args.fetch(:command_id))
      expect(completed.fetch("native_id")).to eq(native.fetch("id"))
      saved =
        DiscussionBridgeGhost::NativeBaselineJournal.new(
          context: context,
          journal: native_journal
        )
      expect(saved.current(@mapping.mapping_id).assert_current!(native)).to eq(
        true
      )
      expect(executor.execute(args.fetch(:command_id))).to eq(completed)
      expect(@mapping.reload.destination_native_id).to eq(nil)
      expect(@work.reload.state).to eq("leased")

      original_completion = native_journal.retained(args.fetch(:command_id))
      ownership =
        DiscussionBridgeGhost::NativeOwnershipJournal.new(
          context: context,
          commands: native_journal,
          authority: held,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      expect { ownership.capture }.to raise_error(DiscussionBridgeGhost::Error)
      expect(
        @installation.operational_records.where(
          kind: "native_ownership_receipt"
        )
      ).not_to exist
      draft_head = saved.current(@mapping.mapping_id)
      original_entry =
        @installation
          .operational_records
          .find_by!(
            kind: "native_managed_baseline",
            record_key: args.fetch(:command_id)
          )
          .encrypted_payload
      publication = managed_publish_arguments(context, lease, native)
      stub_request(
        :put,
        @target.admin_origin + publication.dig(:request, "path")
      ).to_return do |request|
        applied = JSON.parse(request.body).fetch("posts").fetch(0)
        rendered =
          JSON
            .parse(applied.fetch("lexical"))
            .fetch("root")
            .fetch("children")
            .filter_map { |node| node["html"] }
            .join
        native =
          native.merge(applied).merge(
            "html" => rendered,
            "updated_at" => "2026-11-03T16:02:00.000Z"
          )
        {
          status: 200,
          headers: {
            "Content-Type" => "application/json"
          },
          body: JSON.generate("posts" => [native])
        }
      end
      reached = []
      safeguard =
        TracePoint.new(:call) do |event|
          if event.self.is_a?(DiscussionBridgeGhost::NativeBaselineJournal) &&
               event.method_id == :assert_before_write!
            reached << event
              .binding
              .local_variable_get(:command)
              .fetch("command_id")
          end
        end
      native_journal.prepare(**publication)
      published = nil
      safeguard.enable do
        published = executor.execute(publication.fetch(:command_id))
      end
      expect(reached).to eq([publication.fetch(:command_id)])
      expect(published.fetch("native_id")).to eq(native.fetch("id"))
      expect(native.fetch("status")).to eq("published")
      head = saved.current(@mapping.mapping_id)
      expect(head.value.fetch("command_id")).to eq(
        publication.fetch(:command_id)
      )
      expect(head.value.fetch("previous_sha256")).to eq(draft_head.sha256)
      expect(head.value.dig("fragment", "native_id")).to eq(native.fetch("id"))
      expect(head.sha256).not_to eq(draft_head.sha256)
      expect(head.assert_current!(native)).to eq(true)
      expect(native_journal.retained(args.fetch(:command_id))).to eq(
        original_completion
      )
      expect(
        @installation
          .operational_records
          .find_by!(
            kind: "native_managed_baseline",
            record_key: args.fetch(:command_id)
          )
          .encrypted_payload
      ).to eq(original_entry)
      expect(executor.execute(publication.fetch(:command_id))).to eq(published)
      expect(@mapping.reload.destination_native_id).to eq(nil)
      expect(@work.reload.state).to eq("leased")

      # A real current lease + completed managed publication + fresh Ghost
      # reads can create the durable LOCAL receipt before the receiver binding
      # is set. This is ownership evidence, not a synchronized/verified ACK.
      observed = ownership.capture
      kept_key, kept_receipt = observed.key, observed.receipt.sha256
      expect(observed.receipt.value).to include(
        "mapping_id" => @mapping.mapping_id,
        "native_id" => native.fetch("id"),
        "resource_id" => @record.resource_id,
        "last_lease_generation" => lease.fetch("lease_generation")
      )
      expect(observed.value.fetch("baseline_sha256")).to eq(head.sha256)
      expect(ownership.retained(observed.key).receipt.sha256).to eq(
        observed.receipt.sha256
      )
      receipt_row =
        @installation.operational_records.find_by!(
          kind: "native_ownership_receipt"
        )
      original_receipt_bytes = receipt_row.encrypted_payload
      expect(ownership.capture.key).to eq(observed.key)
      expect(ownership.latest(@mapping.mapping_id).key).to eq(observed.key)
      expect(receipt_row.reload.encrypted_payload).to eq(original_receipt_bytes)
      expect(
        @installation
          .operational_records
          .where(kind: "native_ownership_receipt")
          .count
      ).to eq(1)
      expect(@mapping.reload.destination_native_id).to eq(nil)
      expect(@work.reload.state).to eq("leased")
      # Reading a missing/foreign record never imports a manufactured hash.
      expect { ownership.retained("0" * 64) }.to raise_error(
        DiscussionBridgeGhost::Error
      )

      # Both fields are explicitly Ghost-controlled under this actual current
      # empty policy. A new observation preserves their edits and the original
      # immutable physical baseline/receipt; it is still not a policy ACK.
      original_baseline_bytes = JSON.generate(head.value)
      native =
        native.merge(
          "authors" => [{ "id" => "d" * 24 }],
          "tags" =>
            native.fetch("tags") +
              [{ "id" => "e" * 24, "name" => "Ghost editorial tag" }],
          "updated_at" => "2026-11-03T16:02:30.000Z"
        )
      after_edit = ownership.capture
      expect(after_edit.key).not_to eq(observed.key)
      expect(after_edit.value.dig("management", "policy_author_ids")).to eq([])
      expect(after_edit.value.dig("management", "policy_taxonomy_ids")).to eq(
        []
      )
      expect(after_edit.value.fetch("baseline_sha256")).to eq(head.sha256)
      expect(JSON.generate(saved.current(@mapping.mapping_id).value)).to eq(
        original_baseline_bytes
      )
      expect(receipt_row.reload.encrypted_payload).to eq(original_receipt_bytes)
      kept_key, kept_receipt = after_edit.key, after_edit.receipt.sha256

      # Ghost has been edited before the next command was prepared. Even its
      # fresh CAS baseline already contains that change; it must not be blessed.
      native =
        native.merge(
          "title" => "An editor changed the managed title",
          "updated_at" => "2026-11-03T16:03:00.000Z"
        )
      expect { ownership.capture }.to raise_error(DiscussionBridgeGhost::Error)
      expect(ownership.retained(observed.key).receipt.sha256).to eq(
        observed.receipt.sha256
      )
      expect(receipt_row.reload.encrypted_payload).to eq(original_receipt_bytes)
      second = managed_publish_arguments(context, lease, native)
      native_journal.prepare(**second)
      before = saved.current(@mapping.mapping_id).sha256
      expect {
        safeguard.enable { executor.execute(second.fetch(:command_id)) }
      }.to raise_error(DiscussionBridgeGhost::Error) { |error|
        expect(error.code).to eq("identity_conflict")
      }
      expect(reached).to eq(
        [publication.fetch(:command_id), second.fetch(:command_id)]
      )
      expect(saved.current(@mapping.mapping_id).sha256).to eq(before)
      expect(
        native_journal.retained(second.fetch(:command_id)).dig(
          "state",
          "pending_attempt"
        )
      ).to eq(nil)
    end
    with_runtime do |context, mutations|
      lease = claim(context, mutations)
      resumed =
        DiscussionBridgeGhost::NativeOwnershipJournal.new(
          context: context,
          commands:
            DiscussionBridgeGhost::NativeCommandJournal.new(context: context),
          authority: authority(context, mutations, lease),
          api_key: "a" * 24 + ":" + "12" * 32
        )
      expect(resumed.retained(kept_key).receipt.sha256).to eq(kept_receipt)
      expect(resumed.latest(@mapping.mapping_id).key).to eq(kept_key)
      expect(@mapping.reload.destination_native_id).to eq(nil)
      expect(@work.reload.state).to eq("leased")
    end
    expect(
      a_request(
        :post,
        %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
      )
    ).to have_been_made.once
    expect(
      a_request(
        :put,
        %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/}
      )
    ).to have_been_made.once
  end

  def field_control_catalogs!
    store =
      DiscussionBridge::CmsCatalogStore.new(
        @connection,
        authenticated_secret_digest: @connection.secret_digest
      )
    { "authors" => %w[1 2], "taxonomy" => %w[3 4] }.each do |kind, digits|
      items =
        digits.map do |digit|
          {
            "id" => digit * 24,
            "label" => "Synthetic #{kind} #{digit}",
            "available" => true
          }
        end
      upload =
        store.begin_upload(
          {
            "mutation_id" => SecureRandom.uuid,
            "kind" => kind,
            "native_revision" => "native:reselection",
            "total_items" => items.length
          }
        ).body
      id = upload.fetch("upload_id")
      store.append_page(
        id,
        { "mutation_id" => SecureRandom.uuid, "page" => 0, "items" => items }
      )
      store.finalize(
        id,
        {
          "mutation_id" => SecureRandom.uuid,
          "upload_id" => id,
          "expected_total_items" => items.length
        }
      )
    end
  end

  def field_control_policy!(authors:, taxonomy:, withdraw: false)
    config = @connection.reload.cms_configuration.deep_dup
    config.fetch("policy").merge!(
      "policy_revision" => SecureRandom.uuid,
      "author_ids" => authors,
      "taxonomy_ids" => taxonomy,
      "exclude_topic_ids" => withdraw ? [@topic.id.to_s] : []
    )
    @connection.update_columns(cms_configuration: config)
    @work =
      DiscussionBridge::CmsWorkCoordinator.new(@connection).enqueue!(
        @mapping,
        source_snapshot: withdraw ? nil : @snapshot,
        action: withdraw ? "withdraw" : "publish_revision"
      )
  end

  def ghost_fixture_response(status = 200)
    {
      status: status,
      headers: {
        "Content-Type" => "application/json"
      },
      body: JSON.generate("posts" => [@field_control_native])
    }
  end

  def field_control_initial_publication(
    context,
    lease,
    held,
    legacy: false,
    complete: false
  )
    commands = DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
    args, html = native_arguments(context, lease, native_id: nil, create: true)
    fields = args.fetch(:candidate).merge("visibility" => "public")
    args[:candidate] = fields.merge(
      "management" =>
        DiscussionBridgeGhost::NativeManagement.for_policy(
          protocol: context.protocol,
          policy: @connection.reload.cms_configuration.fetch("policy"),
          stage: "create_draft",
          format:
            (
              if legacy
                DiscussionBridgeGhost::NativeManagement::LEGACY_FORMAT
              else
                DiscussionBridgeGhost::NativeManagement::FORMAT
              end
            )
        ).value
    )
    args[:request]["body_bytes"] = JSON.generate("posts" => [fields])
    @field_control_native = nil
    %w[post page].each do |kind|
      stub_request(
        :get,
        %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/#{kind}s/\?filter=}
      ).to_return do
        {
          status: 200,
          headers: {
            "Content-Type" => "application/json"
          },
          body:
            JSON.generate(
              "#{kind}s" =>
                (
                  if @field_control_native && kind == "post"
                    [@field_control_native]
                  else
                    []
                  end
                )
            )
        }
      end
    end
    stub_request(
      :post,
      @target.admin_origin + args.dig(:request, "path")
    ).to_return do
      @field_control_native =
        fields.merge(
          "id" => "a" * 24,
          "type" => "post",
          "html" => html,
          "authors" => [{ "id" => "b" * 24 }],
          "tags" =>
            fields.fetch("tags").map { |tag| tag.merge("id" => "c" * 24) },
          "updated_at" => "2026-11-03T16:01:00.000Z"
        )
      ghost_fixture_response(201)
    end
    stub_request(
      :get,
      %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/#{"a" * 24}/}
    ).to_return { ghost_fixture_response }
    stub_request(
      :put,
      @target.admin_origin + "/ghost/api/admin/posts/#{"a" * 24}/"
    ).to_return do |request|
      applied = JSON.parse(request.body).fetch("posts").first
      rendered =
        if applied.key?("lexical")
          JSON
            .parse(applied.fetch("lexical"))
            .fetch("root")
            .fetch("children")
            .filter_map { |node| node["html"] }
            .join
        else
          @field_control_native.fetch("html")
        end
      updated =
        (Time.iso8601(@field_control_native.fetch("updated_at")) + 1).iso8601(3)
      @field_control_native =
        @field_control_native.merge(applied).merge(
          "html" => rendered,
          "updated_at" => updated
        )
      ghost_fixture_response
    end
    executor =
      DiscussionBridgeGhost::NativeExecutor.new(
        context: context,
        journal: commands,
        authority: held,
        api_key: "a" * 24 + ":" + "12" * 32
      )
    commands.prepare(**args)
    executor.execute(args.fetch(:command_id))
    publication =
      if complete
        complete_publication_arguments(
          context,
          lease,
          held,
          @field_control_native
        )
      else
        managed_publish_arguments(context, lease, @field_control_native)
      end
    if legacy
      publication.fetch(:candidate)[
        "management"
      ] = DiscussionBridgeGhost::NativeManagement.for_policy(
        protocol: context.protocol,
        policy: @connection.reload.cms_configuration.fetch("policy"),
        stage: "publish",
        format: DiscussionBridgeGhost::NativeManagement::LEGACY_FORMAT
      ).value
    end
    commands.prepare(**publication)
    executor.execute(publication.fetch(:command_id))
    publication.fetch(:command_id)
  end

  def field_control_ownership(context, commands, held)
    DiscussionBridgeGhost::NativeOwnershipJournal.new(
      context: context,
      commands: commands,
      authority: held,
      api_key: "a" * 24 + ":" + "12" * 32
    )
  end

  def field_control_edit!(relation, id)
    @field_control_native = Marshal.load(Marshal.dump(@field_control_native))
    if relation == "authors"
      @field_control_native["authors"] = [{ "id" => id }]
    else
      @field_control_native["tags"] = @field_control_native
        .fetch("tags")
        .select { |tag| tag.fetch("name").start_with?("#discussionbridge-") } +
        [{ "id" => id, "name" => "Ghost editorial edit" }]
    end
    @field_control_native["updated_at"] = (
      Time.iso8601(@field_control_native.fetch("updated_at")) + 1
    ).iso8601(3)
  end

  def native_stage_source_policy!
    @native_stage_category ||= Fabricate(:category)
    config = @connection.reload.cms_configuration.deep_dup
    config.fetch("policy").merge!(
      "selection" => "categories",
      "category_ids" => [@native_stage_category.id.to_s],
      "include_topic_ids" => [@topic.id.to_s],
      "exclude_topic_ids" => [],
      "policy_revision" => SecureRandom.uuid
    )
    @connection.update_columns(cms_configuration: config)
    @snapshot =
      DiscussionBridge::CmsSourceStore
        .new(@connection)
        .capture_snapshot(@topic)
        .metadata
    @work =
      DiscussionBridge::CmsWorkCoordinator.new(@connection).enqueue!(
        @mapping,
        source_snapshot: @snapshot
      )
    DiscussionBridge::CmsSourceStore.new(@connection).refresh_all!
  end

  def native_stage_source(context)
    intake = DiscussionBridgeGhost::SourceIntake.new(context: context)
    page = intake.advance
    item =
      page
        .fetch("items")
        .find { |entry| entry.dig("source", "source_id") == @mapping.source_id }
    expect(item).to be_present
    @native_event_id = item.fetch("event_id")
    expect(
      intake.advance_content(@native_event_id, chunk_budget: 8).fetch(
        "complete"
      )
    ).to eq(true)
    @native_event_id
  end

  def complete_publication_arguments(context, lease, held, native)
    args, = native_arguments(context, lease)
    root =
      Nokogiri::HTML5.fragment(
        native.fetch("html"),
        **DiscussionBridgeGhost::OwnedFragment::OPTIONS
      )
    section = root.at_css("section[data-discussionbridge-owned]")
    fragment =
      DiscussionBridgeGhost::OwnedFragment.new(
        resource_id: @record.resource_id,
        kind: "post",
        native_id: native.fetch("id"),
        nonce: section["data-discussionbridge-fragment-nonce"],
        maximum_bytes: 262_144
      )
    prior =
      DiscussionBridgeGhost::OwnedFragment.new(
        resource_id: @record.resource_id,
        kind: "post",
        native_id: section["data-discussionbridge-native-id"],
        nonce: fragment.nonce,
        maximum_bytes: 262_144
      )
    intake = DiscussionBridgeGhost::SourceIntake.new(context: context)
    article =
      DiscussionBridgeGhost::NativeArticle.new(
        protocol: context.protocol,
        forum_origin: context.binding.fetch("forum_origin"),
        source: intake.source(@native_event_id),
        html: intake.content(@native_event_id),
        maximum_bytes: 262_144
      )
    connection = context.read("V4-01").value
    mapping =
      context.read("V4-11", path: { "mapping_id" => @mapping.mapping_id }).value
    publication =
      DiscussionBridgeGhost::NativePublication.new(
        protocol: context.protocol,
        article: article,
        fragment: fragment,
        mapping: mapping,
        work: lease.fetch("work"),
        forum_name: connection.fetch("forum_name"),
        command_id: args.fetch(:command_id)
      )
    management = held.native_management!(stage: "publish")
    fields = {
      "id" => native.fetch("id"),
      "updated_at" => native.fetch("updated_at"),
      "title" => publication.title,
      "slug" => native.fetch("slug"),
      "status" => "published",
      "visibility" => "public",
      "published_at" => publication.publication_date,
      "lexical" =>
        DiscussionBridgeGhost::OwnedLexical.new(fragment: fragment).replace(
          current: native,
          html: publication.html,
          expected_revision: native.fetch("updated_at"),
          baseline_sha256: prior.extract(native.fetch("html")).sha256,
          prior_fragment: prior
        ),
      "tags" =>
        native
          .fetch("tags")
          .reject do |tag|
            DiscussionBridgeGhost::NativeManagement::INTERNAL_TAGS.include?(
              tag.fetch("name")
            )
          end +
          [
            { "id" => "d" * 24, "name" => "#discussionbridge-source" },
            {
              "id" => "e" * 24,
              "name" =>
                "#discussionbridge-#{mapping.fetch("presentation_mode")}"
            }
          ]
    }
    if management.value.fetch("author_ids")
      fields["authors"] = management
        .value
        .fetch("author_ids")
        .map { |id| { "id" => id } }
    end
    if management.value.fetch("taxonomy_ids")
      fields["tags"] = fields
        .fetch("tags")
        .select { |tag| tag.fetch("name").start_with?("#discussionbridge-") } +
        management
          .value
          .fetch("taxonomy_ids")
          .map { |id| { "id" => id, "name" => "Selected #{id}" } }
    end
    # Native API URL fixture, not an anonymous-public-page verification claim.
    @field_control_native = native.merge("url" => @binding.canonical_url)
    args[:baseline] = @field_control_native
    args[:candidate] = @field_control_native.merge(fields).merge(
      "management" => management.value
    )
    args[:request]["body_bytes"] = JSON.generate("posts" => [fields])
    args
  end

  def native_acknowledgements(context, mutations, commands, held, lease)
    DiscussionBridgeGhost::NativeAcknowledgements.new(
      context: context,
      commands: commands,
      authority: held,
      journal: mutations,
      lease: lease,
      api_key: "a" * 24 + ":" + "12" * 32
    )
  end

  it "synchronizes actual complete native content and verifies its anonymous public fragment through V4" do
    native_stage_source_policy!
    old_lease = nil
    with_runtime do |context, mutations|
      native_stage_source(context)
      lease = old_lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      field_control_initial_publication(context, lease, held, complete: true)
      commands =
        DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
      checker =
        DiscussionBridgeGhost::NativeReadiness.new(
          context: context,
          commands: commands,
          authority: held,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      readiness = checker.capture(event_id: @native_event_id)
      expect(checker.actual_evidence(readiness)).to eq(readiness.value)
      expect(checker.actual_evidence(checker.retained(readiness.key))).to eq(
        nil
      )
      copied =
        DiscussionBridgeGhost::NativeReadiness::Observation.new(
          key: readiness.key,
          value: readiness.value
        )
      expect(checker.actual_evidence(copied)).to eq(nil)
      stages =
        native_acknowledgements(context, mutations, commands, held, lease)
      synced = stages.synchronize(event_id: @native_event_id)
      expect(synced.result.status).to eq(200)
      expect(synced.observed.dig("work", "state")).to eq("synchronized")
      expect(synced.historical).to eq(false)
      expect(@mapping.reload.destination_native_id).to eq("a" * 24)
      # Ghost controls the cleared author field; its later metadata revision
      # must not block verification of unchanged published content.
      field_control_edit!("authors", "9" * 24)
      expect { held.guard!(operation: :mutate) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      page =
        "<!doctype html><html><head><title>Native Ghost fixture</title></head><body>#{@field_control_native.fetch("html")}</body></html>"
      public_get =
        stub_request(:get, @binding.canonical_url)
          .with do |request|
            expect(request.headers.keys).not_to include(
              "Authorization",
              "Cookie"
            )
            true
          end
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "text/html; charset=utf-8"
            },
            body: page
          )
      verified = stages.verify(event_id: @native_event_id)
      expect(verified.result.status).to eq(200)
      expect(verified.observed.dig("work", "state")).to eq("verified")
      expect(verified.historical).to eq(false)
      expect(@mapping.reload.publicly_verified_source_revision).to eq(
        @snapshot.fetch("source_revision")
      )
      expect(public_get).to have_been_requested.once
    end
    before =
      @installation
        .operational_records
        .where(kind: "native_acknowledgement_intent")
        .order(:id)
        .pluck(:encrypted_payload)
    with_runtime do |context, mutations|
      commands =
        DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
      stages =
        native_acknowledgements(
          context,
          mutations,
          commands,
          authority(context, mutations, old_lease),
          old_lease
        )
      replay = stages.verify(event_id: @native_event_id)
      expect(replay.historical).to eq(true)
      expect(replay.result.status).to eq(200)
      expect(replay.observed.dig("work", "state")).to eq("verified")
    end
    expect(
      @installation
        .operational_records
        .where(kind: "native_acknowledgement_intent")
        .order(:id)
        .pluck(:encrypted_payload)
    ).to eq(before)
    expect(
      a_request(
        :post,
        %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
      )
    ).to have_been_made.once
    expect(
      a_request(
        :put,
        %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
      )
    ).to have_been_made.once
  end

  it "does not acknowledge an owned but incomplete or old desired publication" do
    native_stage_source_policy!
    with_runtime do |context, mutations|
      native_stage_source(context)
      lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      field_control_initial_publication(context, lease, held)
      stages =
        native_acknowledgements(
          context,
          mutations,
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context),
          held,
          lease
        )
      expect { stages.synchronize(event_id: @native_event_id) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(@work.reload.state).to eq("leased")
      expect(@installation.mutations.where(route_id: "V4-16").count).to eq(0)
      expect(
        @installation
          .operational_records
          .where(kind: "native_acknowledgement_intent")
          .count
      ).to eq(0)
    end
  end

  it "keeps synchronized work unverified for a wrong public representation, redirect or login-only response" do
    native_stage_source_policy!
    with_runtime do |context, mutations|
      native_stage_source(context)
      lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      field_control_initial_publication(context, lease, held, complete: true)
      stages =
        native_acknowledgements(
          context,
          mutations,
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context),
          held,
          lease
        )
      expect(
        stages.synchronize(event_id: @native_event_id).result.status
      ).to eq(200)
      [
        {
          status: 200,
          headers: {
            "Content-Type" => "text/html"
          },
          body: "<html><body>Wrong page</body></html>"
        },
        {
          status: 302,
          headers: {
            "Location" => "#{@target.ghost_origin}/login/"
          }
        },
        { status: 401 }
      ].each do |response|
        stub_request(:get, @binding.canonical_url).to_return(response)
        expect { stages.verify(event_id: @native_event_id) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        expect(@work.reload.state).to eq("synchronized")
        expect(@installation.mutations.where(route_id: "V4-16").count).to eq(1)
      end
    end
  end

  def stage_observing_app(requests)
    lambda do |env|
      if env.fetch("PATH_INFO").end_with?("/acknowledge.json")
        requests << env.fetch("rack.input").read
        env.fetch("rack.input").rewind
      end
      Rails.application.call(env)
    end
  end

  it "does not report an old cached acknowledgement as current after receiver-state loss" do
    native_stage_source_policy!
    with_runtime do |context, mutations|
      native_stage_source(context)
      lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      field_control_initial_publication(context, lease, held, complete: true)
      stages =
        native_acknowledgements(
          context,
          mutations,
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context),
          held,
          lease
        )
      expect(
        stages.synchronize(event_id: @native_event_id).result.status
      ).to eq(200)
      # Synthetic receiver rollback fixture ONLY. This is not a performed
      # backup/restore or installed rollback qualification.
      @work.update!(state: "leased")
      @mapping.update!(
        destination_native_id: nil,
        destination_native_revision: nil,
        synchronized_source_revision: nil,
        synchronized_at: nil,
        native_result: nil
      )
      DiscussionBridgeCmsMutationReceipt.where(
        content_connection_id: @connection.id,
        route: "acknowledge",
        path_resource: @work.work_id
      ).delete_all
      expect { stages.synchronize(event_id: @native_event_id) }.to raise_error(
        DiscussionBridgeGhost::Error
      ) { |error| expect(error.code).to eq("acknowledgement_not_current") }
      expect(@work.reload.state).to eq("leased")
      expect(
        @installation
          .mutations
          .where(route_id: "V4-16", state: "completed")
          .count
      ).to eq(1)
      expect(
        DiscussionBridgeCmsMutationReceipt.where(
          content_connection_id: @connection.id,
          route: "acknowledge",
          path_resource: @work.work_id
        ).count
      ).to eq(0)
    end
  end

  %w[synchronized verified].each do |lost_stage|
    it "recovers the exact #{lost_stage} acknowledgement after the receiver replied but the local receipt was interrupted" do
      native_stage_source_policy!
      requests = []
      original_lease = original_intent = nil
      public_get = nil
      with_runtime(app: stage_observing_app(requests)) do |context, mutations|
        native_stage_source(context)
        lease = original_lease = claim(context, mutations)
        held = authority(context, mutations, lease)
        field_control_initial_publication(context, lease, held, complete: true)
        stages =
          native_acknowledgements(
            context,
            mutations,
            DiscussionBridgeGhost::NativeCommandJournal.new(context: context),
            held,
            lease
          )
        public_get =
          stub_request(:get, @binding.canonical_url).to_return do
            {
              status: 200,
              headers: {
                "Content-Type" => "text/html"
              },
              body:
                "<!doctype html><html><body>#{@field_control_native.fetch("html")}</body></html>"
            }
          end
        if lost_stage == "verified"
          stages.synchronize(event_id: @native_event_id)
        end
        interrupted = false
        allow(mutations).to receive(
          :retain_response
        ).and_wrap_original do |original, operation, packet, result|
          if !interrupted && packet.route_id == "V4-16" &&
               JSON.parse(packet.body_bytes).fetch("stage") == lost_stage
            interrupted = true
            raise "synthetic ACK receipt interruption"
          end
          original.call(operation, packet, result)
        end
        action = lost_stage == "synchronized" ? :synchronize : :verify
        expect {
          stages.public_send(action, event_id: @native_event_id)
        }.to raise_error("synthetic ACK receipt interruption")
        expect(@work.reload.state).to eq(lost_stage)
        original_intent =
          @installation
            .operational_records
            .find_by!(
              kind: DiscussionBridgeGhost::NativeAcknowledgements::ENTRY,
              record_key:
                "#{@work.work_id}:#{lease.fetch("lease_generation")}:#{lost_stage}"
            )
            .encrypted_payload
      end
      with_runtime(app: stage_observing_app(requests)) do |context, mutations|
        stages =
          native_acknowledgements(
            context,
            mutations,
            DiscussionBridgeGhost::NativeCommandJournal.new(context: context),
            authority(context, mutations, original_lease),
            original_lease
          )
        action = lost_stage == "synchronized" ? :synchronize : :verify
        replay = stages.public_send(action, event_id: @native_event_id)
        expect(replay.result.status).to eq(200)
        expect(replay.historical).to eq(true)
        expect(replay.observed.dig("work", "state")).to eq(lost_stage)
        expect(
          @installation
            .operational_records
            .find_by!(
              kind: DiscussionBridgeGhost::NativeAcknowledgements::ENTRY,
              record_key:
                "#{@work.work_id}:#{original_lease.fetch("lease_generation")}:#{lost_stage}"
            )
            .encrypted_payload
        ).to eq(original_intent)
        if lost_stage == "synchronized"
          expect(stages.verify(event_id: @native_event_id).result.status).to eq(
            200
          )
        end
      end
      repeated =
        requests.select do |bytes|
          JSON.parse(bytes).fetch("stage") == lost_stage
        end
      expect(repeated.length).to eq(2)
      expect(repeated.last).to eq(repeated.first)
      expect(@work.reload.state).to eq("verified")
      expect(
        DiscussionBridgeCmsMutationReceipt.where(
          content_connection_id: @connection.id,
          route: "acknowledge",
          path_resource: @work.work_id
        ).count
      ).to eq(2)
      expect(public_get).to have_been_requested.once
      expect(
        a_request(
          :post,
          %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
        )
      ).to have_been_made.once
      expect(
        a_request(
          :put,
          %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
        )
      ).to have_been_made.once
    end
  end

  it "resolves an old synchronized acknowledgement as history without granting a superseded lease verification" do
    native_stage_source_policy!
    with_runtime do |context, mutations|
      native_stage_source(context)
      lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      field_control_initial_publication(context, lease, held, complete: true)
      stages =
        native_acknowledgements(
          context,
          mutations,
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context),
          held,
          lease
        )
      expect(
        stages.synchronize(event_id: @native_event_id).result.status
      ).to eq(200)
      old_work = @work
      field_control_policy!(authors: [], taxonomy: [])
      replay = stages.synchronize(event_id: @native_event_id)
      expect(replay.historical).to eq(true)
      expect(replay.result.value.dig("work", "state")).to eq("synchronized")
      expect(replay.observed.dig("work", "state")).to eq("superseded")
      expect { stages.verify(event_id: @native_event_id) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(old_work.reload.state).to eq("superseded")
      expect(@work.reload.state).to eq("pending")
    end
    expect(a_request(:get, @binding.canonical_url)).not_to have_been_made
  end

  it "withdraws and republishes the same owned native post with separate current synchronization and public proofs" do
    native_stage_source_policy!
    with_runtime do |context, mutations|
      native_stage_source(context)
      lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      field_control_initial_publication(context, lease, held, complete: true)
      stages =
        native_acknowledgements(
          context,
          mutations,
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context),
          held,
          lease
        )
      stages.synchronize(event_id: @native_event_id)
      stub_request(:get, @binding.canonical_url).to_return(
        status: 200,
        headers: {
          "Content-Type" => "text/html"
        },
        body:
          "<!doctype html><html><body>#{@field_control_native.fetch("html")}</body></html>"
      )
      expect(stages.verify(event_id: @native_event_id).result.status).to eq(200)
    end
    config = @connection.reload.cms_configuration.deep_dup
    config.fetch("policy")["include_topic_ids"] = []
    @connection.update_columns(cms_configuration: config)
    field_control_policy!(authors: [], taxonomy: [], withdraw: true)
    with_runtime do |context, mutations|
      lease = claim(context, mutations, key: "claim:withdraw-stage")
      held = authority(context, mutations, lease)
      commands =
        DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
      args, = native_arguments(context, lease)
      fields = {
        "id" => "a" * 24,
        "updated_at" => @field_control_native.fetch("updated_at"),
        "status" => "draft"
      }
      args[:baseline] = @field_control_native
      args[:candidate] = @field_control_native.merge(fields).merge(
        "management" => held.native_management!(stage: "withdraw").value
      )
      args[:request]["body_bytes"] = JSON.generate("posts" => [fields])
      commands.prepare(**args)
      DiscussionBridgeGhost::NativeExecutor.new(
        context: context,
        journal: commands,
        authority: held,
        api_key: "a" * 24 + ":" + "12" * 32
      ).execute(args.fetch(:command_id))
      stages =
        native_acknowledgements(context, mutations, commands, held, lease)
      expect(stages.synchronize.result.status).to eq(200)
      stub_request(:get, @binding.canonical_url).to_return(status: 403)
      expect { stages.verify }.to raise_error(DiscussionBridgeGhost::Error)
      expect(@work.reload.state).to eq("synchronized")
      stub_request(:get, @binding.canonical_url).to_return(status: 404)
      expect(stages.verify.result.status).to eq(200)
      expect(@mapping.reload.mapping_state).to eq("withdrawn")
    end
    native_stage_source_policy!
    expect(@mapping.reload.mapping_state).to eq("pending")
    with_runtime do |context, mutations|
      lease = claim(context, mutations, key: "claim:republish-stage")
      held = authority(context, mutations, lease)
      commands =
        DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
      args =
        complete_publication_arguments(
          context,
          lease,
          held,
          @field_control_native
        )
      commands.prepare(**args)
      DiscussionBridgeGhost::NativeExecutor.new(
        context: context,
        journal: commands,
        authority: held,
        api_key: "a" * 24 + ":" + "12" * 32
      ).execute(args.fetch(:command_id))
      stages =
        native_acknowledgements(context, mutations, commands, held, lease)
      expect(
        stages.synchronize(event_id: @native_event_id).result.status
      ).to eq(200)
      stub_request(:get, @binding.canonical_url).to_return(
        status: 200,
        headers: {
          "Content-Type" => "text/html"
        },
        body:
          "<!doctype html><html><body>#{@field_control_native.fetch("html")}</body></html>"
      )
      expect(stages.verify(event_id: @native_event_id).result.status).to eq(200)
      expect(@mapping.reload.destination_native_id).to eq("a" * 24)
      expect(@mapping.mapping_state).to eq("active")
    end
    expect(
      a_request(
        :post,
        %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
      )
    ).to have_been_made.once
    expect(
      a_request(
        :put,
        %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
      )
    ).to have_been_made.times(3)
  end

  %w[authors taxonomy]
    .product(%w[before_enrollment after_enrollment])
    .each do |relation, timing|
      it "preserves legacy withdrawal history with a same-generation #{relation} release #{timing}" do
        field_control_catalogs!
        field_control_policy!(authors: ["1" * 24], taxonomy: ["3" * 24])
        original_command = withdrawal_command = release_lease = nil
        historical_bytes = []
        with_runtime do |context, mutations|
          lease = claim(context, mutations, key: "claim:legacy-selected")
          original_command =
            field_control_initial_publication(
              context,
              lease,
              authority(context, mutations, lease),
              legacy: true
            )
        end
        # Explicit synthetic receiver binding after actual local execution; this
        # is not public verification, an ACK, or a synchronized-work assertion.
        @mapping.update!(destination_native_id: "a" * 24)
        field_control_policy!(
          authors: relation == "authors" ? [] : ["1" * 24],
          taxonomy: relation == "taxonomy" ? [] : ["3" * 24],
          withdraw: true
        )
        with_runtime do |context, mutations|
          release_lease =
            claim(context, mutations, key: "claim:legacy-withdraw")
          expect(release_lease.fetch("lease_generation")).to eq(2)
          held = authority(context, mutations, release_lease)
          commands =
            DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
          args, = native_arguments(context, release_lease)
          fields = {
            "id" => "a" * 24,
            "updated_at" => @field_control_native.fetch("updated_at"),
            "status" => "draft"
          }
          management =
            DiscussionBridgeGhost::NativeManagement.for_policy(
              protocol: context.protocol,
              policy: @connection.reload.cms_configuration.fetch("policy"),
              stage: "withdraw",
              format: DiscussionBridgeGhost::NativeManagement::LEGACY_FORMAT
            )
          expect(management.released_relations).to eq([])
          args[:baseline] = @field_control_native
          args[:candidate] = @field_control_native.merge(fields).merge(
            "management" => management.value
          )
          args[:request]["body_bytes"] = JSON.generate("posts" => [fields])
          withdrawal_command = args.fetch(:command_id)
          commands.prepare(**args)
          if timing == "before_enrollment"
            # Genuine current-policy observation AFTER the old-format intent was
            # prepared, BEFORE execution/enrollment. Preparation is not the saved
            # projection's cutoff: this fact must remain usable after restart.
            held.native_management!(stage: "withdraw")
          end
          executor =
            DiscussionBridgeGhost::NativeExecutor.new(
              context: context,
              journal: commands,
              authority: held,
              api_key: "a" * 24 + ":" + "12" * 32
            )
          executor.execute(withdrawal_command)
          expect(
            @installation
              .operational_records
              .where(kind: "native_field_release")
              .count
          ).to eq(timing == "before_enrollment" ? 1 : 0)
          baselines =
            DiscussionBridgeGhost::NativeBaselineJournal.new(
              context: context,
              journal: commands
            )
          baseline = baselines.current(@mapping.mapping_id)
          retained_selection =
            if timing == "before_enrollment"
              nil
            else
              relation == "authors" ? ["1" * 24] : ["3" * 24]
            end
          expect(baseline.value.fetch(relation)).to eq(retained_selection)
          # Save original immutable command/completion/baseline bytes BEFORE the
          # modern observer first records the cleared field, at the SAME lease.
          historical_bytes =
            @installation
              .operational_records
              .where(
                record_key: [original_command, withdrawal_command],
                kind: %w[native_command native_progress native_managed_baseline]
              )
              .order(:id)
              .pluck(:id, :encrypted_payload)
          ownership = field_control_ownership(context, commands, held)
          observation = ownership.capture
          historical_bytes +=
            @installation
              .operational_records
              .where(
                kind: "native_ownership_receipt",
                record_key: observation.key
              )
              .pluck(:id, :encrypted_payload)
          release =
            @installation.operational_records.find_by!(
              kind: "native_field_release"
            )
          expect(release.private_payload.dig("work", "lease_generation")).to eq(
            2
          )
          enrolled =
            @installation.operational_records.find_by!(
              kind: "native_managed_baseline",
              record_key: withdrawal_command
            )
          if timing == "before_enrollment"
            expect(release.id).to be < enrolled.id
          else
            expect(release.id).to be > enrolled.id
          end
          expect(baselines.current(@mapping.mapping_id).value).to eq(
            baseline.value
          )
          expect(
            baseline.released_relations(
              journal: commands,
              through_generation: 2
            )
          ).to eq([relation])
          expect(
            baseline.released_relations(
              journal: commands,
              through_generation: 2,
              before_record_id: enrolled.id
            )
          ).to eq(timing == "before_enrollment" ? [relation] : [])
          expect {
            baseline.released_relations(
              journal: commands,
              through_generation: 2,
              before_record_id: 0
            )
          }.to raise_error(DiscussionBridgeGhost::Error)
        end
        field_control_edit!(relation, "9" * 24)
        with_runtime do |context, mutations|
          commands =
            DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
          held = authority(context, mutations, release_lease)
          field_control_ownership(context, commands, held).capture
          expect(
            DiscussionBridgeGhost::NativeBaselineJournal
              .new(context: context, journal: commands)
              .retained(withdrawal_command)
              .value
              .fetch(relation)
          ).to eq(
            (
              if timing == "before_enrollment"
                nil
              else
                (relation == "authors" ? ["1" * 24] : ["3" * 24])
              end
            )
          )
        end
        field_control_policy!(
          authors: relation == "authors" ? ["2" * 24] : ["1" * 24],
          taxonomy: relation == "taxonomy" ? ["4" * 24] : ["3" * 24]
        )
        selected_command = nil
        with_runtime do |context, mutations|
          lease = claim(context, mutations, key: "claim:legacy-reselection")
          expect(lease.fetch("lease_generation")).to eq(3)
          held = authority(context, mutations, lease)
          commands =
            DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
          ownership = field_control_ownership(context, commands, held)
          ownership.capture
          selected =
            managed_publish_arguments(context, lease, @field_control_native)
          selected_command = selected.fetch(:command_id)
          commands.prepare(**selected)
          executor =
            DiscussionBridgeGhost::NativeExecutor.new(
              context: context,
              journal: commands,
              authority: held,
              api_key: "a" * 24 + ":" + "12" * 32
            )
          result = executor.execute(selected_command)
          expect(result.fetch("native_id")).to eq("a" * 24)
          expect(executor.execute(selected_command)).to eq(result)
          field_control_edit!(relation, "9" * 24)
          expect { ownership.capture }.to raise_error(
            DiscussionBridgeGhost::Error
          )
        end
        with_runtime do |context, _mutations|
          commands =
            DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
          baselines =
            DiscussionBridgeGhost::NativeBaselineJournal.new(
              context: context,
              journal: commands
            )
          expect(
            baselines.current(@mapping.mapping_id).value.fetch("command_id")
          ).to eq(selected_command)
          expect(
            baselines.retained(withdrawal_command).value.fetch(relation)
          ).to eq(
            (
              if timing == "before_enrollment"
                nil
              else
                (relation == "authors" ? ["1" * 24] : ["3" * 24])
              end
            )
          )
        end
        expect(
          @installation
            .operational_records
            .where(id: historical_bytes.map(&:first))
            .order(:id)
            .pluck(:id, :encrypted_payload)
        ).to eq(historical_bytes.sort_by(&:first))
        expect(
          a_request(
            :post,
            %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
          )
        ).to have_been_made.once
        expect(
          a_request(
            :put,
            %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
          )
        ).to have_been_made.times(3)
      end
    end

  %w[authors taxonomy].each do |relation|
    it "retains #{relation} release across restart and re-selection without an intervening native write" do
      field_control_catalogs!
      field_control_policy!(authors: ["1" * 24], taxonomy: ["3" * 24])
      original_command = original_baseline = original_receipt = nil
      release_lease = release_key = release_bytes = nil
      with_runtime do |context, mutations|
        lease = claim(context, mutations, key: "claim:initial-selected")
        held = authority(context, mutations, lease)
        original_command =
          field_control_initial_publication(context, lease, held)
        commands =
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
        observed = field_control_ownership(context, commands, held).capture
        original_baseline =
          @installation
            .operational_records
            .find_by!(
              kind: "native_managed_baseline",
              record_key: original_command
            )
            .encrypted_payload
        original_receipt = [
          observed.key,
          @installation
            .operational_records
            .find_by!(
              kind: "native_ownership_receipt",
              record_key: observed.key
            )
            .encrypted_payload
        ]
      end
      field_control_policy!(
        authors: relation == "authors" ? [] : ["1" * 24],
        taxonomy: relation == "taxonomy" ? [] : ["3" * 24]
      )
      with_runtime do |context, mutations|
        release_lease = claim(context, mutations, key: "claim:clear-selection")
        held = authority(context, mutations, release_lease)
        commands =
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
        field_control_ownership(context, commands, held).capture
        release =
          @installation.operational_records.find_by!(
            kind: "native_field_release"
          )
        expect(release.private_payload.fetch("relation")).to eq(relation)
        release_key, release_bytes =
          release.record_key,
          release.encrypted_payload
        expect(release.private_payload.dig("work", "lease_generation")).to eq(
          release_lease.fetch("lease_generation")
        )
      end
      # Restart follows the clear, before an independent Ghost editor changes
      # the released field. This is an external-editor HTTP fixture, not a
      # Discourse-authorized native write or live installation proof.
      field_control_edit!(relation, "9" * 24)
      with_runtime do |context, mutations|
        held = authority(context, mutations, release_lease)
        commands =
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
        field_control_ownership(context, commands, held).capture
        expect(
          @installation
            .operational_records
            .find_by!(kind: "native_field_release", record_key: release_key)
            .encrypted_payload
        ).to eq(release_bytes)
      end
      field_control_policy!(
        authors: relation == "authors" ? ["2" * 24] : ["1" * 24],
        taxonomy: relation == "taxonomy" ? ["4" * 24] : ["3" * 24]
      )
      selected_command = nil
      with_runtime do |context, mutations|
        expect { authority(context, mutations, release_lease) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        lease = claim(context, mutations, key: "claim:explicit-reselection")
        held = authority(context, mutations, lease)
        commands =
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
        ownership = field_control_ownership(context, commands, held)
        # Current selection is no longer empty, but its old physical baseline
        # must stay untouched until the real new write completes.
        ownership.capture
        descriptor = held.native_management!(stage: "publish")
        expect {
          DiscussionBridgeGhost::NativeFieldControlJournal.new(
            context: context
          ).observe!(descriptor)
        }.to raise_error(DiscussionBridgeGhost::Error)
        damaged =
          @installation.operational_records.find_by!(
            kind: "native_field_release",
            record_key: release_key
          )
        payload = damaged.private_payload
        payload.fetch("work")["lease_generation"] += 1
        rewrite_record(damaged, payload)
        expect { ownership.capture }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        damaged.update!(encrypted_payload: release_bytes)
        ownership.capture
        safe = @field_control_native
        other = relation == "authors" ? "taxonomy" : "authors"
        field_control_edit!(other, "8" * 24)
        expect { ownership.capture }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        @field_control_native =
          safe.merge("title" => "Edited still-managed title")
        expect { ownership.capture }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        @field_control_native = safe.merge("tags" => [])
        expect { ownership.capture }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        @field_control_native = safe
        selected =
          managed_publish_arguments(context, lease, @field_control_native)
        selected_command = selected.fetch(:command_id)
        commands.prepare(**selected)
        executor =
          DiscussionBridgeGhost::NativeExecutor.new(
            context: context,
            journal: commands,
            authority: held,
            api_key: "a" * 24 + ":" + "12" * 32
          )
        result = executor.execute(selected_command)
        expect(executor.execute(selected_command)).to eq(result)
        expect(result.fetch("native_id")).to eq("a" * 24)
        current =
          DiscussionBridgeGhost::NativeBaselineJournal.new(
            context: context,
            journal: commands
          ).current(@mapping.mapping_id)
        expected = relation == "authors" ? ["2" * 24] : ["4" * 24]
        expect(current.value.fetch(relation)).to eq(expected)
        # An applied explicit selection is managed again; its earlier release
        # cannot become an unlimited exemption for subsequent editorial edits.
        field_control_edit!(relation, "9" * 24)
        expect { ownership.capture }.to raise_error(
          DiscussionBridgeGhost::Error
        )
      end
      # A later clear crosses the decimal 9 -> 10 boundary. It cannot become
      # retroactive permission while reconstructing the earlier generation-3
      # completion, or shadow the earlier release in a bounded history lookup.
      field_control_policy!(
        authors: relation == "authors" ? [] : ["1" * 24],
        taxonomy: relation == "taxonomy" ? [] : ["3" * 24]
      )
      @mapping.update!(fence_generation: 9) # synthetic prior receiver high-water
      with_runtime do |context, mutations|
        lease = claim(context, mutations, key: "claim:later-clear")
        expect(lease.fetch("lease_generation")).to eq(10)
        authority(context, mutations, lease).native_management!(
          stage: "publish"
        )
        commands =
          DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
        saved =
          DiscussionBridgeGhost::NativeBaselineJournal.new(
            context: context,
            journal: commands
          )
        prior = saved.current(@mapping.mapping_id)
        expect(prior.value.fetch("command_id")).to eq(selected_command)
        history =
          DiscussionBridgeGhost::NativeFieldControlJournal.new(context: context)
        expect(
          history.released_relations(
            identity: prior.value.fetch("identity"),
            after_generation: release_lease.fetch("lease_generation"),
            through_generation: 9
          )
        ).to eq([])
        expect(
          history.released_relations(
            identity: prior.value.fetch("identity"),
            after_generation: 0,
            through_generation: 9
          )
        ).to eq([relation])
      end
      with_runtime do |context, _mutations|
        saved =
          DiscussionBridgeGhost::NativeBaselineJournal.new(
            context: context,
            journal:
              DiscussionBridgeGhost::NativeCommandJournal.new(context: context)
          )
        expect(
          saved.current(@mapping.mapping_id).value.fetch("command_id")
        ).to eq(selected_command)
        expect(saved.retained(original_command).value.fetch(relation)).to eq(
          relation == "authors" ? ["1" * 24] : ["3" * 24]
        )
      end
      expect(
        @installation
          .operational_records
          .find_by!(
            kind: "native_managed_baseline",
            record_key: original_command
          )
          .encrypted_payload
      ).to eq(original_baseline)
      expect(
        @installation
          .operational_records
          .find_by!(
            kind: "native_ownership_receipt",
            record_key: original_receipt.first
          )
          .encrypted_payload
      ).to eq(original_receipt.last)
      expect(
        @installation
          .operational_records
          .find_by!(kind: "native_field_release", record_key: release_key)
          .encrypted_payload
      ).to eq(release_bytes)
      expect(
        @installation
          .operational_records
          .where(kind: "native_field_release")
          .count
      ).to eq(2)
      expect(
        a_request(
          :post,
          %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
        )
      ).to have_been_made.once
      expect(
        a_request(
          :put,
          %r{#{Regexp.escape(@target.admin_origin)}/ghost/api/admin/posts/}
        )
      ).to have_been_made.twice
    end
  end

  it "does not let a current From lease authorize another generation, resource, To move or From move" do
    with_runtime do |context, mutations|
      lease = claim(context, mutations)
      held = authority(context, mutations, lease)
      command = {
        "binding" => context.binding,
        "identity" => {
          "resource_id" => @record.resource_id
        },
        "owner" => {
          "direction" => "from_discourse",
          "action" => "create_draft",
          "mapping_id" => @mapping.mapping_id,
          "work_id" => @work.work_id,
          "generation" => lease.fetch("lease_generation"),
          "source_revision" => @work.source_revision,
          "external_id" => @binding.external_id,
          "move_id" => nil,
          "proof_nonce" => nil
        }
      }
      [
        { "direction" => "to_discourse", "action" => "source_move" },
        { "generation" => lease.fetch("lease_generation") + 1 },
        { "work_id" => SecureRandom.uuid },
        { "action" => "withdraw" },
        { "move_id" => SecureRandom.uuid, "proof_nonce" => "x" * 64 }
      ].each do |delta|
        expect {
          held.guard_native!(
            command.merge("owner" => command["owner"].merge(delta))
          )
        }.to raise_error(DiscussionBridgeGhost::Error)
      end
      expect {
        held.guard_native!(
          command.merge("identity" => { "resource_id" => SecureRandom.uuid })
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(@installation.mutations.where(route_id: "V4-15").count).to eq(0)
    end
  end

  it "renews through actual authentication/controllers and persists a cross-restart mapping fence" do
    lease = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      held = authority(context, journal, lease)
      expect(
        held.guard!(operation: :mutate).fetch("work").fetch("work_id")
      ).to eq(@work.work_id)
    end
    expect(state.fetch("next_renewal")).to eq(1)
    expect(state.fetch("pending")).to eq(nil)
    fence =
      @installation
        .operational_records
        .find_by!(kind: "mapping_fence")
        .private_payload
    expect(fence.fetch("generation")).to eq(lease.fetch("lease_generation"))
    ciphertext =
      @installation
        .operational_records
        .find_by!(kind: "work_authority")
        .encrypted_payload
    expect(ciphertext).not_to include(lease.fetch("lease_token"))
    with_runtime do |context, journal|
      expect(
        authority(context, journal, lease)
          .guard!(operation: :mutate)
          .fetch("work")
          .fetch("state")
      ).to eq("leased")
    end
    expect(state.fetch("next_renewal")).to eq(2)
    expect(
      @connection.reload.cms_configuration.fetch("policy").fetch("enabled")
    ).to eq(true)
  end

  it "commits the pending pointer before journal preparation and resumes its same mutation ID" do
    lease = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      held = authority(context, journal, lease)
      allow(journal).to receive(:call).and_raise(
        "synthetic pre-journal interruption"
      )
      expect { held.guard!(operation: :mutate) }.to raise_error(/pre-journal/)
    end
    pending = state.fetch("pending")
    expect(@installation.mutations.where(route_id: "V4-15").count).to eq(0)
    requests = []
    with_runtime(app: observed_app(requests)) do |context, journal|
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    expect(JSON.parse(requests.first).fetch("mutation_id")).to eq(
      pending.fetch("mutation_id")
    )
    expect(requests.length).to eq(2) # recovered history, then fresh token proof
    expect(state.fetch("next_renewal")).to eq(2)
  end

  it "recovers receiver-committed but unretained responses using identical request bytes" do
    lease = nil
    requests = []
    interrupted = false
    app =
      observed_app(requests) do |response|
        unless interrupted
          interrupted = true
          response.last.close if response.last.respond_to?(:close)
          raise "synthetic post-commit transport interruption"
        end
        response
      end
    with_runtime(app: app) do |context, journal|
      lease = claim(context, journal)
      expect {
        authority(context, journal, lease).guard!(operation: :mutate)
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    retained = @installation.mutations.find_by!(route_id: "V4-15")
    expect(retained.state).to eq("pending")
    original = retained.request_ciphertext
    with_runtime(app: app) do |context, journal|
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    expect(requests.length).to eq(3)
    expect(requests[1]).to eq(requests[0])
    expect(retained.reload.request_ciphertext).to eq(original)
    expect(
      DiscussionBridgeCmsMutationReceipt.where(
        content_connection_id: @connection.id,
        route: "renew"
      ).count
    ).to eq(2)
    expect(state.fetch("next_renewal")).to eq(2)
  end

  it "retains a completed response across checkpoint rollback but obtains fresh proof on restart" do
    lease = nil
    requests = []
    app = observed_app(requests)
    with_runtime(app: app) do |context, journal|
      lease = claim(context, journal)
      held = authority(context, journal, lease)
      allow(held).to receive(:advance_fence!).and_raise(
        "synthetic checkpoint interruption"
      )
      expect { held.guard!(operation: :mutate) }.to raise_error(
        /checkpoint interruption/
      )
    end
    expect(state.fetch("pending")).not_to eq(nil)
    expect(@installation.mutations.find_by!(route_id: "V4-15").state).to eq(
      "completed"
    )
    retained_receipts =
      @installation
        .operational_records
        .where(kind: "mutation_receipt")
        .pluck(:id, :encrypted_payload)
        .to_h
    with_runtime(app: app) do |context, journal|
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    expect(requests.length).to eq(2) # cached response not redispatched, fresh renewal is
    retained_receipts.each do |id, encrypted|
      expect(
        DiscussionBridgeGhost::OperationalRecord.find(id).encrypted_payload
      ).to eq(encrypted)
    end
    expect(state.fetch("next_renewal")).to eq(2)
  end

  it "does not treat a parsed wrong token as native authority or rotate away a refusal" do
    requests = []
    with_runtime(app: observed_app(requests)) do |context, journal|
      lease = JSON.parse(JSON.generate(claim(context, journal)))
      lease["lease_token"] = SecureRandom.urlsafe_base64(32, false)
      held = authority(context, journal, lease)
      2.times do
        expect { held.guard!(operation: :mutate) }.to raise_error(
          DiscussionBridgeGhost::Error,
          /renewal has not succeeded/
        )
      end
    end
    expect(requests.length).to eq(1)
    expect(@installation.mutations.where(route_id: "V4-15").sole.state).to eq(
      "refused"
    )
    expect(state.fetch("pending")).not_to eq(nil)
    expect(state.fetch("next_renewal")).to eq(0)
  end

  it "rejects outer/inner generation disagreement without clearing pending intent" do
    requests = []
    app =
      observed_app(requests) do |response|
        body = +""
        response.last.each { |part| body << part }
        value = JSON.parse(body)
        value["lease_generation"] += 1
        response.last.close if response.last.respond_to?(:close)
        [
          response.first,
          { "content-type" => "application/json" },
          [JSON.generate(value)]
        ]
      end
    with_runtime(app: app) do |context, journal|
      lease = claim(context, journal)
      expect {
        authority(context, journal, lease).guard!(operation: :mutate)
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    expect(state.fetch("pending")).not_to eq(nil)
    expect(state.fetch("next_renewal")).to eq(0)
    expect(
      @installation.operational_records.where(kind: "mapping_fence").count
    ).to eq(0)
  end

  it "rejects a well-typed returned token that does not match retained authority" do
    requests = []
    app =
      observed_app(requests) do |response|
        body = +""
        response.last.each { |part| body << part }
        value = JSON.parse(body)
        value["lease_token"] = SecureRandom.urlsafe_base64(32, false)
        response.last.close if response.last.respond_to?(:close)
        [
          response.first,
          { "content-type" => "application/json" },
          [JSON.generate(value)]
        ]
      end
    with_runtime(app: app) do |context, journal|
      lease = claim(context, journal)
      expect {
        authority(context, journal, lease).guard!(operation: :mutate)
      }.to raise_error(DiscussionBridgeGhost::Error, /identity/)
    end
    expect(state.fetch("pending")).not_to eq(nil)
    expect(state.fetch("next_renewal")).to eq(0)
    expect(
      @installation.operational_records.where(kind: "mapping_fence").count
    ).to eq(0)
  end

  it "retains a mapping high-water generation across a different work ID and attempt cycle" do
    old_lease = nil
    with_runtime do |context, journal|
      old_lease = claim(context, journal)
      authority(context, journal, old_lease).guard!(operation: :mutate)
    end
    @work.update!(
      state: "cancelled",
      lease_verifier: nil,
      lease_expires_at: nil
    )
    @mapping.work_items.create!(
      work_id: SecureRandom.uuid,
      attempt_cycle: SecureRandom.uuid,
      action: "publish_revision",
      source_revision: @work.source_revision,
      policy_revision: @work.policy_revision,
      source_snapshot: @snapshot
    )
    with_runtime do |context, journal|
      newer = claim(context, journal, key: "claim:new-work")
      expect(newer.fetch("lease_generation")).to be >
        old_lease.fetch("lease_generation")
      authority(context, journal, newer).guard!(operation: :mutate)
    end
    with_runtime do |context, journal|
      expect { authority(context, journal, old_lease) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect(
      @installation.operational_records.where(kind: "work_authority").count
    ).to eq(2)
  end

  it "does not let synchronized work authorize another write or adopt an unproven native ID" do
    lease = nil
    native_id = "a" * 24
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    # Synthetic synchronized fixture; no native write/public verification claim.
    @work.update!(state: "synchronized")
    @mapping.update!(destination_native_id: native_id)
    with_runtime do |context, journal|
      held = authority(context, journal, lease)
      expect { held.guard!(operation: :mutate) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect { held.guard!(operation: :verify) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(
        held
          .guard!(operation: :verify, native_id: native_id)
          .fetch("mapping")
          .fetch("destination_native_id")
      ).to eq(native_id)
    end
  end

  it "stops when policy is disabled and never claims an automatic withdrawal exception" do
    requests = []
    with_runtime(app: observed_app(requests)) do |context, journal|
      lease = claim(context, journal)
      held = authority(context, journal, lease)
      config = @connection.cms_configuration.deep_dup
      config.fetch("policy")["enabled"] = false
      @connection.update_columns(cms_configuration: config)
      expect { held.guard!(operation: :mutate) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect(requests).to eq([])
    expect(state.fetch("pending")).to eq(nil)
  end

  it "supports current owned withdrawal while publishing remains enabled and the source is ineligible" do
    native_id = "b" * 24
    # Retained local fence precedes this synthetic owned native publication.
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    @work.update!(state: "cancelled")
    @mapping.update!(destination_native_id: native_id)
    config = @connection.cms_configuration.deep_dup
    config.fetch("policy")["exclude_topic_ids"] = [@topic.id.to_s]
    @connection.update_columns(cms_configuration: config)
    withdrawn =
      DiscussionBridge::CmsWorkCoordinator.new(@connection).enqueue!(
        @mapping,
        source_snapshot: nil,
        action: "withdraw"
      )
    with_runtime do |context, journal|
      lease = claim(context, journal, key: "claim:withdrawal")
      expect(lease.fetch("work").fetch("work_id")).to eq(withdrawn.work_id)
      expect(lease.fetch("work").fetch("source_revision")).to eq(nil)
      expect(
        authority(context, journal, lease)
          .guard!(operation: :mutate)
          .fetch("work")
          .fetch("action")
      ).to eq("withdraw")
    end
  end

  it "recomputes remaining budget after its own current-state reads" do
    requests = []
    app =
      observed_app(requests) do |response|
        freeze_time(290.seconds.from_now)
        response
      end
    with_runtime(app: app) do |context, journal|
      lease = claim(context, journal)
      expect {
        authority(context, journal, lease).guard!(operation: :mutate)
      }.to raise_error(DiscussionBridgeGhost::Error, /authority/)
    end
    expect(state.fetch("pending")).to eq(nil)
    expect(state.fetch("last_lease")).not_to eq(nil)
  end

  it "never resets an expired replay's lifetime after a checkpoint interruption" do
    lease = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      held = authority(context, journal, lease)
      allow(held).to receive(:advance_fence!).and_raise(
        "synthetic checkpoint interruption"
      )
      expect { held.guard!(operation: :mutate) }.to raise_error(
        /checkpoint interruption/
      )
    end
    original_expiry =
      @installation.mutations.find_by!(route_id: "V4-15").private_response
    freeze_time(301.seconds.from_now)
    with_runtime do |context, journal|
      expect {
        authority(context, journal, lease).guard!(operation: :mutate)
      }.to raise_error(
        DiscussionBridgeGhost::Error,
        /renewal has not succeeded/
      )
    end
    expect(@installation.mutations.where(route_id: "V4-15").count).to eq(2)
    expect(Time.iso8601(state.fetch("last_lease").fetch("expires_at"))).to be <
      Time.current
    expect(
      @installation
        .mutations
        .where(route_id: "V4-15")
        .order(:id)
        .first
        .private_response
    ).to eq(original_expiry)
  end

  it "honors a retained renewal cooldown before replay and fresh receiver proof" do
    requests = []
    limited = true
    app =
      lambda do |env|
        if env.fetch("PATH_INFO").end_with?("/renew.json") && limited
          requests << env.fetch("rack.input").read
          [
            429,
            { "content-type" => "application/json" },
            [
              JSON.generate(
                "outcome" => "rejected",
                "code" => "rate_limited",
                "retryable" => true,
                "retry_after_seconds" => 10,
                "correlation_id" => nil,
                "core_fallback" => false
              )
            ]
          ]
        else
          observed_app(requests).call(env)
        end
      end
    with_runtime(app: app) do |context, journal|
      lease = claim(context, journal)
      held = authority(context, journal, lease)
      2.times do
        expect { held.guard!(operation: :mutate) }.to raise_error(
          DiscussionBridgeGhost::Error,
          /renewal has not succeeded/
        )
      end
      expect(requests.length).to eq(1)
      pending = state.fetch("pending")
      limited = false
      freeze_time(11.seconds.from_now)
      held.guard!(operation: :mutate)
      expect(JSON.parse(requests[1]).fetch("mutation_id")).to eq(
        pending.fetch("mutation_id")
      )
      expect(requests[1]).to eq(requests[0])
      expect(requests.length).to eq(3)
    end
  end

  %w[policy direction destination].each do |change|
    it "stops when the remote #{change} binding changes" do
      requests = []
      with_runtime(app: observed_app(requests)) do |context, journal|
        lease = claim(context, journal)
        held = authority(context, journal, lease)
        config = @connection.cms_configuration.deep_dup
        case change
        when "policy"
          config.fetch("policy")["policy_revision"] = SecureRandom.uuid
          @connection.update_columns(cms_configuration: config)
        when "direction"
          @connection.update_columns(allowed_directions: ["to_discourse"])
        when "destination"
          config["destination_origin"] = "https://different-native.example"
          @connection.update_columns(
            cms_configuration: config,
            allowed_origins: ["https://different-native.example"]
          )
        end
        expect { held.guard!(operation: :mutate) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        expect(requests).to eq([])
      end
    end
  end

  it "rejects a journal belonging to another execution context before retaining work" do
    with_runtime do |context, journal|
      lease = claim(context, journal)
      expect {
        described_class.new(
          context: context,
          journal: Object.new,
          lease: lease,
          mapping: {
          },
          scope_revision: "synthetic"
        )
      }.to raise_error(DiscussionBridgeGhost::Error, /identity/)
    end
    expect(
      @installation.operational_records.where(kind: "work_authority").count
    ).to eq(0)
  end

  it "rejects local revision changes and transaction nesting" do
    with_runtime do |context, journal|
      lease = claim(context, journal)
      held = authority(context, journal, lease)
      @installation.update!(configuration_revision: 2)
      expect { held.guard!(operation: :mutate) }.to raise_error(
        DiscussionBridgeGhost::Error,
        /disabled/
      )
    end
    with_runtime do |context, journal|
      lease = claim(context, journal)
      ActiveRecord::Base.transaction do
        expect { authority(context, journal, lease) }.to raise_error(
          DiscussionBridgeGhost::Error,
          /enclosing/
        )
        raise ActiveRecord::Rollback
      end
    end
  end

  it "rejects non-object restored checkpoints without rewriting history or dispatching renewal" do
    lease = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease)
    end
    row = @installation.operational_records.find_by!(kind: "work_authority")
    [nil, false, true, [], "not-a-checkpoint", 7].each do |malformed|
      rewrite_record(row, malformed)
      before = retained_evidence
      requests = []
      with_runtime(app: observed_app(requests)) do |context, journal|
        expect { authority(context, journal, lease) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
      end
      expect(requests).to eq([])
      expect(retained_evidence).to eq(before)
    end
  end

  it "requires exact nullable object types and counter/last-lease consistency" do
    lease = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    row = @installation.operational_records.find_by!(kind: "work_authority")
    original = row.private_payload
    malformed_states = []
    %w[pending last_lease].each do |field|
      [false, true, [], "not-an-object", 1].each do |value|
        malformed_states << original.deep_dup.merge(field => value)
      end
    end
    malformed_states << original.deep_dup.merge("last_lease" => nil)
    malformed_states << original.deep_dup.merge("next_renewal" => 0)
    malformed_states.each do |malformed|
      rewrite_record(row, malformed)
      before = retained_evidence
      requests = []
      with_runtime(app: observed_app(requests)) do |context, journal|
        expect { authority(context, journal, lease) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
      end
      expect(requests).to eq([])
      expect(retained_evidence).to eq(before)
    end
  end

  it "validates an older fence's complete identity before a higher generation can supersede it" do
    lease = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    next_work!
    newer = nil
    with_runtime do |context, journal|
      newer = claim(context, journal, key: "claim:higher-for-corruption-check")
    end
    row = @installation.operational_records.find_by!(kind: "mapping_fence")
    original = row.private_payload
    expect(newer.fetch("lease_generation")).to be > original.fetch("generation")
    malformed_fences = [nil, false, [], "not-a-fence"]
    [nil, false, [], "not-an-identity", {}].each do |identity|
      malformed_fences << original.deep_dup.merge("identity" => identity)
    end
    {
      "mapping_id" => SecureRandom.uuid,
      "source_id" => "topic:wrong-source",
      "lease_generation" => original.fetch("generation") + 1,
      "work_id" => "not-a-uuid",
      "attempt_cycle" => "not-a-cycle",
      "attempt" => 0,
      "action" => "not-an-action",
      "source_revision" => nil,
      "policy_revision" => false
    }.each do |field, value|
      malformed = original.deep_dup
      malformed.fetch("identity")[field] = value
      malformed_fences << malformed
    end
    malformed_fences << original.deep_dup.merge("generation" => 0)
    malformed = original.deep_dup
    malformed.fetch("binding")["connection_id"] = "dbc_#{SecureRandom.hex(12)}"
    malformed_fences << malformed
    malformed_fences.each do |value|
      rewrite_record(row, value)
      before = retained_evidence
      requests = []
      with_runtime(app: observed_app(requests)) do |context, journal|
        expect { authority(context, journal, newer) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
      end
      expect(requests).to eq([])
      expect(retained_evidence).to eq(before)
    end
  end

  it "rejects a missing fence contradicted by completed local checkpoint history" do
    lease = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    @installation.operational_records.find_by!(kind: "mapping_fence").delete
    before = retained_evidence
    requests = []
    with_runtime(app: observed_app(requests)) do |context, journal|
      expect { authority(context, journal, lease) }.to raise_error(
        DiscussionBridgeGhost::Error,
        /identity/
      )
    end
    expect(requests).to eq([])
    expect(retained_evidence).to eq(before)
  end

  it "rejects a missing prior fence for a new work item with an already-owned native ID" do
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    @mapping.update!(destination_native_id: "a" * 24)
    next_work!
    newer = nil
    with_runtime do |context, journal|
      newer = claim(context, journal, key: "claim:owned-native-missing-fence")
    end
    @installation.operational_records.find_by!(kind: "mapping_fence").delete
    before = retained_evidence
    requests = []
    with_runtime(app: observed_app(requests)) do |context, journal|
      expect { authority(context, journal, newer) }.to raise_error(
        DiscussionBridgeGhost::Error,
        /identity/
      )
    end
    expect(requests).to eq([])
    expect(retained_evidence).to eq(before)
  end

  it "rejects a different work identity at the same retained mapping generation" do
    lease = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease).guard!(operation: :mutate)
    end
    conflicting = JSON.parse(JSON.generate(lease))
    conflicting.fetch("work")["work_id"] = SecureRandom.uuid
    before = retained_evidence
    requests = []
    with_runtime(app: observed_app(requests)) do |context, journal|
      expect { authority(context, journal, conflicting) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect(requests).to eq([])
    expect(retained_evidence).to eq(before)
  end

  [false, true].each do |legacy|
    it "rejects cross-work missing-fence history with #{legacy ? "legacy NULL" : "indexed"} mapping metadata" do
      with_runtime do |context, journal|
        lease = claim(context, journal)
        authority(context, journal, lease).guard!(operation: :mutate)
      end
      previous =
        @installation.operational_records.find_by!(kind: "work_authority")
      previous.update_columns(mapping_public_id: nil) if legacy
      previous_ciphertext = previous.reload.encrypted_payload
      next_work!
      newer = nil
      with_runtime do |context, journal|
        newer = claim(context, journal, key: "claim:cross-work-null-native")
      end
      expect(@mapping.reload.destination_native_id).to eq(nil)
      @installation.operational_records.find_by!(kind: "mapping_fence").delete
      before = retained_evidence
      requests = []
      with_runtime(app: observed_app(requests)) do |context, journal|
        expect { authority(context, journal, newer) }.to raise_error(
          DiscussionBridgeGhost::Error,
          /identity/
        )
      end
      expect(requests).to eq([])
      expect(previous.reload.encrypted_payload).to eq(previous_ciphertext)
      expect(previous.mapping_public_id).to eq(
        legacy ? nil : @mapping.mapping_id
      )
      expect(retained_evidence).to eq(before)
    end
  end

  it "permits a later same-mapping work item when retained earlier work never completed a guard" do
    previous = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease)
      previous =
        @installation.operational_records.find_by!(kind: "work_authority")
    end
    expect(previous.private_payload.fetch("next_renewal")).to eq(0)
    original = previous.encrypted_payload
    next_work!
    requests = []
    with_runtime(app: observed_app(requests)) do |context, journal|
      newer = claim(context, journal, key: "claim:never-completed-predecessor")
      expect(
        authority(context, journal, newer)
          .guard!(operation: :mutate)
          .fetch("work")
          .fetch("work_id")
      ).to eq(newer.fetch("work").fetch("work_id"))
    end
    expect(requests.length).to eq(1)
    expect(previous.reload.encrypted_payload).to eq(original)
  end

  [false, true].each do |legacy|
    it "permits first use with valid #{legacy ? "legacy NULL" : "indexed"} successful history for another mapping" do
      with_runtime do |context, journal|
        lease = claim(context, journal)
        held = authority(context, journal, lease)
        historical = state.deep_dup
        old_identity =
          historical.fetch("identity").merge(
            "work_id" => SecureRandom.uuid,
            "mapping_id" => SecureRandom.uuid,
            "source_id" => "topic:other-synthetic-source",
            "attempt_cycle" => SecureRandom.uuid
          )
        historical["identity"] = old_identity
        historical["mapping"].merge!(
          "mapping_id" => old_identity.fetch("mapping_id"),
          "source_id" => old_identity.fetch("source_id"),
          "resource_id" => SecureRandom.uuid,
          "external_id" => "other-article",
          "canonical_url" => "#{@target.ghost_origin}/other-article/"
        )
        historical["authority"].merge!(
          old_identity.slice(
            "work_id",
            "source_revision",
            "policy_revision",
            "lease_generation"
          )
        )
        historical["next_renewal"] = 1
        historical["last_lease"] = JSON.parse(JSON.generate(lease))
        historical.fetch("last_lease").fetch("work").merge!(old_identity)
        key =
          "#{old_identity.fetch("work_id")}:#{old_identity.fetch("lease_generation")}"
        row =
          @installation.operational_records.create!(
            kind: "work_authority",
            record_key: key,
            mapping_public_id: legacy ? nil : old_identity.fetch("mapping_id"),
            encrypted_payload:
              @installation.envelope.encrypt(
                "operational_record",
                historical,
                binding: JSON.generate(["work_authority", key])
              )
          )
        original = row.encrypted_payload
        expect(
          held.guard!(operation: :mutate).fetch("mapping").fetch("mapping_id")
        ).to eq(@mapping.mapping_id)
        expect(row.reload.encrypted_payload).to eq(original)
        expect(row.mapping_public_id).to eq(
          legacy ? nil : old_identity.fetch("mapping_id")
        )
      end
    end
  end

  it "does not decrypt unrelated indexed mapping history during ordinary first use" do
    row =
      @installation.operational_records.create!(
        kind: "work_authority",
        record_key: "#{SecureRandom.uuid}:1",
        mapping_public_id: SecureRandom.uuid,
        encrypted_payload: "SYNTHETIC-other-mapping-unreadable"
      )
    with_runtime do |context, journal|
      lease = claim(context, journal)
      expect(
        authority(context, journal, lease)
          .guard!(operation: :mutate)
          .fetch("work")
          .fetch("work_id")
      ).to eq(@work.work_id)
    end
    expect(row.reload.encrypted_payload).to eq(
      "SYNTHETIC-other-mapping-unreadable"
    )
  end

  it "rejects ambiguous malformed legacy history without creating or retagging records" do
    key = "#{SecureRandom.uuid}:1"
    row =
      @installation.operational_records.create!(
        kind: "work_authority",
        record_key: key,
        mapping_public_id: nil,
        encrypted_payload:
          @installation.envelope.encrypt(
            "operational_record",
            false,
            binding: JSON.generate(["work_authority", key])
          )
      )
    with_runtime do |context, journal|
      lease = claim(context, journal)
      before = retained_evidence
      expect { authority(context, journal, lease) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(retained_evidence).to eq(before)
    end
    expect(row.reload.mapping_public_id).to eq(nil)
  end

  it "does not trust a current record's locator over its encrypted mapping identity" do
    lease = nil
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease)
    end
    row = @installation.operational_records.find_by!(kind: "work_authority")
    row.update_columns(mapping_public_id: SecureRandom.uuid) # synthetic malformed restored metadata
    before = retained_evidence
    with_runtime do |context, journal|
      expect { authority(context, journal, lease) }.to raise_error(
        DiscussionBridgeGhost::Error,
        /identity/
      )
    end
    expect(retained_evidence).to eq(before)
  end

  it "has a nullable indexed locator without permitting normal rebinding or changing ciphertext" do
    column =
      DiscussionBridgeGhost::OperationalRecord.columns_hash.fetch(
        "mapping_public_id"
      )
    expect(column.type).to eq(:uuid)
    expect(column.null).to eq(true)
    index =
      ActiveRecord::Base
        .connection
        .indexes("discussion_bridge_ghost_records")
        .find { |entry| entry.name == "idx_db_ghost_record_mapping" }
    expect(index.columns).to eq(%w[installation_id kind mapping_public_id])
    expect(index.unique).to eq(false)
    with_runtime do |context, journal|
      lease = claim(context, journal)
      authority(context, journal, lease)
    end
    row = @installation.operational_records.find_by!(kind: "work_authority")
    original = row.encrypted_payload
    expect(row.update(mapping_public_id: SecureRandom.uuid)).to eq(false)
    expect(row.reload.mapping_public_id).to eq(@mapping.mapping_id)
    expect(row.encrypted_payload).to eq(original)
    receipt =
      @installation.operational_records.find_by!(kind: "mutation_receipt")
    expect(receipt.mapping_public_id).to eq(nil)
    expect(
      receipt.private_payload.fetch("binding").fetch("connection_id")
    ).to eq(@connection.public_id)
  end
end
