# frozen_string_literal: true

require "rails_helper"

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
      lease["lease_token"] = "SYNTHETIC-wrong-token-#{"x" * 24}"
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
        value["lease_token"] = "y" * 43
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
      lease = claim(context, journal)
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
        freeze_time(Time.current + 290.seconds)
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
    freeze_time(Time.current + 301.seconds)
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
      freeze_time(Time.current + 11.seconds)
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
end
