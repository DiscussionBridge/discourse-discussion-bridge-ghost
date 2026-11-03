# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/discussion_bridge_ghost/native_command_journal"

RSpec.describe DiscussionBridgeGhost::NativeCommandJournal do
  self.use_transactional_tests = false

  around do |example|
    base = Class.new(ActiveRecord::Base) { self.abstract_class = true }
    stub_const(Object, :GhostNativeIntentObserver, base) do
      begin
        base.establish_connection(
          ActiveRecord::Base.connection_db_config.configuration_hash.merge(
            pool: 1
          )
        )
        @observer_pool = base.connection_pool
        example.run
      ensure
        begin
          Array(@installations).each do |installation|
            DiscussionBridgeGhost::OperationalRecord.where(
              installation_id: installation.id
            ).delete_all
            installation.delete
          end
          Array(@targets).each(&:delete)
        ensure
          @observer_pool&.disconnect!
          base.remove_connection
        end
      end
    end
  end

  before do
    SiteSetting.discussion_bridge_ghost_enabled = true
    SiteSetting.force_https = true
    @targets, @installations = [], []
    @installation = make_installation
    @clock = Time.utc(2026, 11, 3, 18)
  end

  def make_installation(target = nil)
    unless target
      suffix = SecureRandom.hex(8)
      target =
        DiscussionBridgeGhost::NativeTarget.create!(
          public_id: SecureRandom.uuid,
          ghost_origin: "https://ghost-native-#{suffix}.example",
          admin_origin: "https://ghost-admin-#{suffix}.example"
        )
      @targets << target
    end
    id = SecureRandom.uuid
    envelope =
      DiscussionBridgeGhost::SecretEnvelope.new(
        application_key: Rails.application.secret_key_base,
        installation_id: id
      )
    installation =
      DiscussionBridgeGhost::Installation.create!(
        native_target: target,
        public_id: id,
        enabled: true,
        connection_public_id: "dbc_#{SecureRandom.hex(12)}",
        encrypted_configuration:
          envelope.encrypt(
            "configuration",
            { "key" => "SYNTHETIC-private-configuration" }
          )
      )
    @installations << installation
    installation
  end

  def with_journal(installation = @installation)
    DiscussionBridgeGhost::NativeLock.synchronize(
      installation.native_target.public_id
    ) do |lease|
      protocol = DiscussionBridgeGhost::WireProtocol.new
      transport =
        DiscussionBridgeGhost::RackTransport.new(
          protocol: protocol,
          connection_id: installation.connection_public_id,
          connection_secret: "SYNTHETIC-#{"x" * 40}",
          app: ->(_env) { [204, {}, []] },
          base_url: Discourse.base_url
        )
      context =
        DiscussionBridgeGhost::ExecutionContext.new(
          installation: installation.reload,
          protocol: protocol,
          transport: transport,
          lease: lease
        )
      yield described_class.new(context: context, now: -> { @clock }), context
    end
  end

  def native_http(context, guard: -> {})
    DiscussionBridgeGhost::GhostHttp.new(
      protocol: context.protocol,
      origin: context.installation.native_target.admin_origin,
      guard: guard,
      api_key: "a" * 24 + ":" + "12" * 32
    )
  end

  def arguments(action: "create_draft")
    create = action == "create_draft"
    native_id = create ? nil : "a" * 24
    fields = {
      "slug" => "retained-native-command",
      "title" => "Private native command",
      "status" => create ? "draft" : "published"
    }
    baseline =
      (
        if create
          nil
        else
          {
            "id" => native_id,
            "slug" => fields.fetch("slug"),
            "updated_at" => "2026-11-03T10:00:00.000Z",
            "lexical" => "SYNTHETIC-unrelated-lexical"
          }
        end
      )
    unless create
      fields["id"] = native_id
      fields["updated_at"] = baseline.fetch("updated_at")
    end
    {
      command_id: SecureRandom.uuid,
      identity: {
        "resource_id" => SecureRandom.uuid,
        "kind" => "post",
        "native_id" => native_id
      },
      owner: {
        "direction" => "from_discourse",
        "action" => action,
        "mapping_id" => SecureRandom.uuid,
        "work_id" => SecureRandom.uuid,
        "generation" => 2,
        "source_revision" => "post:24:version:1",
        "external_id" => "native-target-one",
        "move_id" => nil
      },
      request: {
        "method" => create ? "POST" : "PUT",
        "path" => "/ghost/api/admin/posts/#{create ? "" : "#{native_id}/"}",
        "body_bytes" => " #{JSON.generate("posts" => [fields])}\n",
        "maximum_bytes" => 262_144,
        "allowed_statuses" => create ? [201] : [200]
      },
      baseline: baseline,
      candidate: fields
    }
  end

  def send_command(http, command, attempt)
    request = command.fetch("request")
    http.request(
      request.fetch("method"),
      request.fetch("path"),
      retained_body: request.fetch("body_bytes"),
      maximum_bytes: request.fetch("maximum_bytes"),
      authenticated: true,
      allowed_statuses: request.fetch("allowed_statuses"),
      dispatch: attempt
    )
  end

  def row(kind, id)
    @installation.operational_records.find_by!(kind: kind, record_key: id)
  end

  def encrypted_snapshot
    @installation
      .operational_records
      .order(:id)
      .pluck(:id, :kind, :record_key, :encrypted_payload)
  end

  it "commits exact intent and attempt before HTTP and retains responses without declaring publication success" do
    args = arguments
    command = nil
    with_journal do |journal, context|
      command = journal.prepare(**args)
      request =
        stub_request(
          :post,
          @installation.native_target.admin_origin +
            command.dig("request", "path")
        )
          .with(body: args.dig(:request, "body_bytes")) do
            @observer_pool.with_connection do |connection|
              expect(
                connection.select_value(
                  "SELECT count(*) FROM discussion_bridge_ghost_records WHERE installation_id = #{@installation.id} AND kind = 'native_command'"
                ).to_i
              ).to eq(1)
              progress =
                connection.select_value(
                  "SELECT encrypted_payload FROM discussion_bridge_ghost_records WHERE installation_id = #{@installation.id} AND kind = 'native_progress'"
                )
              state =
                @installation.envelope.decrypt(
                  "operational_record",
                  progress,
                  binding:
                    JSON.generate(["native_progress", args.fetch(:command_id)])
                )
              expect(state.fetch("pending_attempt")).not_to eq(nil)
            end
            true
          end
          .to_return(
            status: 201,
            headers: {
              "Content-Type" => "application/json"
            },
            body: '{"posts":[]}'
          )
      http = native_http(context)
      attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
      response = send_command(http, command, attempt)
      journal.retain_dispatch(
        args.fetch(:command_id),
        attempt: attempt,
        http: http,
        outcome: response
      )
      retained = journal.retained(args.fetch(:command_id))
      expect(retained.dig("command", "request", "body_bytes")).to eq(
        args.dig(:request, "body_bytes")
      )
      expect(retained.dig("state", "event_count")).to eq(2)
      expect(retained.dig("state", "dispatch_recorded")).to eq(true)
      expect(retained.dig("state", "pending_attempt")).to eq(attempt)
      expect {
        journal.begin_attempt(args.fetch(:command_id), http: http)
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(request).to have_been_requested.once
      expect(retained.inspect).not_to include("native_success")
    end
    expect(
      row("native_command", args.fetch(:command_id)).encrypted_payload
    ).not_to include("Private native command")
  end

  it "reopens identical command bytes but refuses changed owner, baseline, candidate or request without erasing history" do
    args = arguments(action: "publish")
    with_journal do |journal, _context|
      original = journal.prepare(**args)
      before = encrypted_snapshot
      @clock += 30
      expect(journal.prepare(**args)).to eq(original)
      [
        args.merge(owner: args.fetch(:owner).merge("generation" => 3)),
        args.merge(
          baseline: args.fetch(:baseline).merge("lexical" => "changed")
        ),
        args.merge(
          candidate: args.fetch(:candidate).merge("title" => "changed")
        ),
        args.merge(
          request:
            args.fetch(:request).merge(
              "body_bytes" => args.dig(:request, "body_bytes").strip
            )
        )
      ].each do |changed|
        expect { journal.prepare(**changed) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        expect(encrypted_snapshot).to eq(before)
      end
    end
  end

  it "allows only a new attempt after genuine retained no-send, not a new command or an automatic transport retry" do
    args = arguments
    with_journal do |journal, context|
      command = journal.prepare(**args)
      deny = true
      http =
        native_http(
          context,
          guard: -> do
            raise DiscussionBridgeGhost::Error.new("disabled") if deny
          end
        )
      first = journal.begin_attempt(args.fetch(:command_id), http: http)
      error = nil
      expect { send_command(http, command, first) }.to raise_error(
        DiscussionBridgeGhost::Error
      ) { |value| error = value }
      journal.retain_dispatch(
        args.fetch(:command_id),
        attempt: first,
        http: http,
        outcome: error
      )
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "state",
          "pending_attempt"
        )
      ).to eq(nil)
      deny = false
      second = journal.begin_attempt(args.fetch(:command_id), http: http)
      expect(second.fetch("attempt_id")).not_to eq(first.fetch("attempt_id"))
      before = encrypted_snapshot
      expect {
        journal.retain_dispatch(
          args.fetch(:command_id),
          attempt: first,
          http: http,
          outcome: error
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(encrypted_snapshot).to eq(before)
    end
  end

  it "keeps a crash after dispatch-started uncertain across reconstruction and never infers no-send from empty discovery" do
    args = arguments
    execution = nil
    with_journal do |journal, context|
      journal.prepare(**args)
      journal.begin_attempt(args.fetch(:command_id), http: native_http(context))
      execution = context.execution_id
    end
    with_journal do |journal, context|
      expect(context.execution_id).not_to eq(execution)
      journal.observe(
        args.fetch(:command_id),
        { "both_kind_lookup" => [], "candidate_equal" => true }
      )
      expect {
        journal.begin_attempt(
          args.fetch(:command_id),
          http: native_http(context)
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "state",
          "pending_attempt",
          "execution_id"
        )
      ).to eq(execution)
      replacement =
        args.merge(
          command_id: SecureRandom.uuid,
          owner:
            args.fetch(:owner).merge(
              "work_id" => SecureRandom.uuid,
              "generation" => 3
            )
        )
      expect { journal.prepare(**replacement) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
  end

  it "does not repeat a timed-out native create when a delayed matching draft appears" do
    args = arguments
    with_journal do |journal, context|
      command = journal.prepare(**args)
      request =
        stub_request(
          :post,
          @installation.native_target.admin_origin +
            command.dig("request", "path")
        ).to_timeout
      http = native_http(context)
      attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
      error = nil
      expect { send_command(http, command, attempt) }.to raise_error(
        DiscussionBridgeGhost::GhostHttp::Failure
      ) { |value| error = value }
      journal.retain_dispatch(
        args.fetch(:command_id),
        attempt: attempt,
        http: http,
        outcome: error
      )
      journal.observe(args.fetch(:command_id), { "both_kind_lookup" => [] })
      journal.observe(
        args.fetch(:command_id),
        {
          "unique_pending_draft" => command.fetch("candidate"),
          "native_id" => "b" * 24
        }
      )
      expect {
        journal.begin_attempt(args.fetch(:command_id), http: http)
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(request).to have_been_requested.once
    end
  end

  it "rejects forged, cross-client and wrong-attempt dispatch evidence without changing retained intent" do
    args = arguments
    with_journal do |journal, context|
      command = journal.prepare(**args)
      http =
        native_http(
          context,
          guard: -> { raise DiscussionBridgeGhost::Error.new("disabled") }
        )
      attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
      error = nil
      expect { send_command(http, command, attempt) }.to raise_error(
        DiscussionBridgeGhost::Error
      ) { |value| error = value }
      before = encrypted_snapshot
      [
        {
          attempt: attempt,
          http: http,
          outcome: DiscussionBridgeGhost::Error.new("disabled")
        },
        { attempt: attempt, http: native_http(context), outcome: error },
        {
          attempt: attempt.merge("attempt_id" => SecureRandom.uuid),
          http: http,
          outcome: error
        }
      ].each do |options|
        expect {
          journal.retain_dispatch(args.fetch(:command_id), **options)
        }.to raise_error(DiscussionBridgeGhost::Error)
        expect(encrypted_snapshot).to eq(before)
      end
    end
  end

  it "preserves uncertainty when the post-request receipt commit is lost" do
    args = arguments
    with_journal do |journal, context|
      command = journal.prepare(**args)
      http =
        native_http(
          context,
          guard: -> { raise DiscussionBridgeGhost::Error.new("disabled") }
        )
      attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
      error = nil
      expect { send_command(http, command, attempt) }.to raise_error(
        DiscussionBridgeGhost::Error
      ) { |value| error = value }
      before = encrypted_snapshot
      context.expects(:commit).raises(
        DiscussionBridgeGhost::Error.new("native_lock_lost")
      )
      expect {
        journal.retain_dispatch(
          args.fetch(:command_id),
          attempt: attempt,
          http: http,
          outcome: error
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(encrypted_snapshot).to eq(before)
    end
    with_journal do |journal, context|
      expect {
        journal.begin_attempt(
          args.fetch(:command_id),
          http: native_http(context)
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
  end

  it "retains original work provenance separately from later observations and never synthesizes a current receipt" do
    args = arguments
    original_execution = nil
    with_journal do |journal, context|
      journal.prepare(**args)
      original_execution = context.execution_id
      journal.begin_attempt(args.fetch(:command_id), http: native_http(context))
    end
    original_cipher =
      row("native_command", args.fetch(:command_id)).encrypted_payload
    with_journal do |journal, context|
      observation = {
        "desired_generation" => 9,
        "observed_native_id" => "c" * 24
      }
      event = journal.observe(args.fetch(:command_id), observation)
      expect(event.fetch("observer_execution_id")).to eq(context.execution_id)
      expect(event.fetch("observer_execution_id")).not_to eq(original_execution)
      retained = journal.retained(args.fetch(:command_id))
      expect(retained.dig("command", "owner")).to eq(args.fetch(:owner))
      expect(retained.dig("state", "pending_attempt", "execution_id")).to eq(
        original_execution
      )
      expect(
        @installation
          .operational_records
          .where(kind: "native_ownership_receipt")
          .count
      ).to eq(0)
    end
    expect(
      row("native_command", args.fetch(:command_id)).encrypted_payload
    ).to eq(original_cipher)
  end

  it "blocks conflicting identities across installations and directions, including pre-ID slug claims" do
    args = arguments
    with_journal { |journal, _context| journal.prepare(**args) }
    other = make_installation(@installation.native_target)
    with_journal(other) do |journal, _context|
      expect {
        journal.prepare(**args.merge(command_id: SecureRandom.uuid))
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect {
        journal.assert_clear!(
          resource_id: SecureRandom.uuid,
          kind: "page",
          native_id: nil,
          slugs: [args.dig(:candidate, "slug")]
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    unrelated = make_installation
    with_journal(unrelated) do |journal, _context|
      expect(
        journal.assert_clear!(
          **args.fetch(:identity).transform_keys(&:to_sym),
          slugs: [args.dig(:candidate, "slug")]
        )
      ).to eq(true)
    end
  end

  it "blocks To source moves that touch an unresolved From native ID despite changed resource, work and slug" do
    args = arguments(action: "publish")
    with_journal do |journal, _context|
      journal.prepare(**args)
      expect {
        journal.assert_clear!(
          resource_id: SecureRandom.uuid,
          kind: "page",
          native_id: args.dig(:identity, "native_id"),
          slugs: ["other-slug"]
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      moved = arguments(action: "publish")
      moved[:identity]["native_id"] = args.dig(:identity, "native_id")
      moved[:owner].merge!(
        "direction" => "to_discourse",
        "action" => "source_move",
        "mapping_id" => nil,
        "work_id" => nil,
        "generation" => 0,
        "move_id" => SecureRandom.uuid
      )
      fields =
        moved
          .fetch(:candidate)
          .slice("id", "slug", "updated_at")
          .merge("slug" => "other-slug")
      moved[:request]["body_bytes"] = JSON.generate("posts" => [fields])
      moved[:candidate] = fields
      expect { journal.prepare(**moved) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
  end

  it "rejects invalid directional provenance, bodies, CAS and status without preparing an effect" do
    with_journal do |journal, _context|
      args = arguments
      [
        args.merge(owner: args.fetch(:owner).merge("generation" => false)),
        args.merge(identity: args.fetch(:identity).merge("native_id" => false)),
        args.merge(
          owner: args.fetch(:owner).merge("direction" => "to_discourse")
        ),
        args.merge(
          request:
            args.fetch(:request).merge(
              "body_bytes" =>
                '{"posts":[{"status":"published","slug":"retained-native-command"}]}'
            )
        ),
        args.merge(
          request:
            args.fetch(:request).merge(
              "body_bytes" => '{"posts":[],"posts":[]}'
            )
        ),
        args.merge(
          candidate: args.fetch(:candidate).merge("slug" => "wrong-slug")
        )
      ].each do |changed|
        expect { journal.prepare(**changed) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        expect(@installation.operational_records.count).to eq(0)
      end
      update = arguments(action: "publish")
      update[:baseline]["updated_at"] = "changed"
      expect { journal.prepare(**update) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
  end

  it "detects missing progress, barriers and event tails without silently reconstructing a clean command" do
    args = arguments
    with_journal do |journal, context|
      journal.prepare(**args)
      journal.begin_attempt(args.fetch(:command_id), http: native_http(context))
      original =
        row("native_command", args.fetch(:command_id)).encrypted_payload
      event = @installation.operational_records.find_by!(kind: "native_event")
      event.delete
      expect { journal.retained(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(
        row("native_command", args.fetch(:command_id)).encrypted_payload
      ).to eq(original)
      row("native_progress", args.fetch(:command_id)).delete
      expect { journal.prepare(**args) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      @installation
        .operational_records
        .where(kind: "native_barrier")
        .first
        .delete
      expect { journal.retained(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
  end

  it "refuses enclosing transactions and disabled contexts rather than committing a partial intent" do
    args = arguments
    with_journal do |journal, _context|
      @installation.class.transaction do
        expect { journal.prepare(**args) }.to raise_error(
          DiscussionBridgeGhost::Error,
          /committed boundary/
        )
      end
      expect(@installation.operational_records.count).to eq(0)
      @installation.update!(enabled: false)
      expect { journal.prepare(**args) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(@installation.operational_records.count).to eq(0)
    end
  end
end
