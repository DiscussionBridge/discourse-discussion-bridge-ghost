# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/discussion_bridge_ghost/source_intake"

RSpec.describe DiscussionBridgeGhost::SourceIntake do
  self.use_transactional_tests = false

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.discussion_bridge_ghost_enabled = true
    SiteSetting.force_https = true
    SiteSetting.login_required = false
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(
      :wake_connection
    ).and_return(false)
    origin = "https://ghost-intake-#{SecureRandom.hex(8)}.example"
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Synthetic Ghost source intake",
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
          "native_revision" => "native:synthetic-intake",
          "supported_presentations" => %w[simple full interactive],
          "publication_kind" => "dynamic",
          "complete_content_supported" => true
        },
        "policy" => {
          "policy_revision" => SecureRandom.uuid,
          "enabled" => true,
          "selection" => "categories",
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
    @category = Fabricate(:category)
    config = @connection.cms_configuration.deep_dup
    config["policy"]["category_ids"] = [@category.id.to_s]
    @connection.update!(cms_configuration: config)
    @topic = Fabricate(:topic, category: @category)
    # The first chunk ends INSIDE a multibyte character, not at a text boundary.
    @html = "<p>" + "a" * 32_764 + "🌉" * 9000 + "</p>"
    @post =
      Fabricate(
        :post,
        topic: @topic,
        post_number: 1,
        raw: "Synthetic complete content",
        cooked: @html
      )
    DiscussionBridge::CmsSourceStore.new(@connection).refresh_all!
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
  end

  after do
    if @installation&.persisted?
      @installation.operational_records.delete_all
      @installation.delete
    end
    @target.delete if @target&.persisted?
    @connection.delete if @connection&.persisted?
  end

  def runtime(app: Rails.application)
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
          installation: @installation.reload,
          protocol: protocol,
          transport: transport,
          lease: lock
        )
      yield described_class.new(context: context), context
    end
  end

  def stage(intake)
    page = intake.advance
    expect(page.fetch("stream")).to eq("initial")
    item =
      page
        .fetch("items")
        .find { |entry| entry.dig("source", "topic_id") == @topic.id.to_s }
    expect(item).to be_present
    item.fetch("event_id")
  end

  def rewrite(record)
    value = record.private_payload
    yield value
    record.update!(
      encrypted_payload:
        @installation.envelope.encrypt(
          "operational_record",
          value,
          binding: JSON.generate([record.kind, record.record_key])
        )
    )
  end

  def modified_responses(&modify)
    lambda do |env|
      status, headers, body = Rails.application.call(env)
      text = +""
      body.each { |part| text << part }
      body.close if body.respond_to?(:close)
      if status == 200 && env.fetch("PATH_INFO").end_with?("/content.json")
        value = JSON.parse(text)
        modify.call(value)
        text = JSON.generate(value)
        headers = headers.except("content-length", "Content-Length")
      end
      [status, headers, [text]]
    end
  end

  it "stages the actual scoped feed and resumes complete binary chunks after a new run" do
    id = nil
    runtime do |intake, _context|
      id = stage(intake)
      expect(intake.source(id).fetch("title")).to eq(@topic.title)
      expect(intake.source(id)).to be_frozen
      expect(intake.advance_content(id)).to include(
        "complete" => false,
        "offset" => 32_768
      )
      expect { intake.content(id) }.to raise_error(DiscussionBridgeGhost::Error)
    end
    runtime do |intake, _context|
      expect(intake.advance_content(id, chunk_budget: 2)).to include(
        "complete" => true
      )
      expect(intake.content(id)).to eq(@html)
      expect(intake.content(id).encoding).to eq(Encoding::UTF_8)
      expect(intake.content(id)).to be_frozen
      changes = intake.advance
      expect(changes.fetch("stream")).to eq("changes")
      expect(changes.fetch("items")).to eq([])
    end
    encrypted = @installation.operational_records.pluck(:encrypted_payload).join
    expect(encrypted).not_to include(@html, @topic.title, @secret)
    expect(
      DiscussionBridgeGhost::Mutation.where(installation_id: @installation.id)
    ).not_to exist
  end

  it "rolls back every event and source when the page cursor cannot commit" do
    runtime do |intake, _context|
      allow(intake).to receive(
        :write
      ).and_wrap_original do |original, kind, key, value|
        if kind == described_class::STATE
          raise DiscussionBridgeGhost::Error.new("identity_conflict")
        end
        original.call(kind, key, value)
      end
      expect { intake.advance }.to raise_error(DiscussionBridgeGhost::Error)
      expect(@installation.operational_records.count).to eq(0)
    end
    runtime { |intake, _context| stage(intake) }
    expect(
      @installation
        .operational_records
        .where(kind: described_class::EVENT)
        .count
    ).to eq(1)
  end

  it "preserves an invalidated cursor and staged content instead of silently restarting" do
    runtime do |intake, _context|
      stage(intake)
      retained =
        @installation.operational_records.order(:id).pluck(:encrypted_payload)
      config = @connection.reload.cms_configuration.deep_dup
      config["policy"]["policy_revision"] = SecureRandom.uuid
      @connection.update!(cms_configuration: config)
      expect { intake.advance }.to raise_error(
        described_class::Unavailable
      ) { |error| expect(error.receiver_code).to eq("cursor_scope_changed") }
      expect(
        @installation.operational_records.order(:id).pluck(:encrypted_payload)
      ).to eq(retained)
    end
  end

  it "does not return previously cached content after the source becomes private" do
    runtime do |intake, _context|
      id = stage(intake)
      intake.advance_content(id, chunk_budget: 3)
      expect(intake.content(id)).to eq(@html)
      private_category = Fabricate(:private_category)
      @topic.update!(category: private_category)
      expect { intake.content(id) }.to raise_error(described_class::Unavailable)
      expect(intake.source(id).fetch("content_sha256")).to eq(
        Digest::SHA256.hexdigest(@html)
      )
      expect(
        @installation
          .operational_records
          .where(kind: described_class::CHUNK)
          .count
      ).to eq(3)
    end
  end

  it "retains source identity across an updated source and a revocation" do
    runtime do |intake, _context|
      old_id = stage(intake)
      old = intake.source(old_id)
      @post.update!(
        cooked: "<p>Updated synthetic source.</p>",
        version: @post.version + 1
      )
      DiscussionBridge::CmsSourceStore.new(@connection).refresh_topic!(
        @topic.id
      )
      changed = intake.advance.fetch("items")
      id = changed.fetch(0).fetch("event_id")
      expect(intake.source(id).fetch("source_id")).to eq(old.fetch("source_id"))
      expect(intake.source(id).fetch("source_revision")).not_to eq(
        old.fetch("source_revision")
      )
      expect(intake.source(old_id)).to eq(old)
      @topic.update!(deleted_at: Time.current)
      DiscussionBridge::CmsSourceStore.new(@connection).refresh_topic!(
        @topic.id
      )
      revoked = intake.advance.fetch("items").fetch(0)
      expect(revoked.fetch("event_type")).to eq("revocation")
      expect(intake.event(revoked.fetch("event_id"))).to eq(revoked)
      expect { intake.source(revoked.fetch("event_id")) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
  end

  it "rejects a configured size budget before requesting or saving any body" do
    runtime do |intake, _context|
      id = stage(intake)
      expect { intake.advance_content(id, maximum_bytes: 100) }.to raise_error(
        DiscussionBridgeGhost::Error,
        /complete source exceeds/
      )
      expect(
        @installation.operational_records.where(kind: described_class::CHUNK)
      ).not_to exist
    end
  end

  it "rejects a chunk with a changed revision, offset, count or digest" do
    %w[source_revision offset content_bytes content_sha256].each do |field|
      app =
        modified_responses do |value|
          value[field] = case field
          when "source_revision"
            "revision:forged"
          when "content_sha256"
            "0" * 64
          else
            value.fetch(field) + 1
          end
        end
      runtime(app: app) do |intake, _context|
        id =
          @installation
            .operational_records
            .where(kind: described_class::EVENT)
            .first
            &.record_key || stage(intake)
        expect { intake.advance_content(id) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        expect(
          @installation.operational_records.where(kind: described_class::CHUNK)
        ).not_to exist
      end
    end
  end

  it "refuses hash-corrupted complete content without marking the last chunk complete" do
    app =
      modified_responses do |value|
        if value.fetch("offset") == 0
          bytes = Base64.strict_decode64(value.fetch("content_base64"))
          bytes.setbyte(4, 98)
          value["content_base64"] = Base64.strict_encode64(bytes)
        end
      end
    runtime(app: app) do |intake, _context|
      id = stage(intake)
      expect { intake.advance_content(id, chunk_budget: 3) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      record =
        @installation.operational_records.find_by!(
          kind: described_class::PROGRESS
        )
      expect(record.private_payload.dig("value", "progress")).to include(
        "complete" => false,
        "offset" => 65_536
      )
      expect { intake.content(id) }.to raise_error(DiscussionBridgeGhost::Error)
    end
  end

  it "refuses transplanted or edited protected source identity" do
    runtime do |intake, _context|
      id = stage(intake)
      record =
        @installation.operational_records.find_by!(
          kind: described_class::SOURCE
        )
      rewrite(record) do |value|
        value.fetch("value").fetch("source")["title"] = "Changed outside intake"
      end
      expect { intake.source(id) }.to raise_error(DiscussionBridgeGhost::Error)
    end
  end

  it "does not treat GET query support as mutation authority" do
    runtime do |_intake, context|
      expect { context.read("V4-13") }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect {
        context.read("V4-07", query: { "unexpected" => "value" })
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(
        DiscussionBridgeGhost::Mutation.where(installation_id: @installation.id)
      ).not_to exist
    end
  end
end
