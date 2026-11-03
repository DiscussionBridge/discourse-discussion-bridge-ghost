# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/discussion_bridge_ghost/native_command_journal"
require_relative "../../lib/discussion_bridge_ghost/native_executor"

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
        candidate: fields
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
