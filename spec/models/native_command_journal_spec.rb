# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/discussion_bridge_ghost/native_command_journal"
require_relative "../../lib/discussion_bridge_ghost/native_executor"

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
      "status" => (create || action == "withdraw") ? "draft" : "published"
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
            "lexical" => "SYNTHETIC-unrelated-lexical",
            "status" => "published"
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
        "source_revision" => action == "withdraw" ? nil : "post:24:version:1",
        "external_id" => "native-target-one",
        "move_id" => nil,
        "proof_nonce" => nil
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

  def retained_history_snapshot(installation = @installation)
    installation
      .operational_records
      .where.not(kind: %w[native_unknown_create native_exclusion_enrollment])
      .order(:id)
      .pluck(:id, :kind, :record_key, :encrypted_payload)
  end

  def completed_response(journal, context, args, native_overrides: {})
    command = journal.prepare(**args)
    native =
      args
        .fetch(:candidate)
        .merge(
          "id" => args.dig(:identity, "native_id") || "a" * 24,
          "type" => args.dig(:identity, "kind"),
          "updated_at" => "2026-11-03T10:01:00.000Z"
        )
        .merge(native_overrides)
    response = { "#{args.dig(:identity, "kind")}s" => [native] }
    stub_request(
      args.dig(:request, "method").downcase.to_sym,
      @installation.native_target.admin_origin + args.dig(:request, "path")
    ).to_return(
      status: args.dig(:request, "allowed_statuses").first,
      headers: {
        "Content-Type" => "application/json"
      },
      body: JSON.generate(response)
    )
    http = native_http(context)
    attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
    outcome = send_command(http, command, attempt)
    journal.retain_dispatch(
      args.fetch(:command_id),
      attempt: attempt,
      http: http,
      outcome: outcome
    )
    [command, native]
  end

  def stub_native_reads(args, native, duplicate: false)
    origin = @installation.native_target.admin_origin
    kind = args.dig(:identity, "kind")
    stub_request(
      :get,
      %r{#{Regexp.escape(origin)}/ghost/api/admin/#{kind}s/#{native.fetch("id")}/}
    ).to_return(
      status: 200,
      headers: {
        "Content-Type" => "application/json"
      },
      body: JSON.generate("#{kind}s" => [native])
    )
    %w[post page].each do |queried|
      values =
        queried == kind || duplicate ? [native.merge("type" => queried)] : []
      stub_request(
        :get,
        %r{#{Regexp.escape(origin)}/ghost/api/admin/#{queried}s/\?filter=}
      ).to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json"
        },
        body: JSON.generate("#{queried}s" => values)
      )
    end
  end

  def source_move_arguments(native_id)
    args = arguments(action: "publish")
    args[:identity]["native_id"] = native_id
    args[:baseline].merge!("id" => native_id, "slug" => "another-source-old")
    args[:owner].merge!(
      "direction" => "to_discourse",
      "action" => "source_move",
      "mapping_id" => nil,
      "work_id" => nil,
      "generation" => 0,
      "move_id" => SecureRandom.uuid,
      "proof_nonce" =>
        Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
    )
    fields = {
      "id" => native_id,
      "slug" => "another-source-new",
      "updated_at" => args.dig(:baseline, "updated_at"),
      "codeinjection_head" => "Retained move proof"
    }
    args[:candidate] = fields
    args[:request].merge!(
      "path" => "/ghost/api/admin/posts/#{native_id}/",
      "body_bytes" => JSON.generate("posts" => [fields])
    )
    args
  end

  it "protects a discovered ID before readback succeeds across connections and both journal directions" do
    args = arguments
    other = make_installation(@installation.native_target)
    native = nil
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "state",
          "discovery",
          "native_id"
        )
      ).to eq(native.fetch("id"))
      expect(
        @installation
          .operational_records
          .where(kind: "native_unknown_create")
          .count
      ).to eq(0)
    end
    with_journal(other) do |journal, _context|
      expect {
        journal.assert_clear!(
          resource_id: SecureRandom.uuid,
          kind: "post",
          native_id: native.fetch("id"),
          slugs: ["different-slug"]
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      move = source_move_arguments(native.fetch("id"))
      expect { journal.prepare(**move) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      independent = source_move_arguments("b" * 24)
      journal.prepare(**independent)
      expect(
        journal.retained(independent.fetch(:command_id)).dig(
          "state",
          "pending_attempt"
        )
      ).to eq(nil)
    end
    stub_native_reads(args, native)
    with_journal do |journal, context|
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      executor.recover(args.fetch(:command_id))
      expect(
        @installation.operational_records.where(kind: "native_barrier").count
      ).to eq(0)
      expect(
        other.operational_records.where(kind: "native_barrier").count
      ).to eq(4)
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "command",
          "identity",
          "native_id"
        )
      ).to eq(nil)
    end
  end

  it "keeps conservative target exclusion when a create has no received ID, including after restart and lost receipt commit" do
    args = arguments
    other = make_installation(@installation.native_target)
    with_journal do |journal, context|
      command = journal.prepare(**args)
      http = native_http(context)
      attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
      stub_request(
        :post,
        @installation.native_target.admin_origin + args.dig(:request, "path")
      ).to_return(
        status: 201,
        headers: {
          "Content-Type" => "application/json"
        },
        body:
          JSON.generate(
            "posts" => [
              args.fetch(:candidate).merge(
                "id" => "a" * 24,
                "updated_at" => "2026-11-03T10:01:00.000Z"
              )
            ]
          )
      )
      response = send_command(http, command, attempt)
      context.expects(:commit).raises(
        DiscussionBridgeGhost::Error.new("native_lock_lost")
      )
      expect {
        journal.retain_dispatch(
          args.fetch(:command_id),
          attempt: attempt,
          http: http,
          outcome: response
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    with_journal(other) do |journal, context|
      expect {
        journal.assert_clear!(
          resource_id: SecureRandom.uuid,
          kind: "page",
          native_id: "b" * 24,
          slugs: ["unrelated"]
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect {
        journal.prepare(**source_move_arguments("b" * 24))
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(
        @installation
          .operational_records
          .where(kind: "native_unknown_create")
          .count
      ).to eq(1)
    end
    with_journal do |journal, _context|
      expect(journal.retained(args.fetch(:command_id)).fetch("response")).to eq(
        nil
      )
    end
    expect(
      a_request(
        :post,
        @installation.native_target.admin_origin + args.dig(:request, "path")
      )
    ).to have_been_made.once
  end

  %w[missing-id incomplete-alias].each do |shape|
    it "retains the complete target guard for #{shape} native replies" do
      args = arguments
      other = make_installation(@installation.native_target)
      with_journal do |journal, context|
        command = journal.prepare(**args)
        native =
          args.fetch(:candidate).merge(
            "id" => "a" * 24,
            "updated_at" => "2026-11-03T10:01:00.000Z",
            "slug" => nil
          )
        body =
          (
            if shape == "missing-id"
              '{"posts":[]}'
            else
              JSON.generate("posts" => [native])
            end
          )
        stub_request(
          :post,
          @installation.native_target.admin_origin + args.dig(:request, "path")
        ).to_return(
          status: 201,
          headers: {
            "Content-Type" => "application/json"
          },
          body: body
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
        expect(
          Base64.strict_decode64(
            journal.retained(args.fetch(:command_id)).dig(
              "response",
              "body_base64"
            )
          )
        ).to eq(body)
      end
      with_journal(other) do |journal, _context|
        expect {
          journal.assert_clear!(
            resource_id: SecureRandom.uuid,
            kind: "post",
            native_id: "b" * 24,
            slugs: ["unrelated"]
          )
        }.to raise_error(DiscussionBridgeGhost::Error)
      end
    end
  end

  it "requalifies older pending exclusions without changing historical bytes or granting a disabled installation effect authority" do
    args = arguments
    other = make_installation(@installation.native_target)
    command_bytes = nil
    events = nil
    with_journal do |journal, context|
      journal.prepare(**args)
      journal.begin_attempt(args.fetch(:command_id), http: native_http(context))
      command = row("native_command", args.fetch(:command_id))
      command_bytes = command.encrypted_payload
      events =
        @installation
          .operational_records
          .where(kind: "native_event")
          .pluck(:id, :encrypted_payload)
      command.update_columns(native_guard_version: nil)
      @installation
        .operational_records
        .where(kind: %w[native_unknown_create native_exclusion_enrollment])
        .delete_all
    end
    @installation.update!(enabled: false)
    with_journal(other) do |journal, context|
      expect(
        @installation
          .operational_records
          .find_by!(kind: "native_command")
          .encrypted_payload
      ).to eq(command_bytes)
      expect(
        @installation
          .operational_records
          .where(kind: "native_event")
          .pluck(:id, :encrypted_payload)
      ).to eq(events)
      expect(@installation.reload.enabled).to eq(false)
      expect {
        journal.assert_clear!(
          resource_id: SecureRandom.uuid,
          kind: "post",
          native_id: "b" * 24,
          slugs: ["unrelated"]
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      history =
        described_class.new(
          context: context,
          history_installation: @installation
        )
      expect(
        history.retained(args.fetch(:command_id)).dig(
          "state",
          "pending_attempt"
        )
      ).not_to eq(nil)
      expect { history.prepare(**args) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect {
        history.begin_attempt(
          args.fetch(:command_id),
          http: native_http(context)
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    expect(a_request(:any, /ghost-native-/)).not_to have_been_made
  end

  %w[current missing-other-disabled stale-owned].each do |shape|
    it "requalifies already-discovered create history after #{shape} projection reconstruction without changing original evidence or repeating effects" do
      args = arguments
      other = make_installation(@installation.native_target)
      native, original, retained = nil, nil, nil
      with_journal do |journal, context|
        command, native = completed_response(journal, context, args)
        retained = journal.retained(args.fetch(:command_id))
        expect(retained.dig("state", "discovery", "guard_required")).to eq(
          false
        )
        original = retained_history_snapshot
        context.commit do
          row("native_command", args.fetch(:command_id)).update_columns(
            native_guard_version: nil
          )
          @installation
            .operational_records
            .where(kind: "native_exclusion_enrollment")
            .delete_all
          if shape == "stale-owned"
            journal.send(:install_create_guard!, command)
          end
        end
      end
      foreign = shape == "missing-other-disabled"
      @installation.update!(enabled: false) if foreign
      2.times do
        with_journal(foreign ? other : @installation) do |journal, context|
          history =
            (
              if foreign
                described_class.new(
                  context: context,
                  history_installation: @installation
                )
              else
                journal
              end
            )
          2.times do
            history.qualify_retained_exclusion!(args.fetch(:command_id))
          end
          expect(history.retained(args.fetch(:command_id))).to eq(retained)
          expect(retained_history_snapshot).to eq(original)
          expect(
            row("native_command", args.fetch(:command_id)).native_guard_version
          ).to eq(2)
          expect(
            @installation.operational_records.where(
              kind: "native_unknown_create"
            )
          ).not_to exist
          if foreign
            expect(@installation.reload.enabled).to eq(false)
            expect { history.prepare(**arguments) }.to raise_error(
              DiscussionBridgeGhost::Error
            )
          end
          expect {
            journal.assert_clear!(
              resource_id: SecureRandom.uuid,
              kind: "post",
              native_id: native.fetch("id"),
              slugs: ["different-slug"]
            )
          }.to raise_error(DiscussionBridgeGhost::Error)
          expect {
            journal.assert_clear!(
              resource_id: SecureRandom.uuid,
              kind: "post",
              native_id: "b" * 24,
              slugs: [native.fetch("slug")]
            )
          }.to raise_error(DiscussionBridgeGhost::Error)
          expect(
            journal.assert_clear!(
              resource_id: SecureRandom.uuid,
              kind: "post",
              native_id: "b" * 24,
              slugs: ["independent-slug"]
            )
          ).to eq(true)
          # Reconstruct the nullable locator again, retaining all encrypted
          # command/progress/event/alias evidence and the protected enrollment.
          context.commit do
            row("native_command", args.fetch(:command_id)).update_columns(
              native_guard_version: nil
            )
          end
        end
      end
      @installation.update!(enabled: true) if foreign
      stub_native_reads(args, native)
      with_journal do |journal, context|
        expect(retained_history_snapshot).to eq(original)
        executor =
          DiscussionBridgeGhost::NativeExecutor.new(
            context: context,
            journal: journal,
            api_key: "a" * 24 + ":" + "12" * 32
          )
        completed = executor.recover(args.fetch(:command_id))
        expect(completed.fetch("native_id")).to eq(native.fetch("id"))
        expect(executor.recover(args.fetch(:command_id))).to eq(completed)
        expect(
          journal.retained(args.fetch(:command_id)).fetch("command")
        ).to eq(retained.fetch("command"))
      end
      expect(
        a_request(
          :post,
          @installation.native_target.admin_origin + args.dig(:request, "path")
        )
      ).to have_been_made.once
      expect(a_request(:put, %r{ghost/api/admin})).not_to have_been_made
    end
  end

  it "rolls back interrupted requalification without changing retained discovery and succeeds on a fresh retry" do
    args = arguments
    with_journal do |journal, context|
      command, native = completed_response(journal, context, args)
      retained = journal.retained(args.fetch(:command_id))
      context.commit do
        row("native_command", args.fetch(:command_id)).update_columns(
          native_guard_version: nil
        )
        journal.send(:install_create_guard!, command)
      end
      before = encrypted_snapshot
      fired = false
      injection =
        TracePoint.new(:return) do |event|
          if !fired && event.self.equal?(journal) &&
               event.method_id == :remove_create_guard!
            fired = true
            raise DiscussionBridgeGhost::Error.new("native_lock_lost")
          end
        end
      begin
        injection.enable
        expect {
          journal.qualify_retained_exclusion!(args.fetch(:command_id))
        }.to raise_error(DiscussionBridgeGhost::Error) { |error|
          expect(error.code).to eq("native_lock_lost")
        }
      ensure
        injection.disable
      end
      expect(fired).to eq(true)
      expect(
        row("native_command", args.fetch(:command_id)).native_guard_version
      ).to eq(nil)
      expect(encrypted_snapshot).to eq(before)
      expect(journal.retained(args.fetch(:command_id))).to eq(retained)
      journal.qualify_retained_exclusion!(args.fetch(:command_id))
      expect(journal.retained(args.fetch(:command_id))).to eq(retained)
      stub_native_reads(args, native)
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      expect(
        executor.recover(args.fetch(:command_id)).fetch("native_id")
      ).to eq(native.fetch("id"))
    end
    expect(
      a_request(
        :post,
        @installation.native_target.admin_origin + args.dig(:request, "path")
      )
    ).to have_been_made.once
    expect(a_request(:put, %r{ghost/api/admin})).not_to have_been_made
  end

  it "retains conservative partial-discovery protection through repeated cross-installation qualification" do
    args = arguments
    other = make_installation(@installation.native_target)
    original, retained = nil, nil
    with_journal do |journal, context|
      completed_response(
        journal,
        context,
        args,
        native_overrides: {
          "slug" => nil
        }
      )
      retained = journal.retained(args.fetch(:command_id))
      expect(retained.dig("state", "discovery", "guard_required")).to eq(true)
      original = retained_history_snapshot
      context.commit do
        row("native_command", args.fetch(:command_id)).update_columns(
          native_guard_version: nil
        )
        @installation
          .operational_records
          .where(kind: %w[native_unknown_create native_exclusion_enrollment])
          .delete_all
      end
    end
    @installation.update!(enabled: false)
    2.times do
      with_journal(other) do |journal, context|
        history =
          described_class.new(
            context: context,
            history_installation: @installation
          )
        history.qualify_retained_exclusion!(args.fetch(:command_id))
        expect(history.retained(args.fetch(:command_id))).to eq(retained)
        expect(retained_history_snapshot).to eq(original)
        expect(
          @installation
            .operational_records
            .where(kind: "native_unknown_create")
            .count
        ).to eq(1)
        expect {
          journal.assert_clear!(
            resource_id: SecureRandom.uuid,
            kind: "page",
            native_id: "b" * 24,
            slugs: ["independent-slug"]
          )
        }.to raise_error(DiscussionBridgeGhost::Error)
        context.commit do
          row("native_command", args.fetch(:command_id)).update_columns(
            native_guard_version: nil
          )
        end
      end
    end
    expect(
      a_request(
        :post,
        @installation.native_target.admin_origin + args.dig(:request, "path")
      )
    ).to have_been_made.once
    expect(a_request(:put, %r{ghost/api/admin})).not_to have_been_made
  end

  it "recovers a completed create response after restart without another POST, preserves original identity, and retains a terminal history after release" do
    args = arguments
    native = nil
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
    end
    stub_native_reads(args, native)
    with_journal do |journal, context|
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      completion = executor.recover(args.fetch(:command_id))
      expect(completion.fetch("native_id")).to eq(native.fetch("id"))
      expect(completion.fetch("released_claims")).to include(
        "native:#{native.fetch("id")}"
      )
      retained = journal.retained(args.fetch(:command_id))
      expect(retained.dig("command", "identity", "native_id")).to eq(nil)
      expect(retained.dig("command", "owner")).to eq(args.fetch(:owner))
      expect(retained.dig("state", "completion", "native", "status")).to eq(
        "draft"
      )
      expect(
        @installation.operational_records.where(kind: "native_barrier").count
      ).to eq(0)
      expect(executor.recover(args.fetch(:command_id))).to eq(completion)
      expect {
        journal.begin_attempt(
          args.fetch(:command_id),
          http: native_http(context)
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(journal.prepare(**args)).to eq(retained.fetch("command"))
    end
    with_journal do |journal, _context|
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "state",
          "completion",
          "native_id"
        )
      ).to eq(native.fetch("id"))
    end
    expect(
      a_request(
        :post,
        @installation.native_target.admin_origin + args.dig(:request, "path")
      )
    ).to have_been_made.once
  end

  it "keeps a possible delayed create blocked despite an empty lookup and never sends during recovery" do
    args = arguments
    with_journal do |journal, context|
      journal.prepare(**args)
      journal.begin_attempt(args.fetch(:command_id), http: native_http(context))
    end
    with_journal do |journal, context|
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      expect { executor.recover(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      ) { |error| expect(error.code).to eq("native_effect_uncertain") }
      expect { executor.execute(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      ) { |error| expect(error.code).to eq("native_effect_uncertain") }
      expect(
        journal.retained(args.fetch(:command_id)).dig("state", "completion")
      ).to eq(nil)
      expect(
        @installation.operational_records.where(kind: "native_barrier").count
      ).to eq(2)
    end
    expect(a_request(:any, /ghost-native-/)).not_to have_been_made
  end

  it "does not release an allowed response with mismatched readback or duplicate native identity across kinds" do
    args = arguments
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      stub_native_reads(args, native.merge("title" => "Someone else's edit"))
      expect { executor.recover(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      stub_native_reads(args, native, duplicate: true)
      expect { executor.recover(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(
        journal.retained(args.fetch(:command_id)).dig("state", "completion")
      ).to eq(nil)
      expect(
        @installation.operational_records.where(kind: "native_barrier").count
      ).to eq(3)
    end
  end

  it "rolls back completion and release while retaining prior discovery when the short receipt commit fails" do
    args = arguments
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      stub_native_reads(args, native)
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      injected = false
      fault =
        TracePoint.new(:return) do |event|
          if event.self.equal?(journal) && event.method_id == :append &&
               event.binding.local_variable_get(:kind) == "effect_completed"
            injected = true
            raise DiscussionBridgeGhost::Error.new("identity_conflict")
          end
        end
      expect {
        fault.enable { executor.recover(args.fetch(:command_id)) }
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(injected).to eq(true)
      expect(
        journal.retained(args.fetch(:command_id)).dig("state", "completion")
      ).to eq(nil)
      expect(
        @installation.operational_records.where(kind: "native_barrier").count
      ).to eq(3)
      expect(
        executor.recover(args.fetch(:command_id)).fetch("native_id")
      ).to eq(native.fetch("id"))
    end
    expect(
      a_request(
        :post,
        @installation.native_target.admin_origin + args.dig(:request, "path")
      )
    ).to have_been_made.once
  end

  it "atomically retains discovery and aliases or keeps the target guard when that local commit is interrupted" do
    args = arguments
    with_journal do |journal, context|
      command = journal.prepare(**args)
      native =
        args.fetch(:candidate).merge(
          "id" => "a" * 24,
          "updated_at" => "2026-11-03T10:01:00.000Z"
        )
      stub_request(
        :post,
        @installation.native_target.admin_origin + args.dig(:request, "path")
      ).to_return(
        status: 201,
        headers: {
          "Content-Type" => "application/json"
        },
        body: JSON.generate("posts" => [native])
      )
      http = native_http(context)
      attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
      response = send_command(http, command, attempt)
      fired = false
      fault =
        TracePoint.new(:return) do |event|
          if event.self.equal?(journal) && event.method_id == :append &&
               event.binding.local_variable_get(:kind) == "native_discovered"
            fired = true
            raise DiscussionBridgeGhost::Error.new("identity_conflict")
          end
        end
      expect {
        fault.enable do
          journal.retain_dispatch(
            args.fetch(:command_id),
            attempt: attempt,
            http: http,
            outcome: response
          )
        end
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(fired).to eq(true)
      expect(journal.retained(args.fetch(:command_id)).fetch("response")).to eq(
        nil
      )
      expect(
        @installation.operational_records.where(kind: "native_barrier").count
      ).to eq(2)
      expect(
        @installation
          .operational_records
          .where(kind: "native_unknown_create")
          .count
      ).to eq(1)
      journal.retain_dispatch(
        args.fetch(:command_id),
        attempt: attempt,
        http: http,
        outcome: response
      )
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "state",
          "discovery",
          "native_id"
        )
      ).to eq("a" * 24)
      expect(
        @installation.operational_records.where(kind: "native_barrier").count
      ).to eq(3)
      expect(
        @installation
          .operational_records
          .where(kind: "native_unknown_create")
          .count
      ).to eq(0)
    end
    expect(
      a_request(
        :post,
        @installation.native_target.admin_origin + args.dig(:request, "path")
      )
    ).to have_been_made.once
  end

  it "rejects a discovered native alias reserved by another installation on the same target" do
    args = arguments
    other = make_installation(@installation.native_target)
    with_journal(other) do |other_journal, _other_context|
      conflict = arguments(action: "publish")
      conflict[:baseline]["slug"] = "different-reserved-slug"
      conflict[:candidate]["slug"] = "different-reserved-slug"
      conflict[:request]["body_bytes"] = JSON.generate(
        "posts" => [conflict[:candidate]]
      )
      other_journal.prepare(**conflict)
    end
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      stub_native_reads(args, native)
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      expect { executor.recover(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(
        journal.retained(args.fetch(:command_id)).dig("state", "completion")
      ).to eq(nil)
    end
  end

  it "does not accept manufactured verifier evidence or a response different from the retained genuine dispatch" do
    args = arguments
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      stub_native_reads(args, native)
      retained = journal.retained(args.fetch(:command_id))
      verifier =
        DiscussionBridgeGhost::NativeEffectVerifier.new(
          context: context,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      proof =
        verifier.verify(
          command: retained.fetch("command"),
          response: retained.fetch("response")
        )
      copy =
        DiscussionBridgeGhost::NativeEffectVerifier::Evidence.new(
          value: proof.value
        )
      expect {
        journal.retain_completion(
          args.fetch(:command_id),
          verifier: verifier,
          evidence: copy
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      changed =
        retained.fetch("response").merge(
          "body_base64" =>
            Base64.strict_encode64(
              " #{Base64.strict_decode64(retained.dig("response", "body_base64"))}"
            )
        )
      different =
        verifier.verify(command: retained.fetch("command"), response: changed)
      expect {
        journal.retain_completion(
          args.fetch(:command_id),
          verifier: verifier,
          evidence: different
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(
        journal.retained(args.fetch(:command_id)).dig("state", "completion")
      ).to eq(nil)
      expect(
        journal.retain_completion(
          args.fetch(:command_id),
          verifier: verifier,
          evidence: proof
        ).fetch("native_id")
      ).to eq(native.fetch("id"))
    end
  end

  it "keeps terminal history valid after a later command reuses temporary claims, and detects a lost completion tail" do
    args = arguments
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      old_progress =
        row("native_progress", args.fetch(:command_id)).encrypted_payload
      stub_native_reads(args, native)
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      completion = executor.recover(args.fetch(:command_id))
      later = arguments(action: "publish")
      later[:identity]["resource_id"] = args.dig(:identity, "resource_id")
      later[:owner].merge!(
        args.fetch(:owner).slice("mapping_id", "external_id")
      )
      journal.prepare(**later)
      expect(
        journal.retained(args.fetch(:command_id)).dig("state", "completion")
      ).to eq(completion)
      event =
        @installation
          .operational_records
          .where(kind: "native_event")
          .where("record_key LIKE ?", "#{args.fetch(:command_id)}:%")
          .order(:record_key)
          .last
      event.delete
      row("native_progress", args.fetch(:command_id)).update!(
        encrypted_payload: old_progress
      )
      expect { journal.retained(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
  end

  it "hands temporary claims to permanent physical assignments atomically and keeps foreign connections from reusing a completed object" do
    args = arguments
    other = make_installation(@installation.native_target)
    original = nil
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      stub_native_reads(args, native)
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      executor.recover(args.fetch(:command_id))
      expect(
        @installation.operational_records.where(kind: "native_barrier").count
      ).to eq(0)
      assignments =
        @installation.operational_records.where(kind: "native_assignment")
      expect(assignments.pluck(:record_key).sort).to eq(
        [
          "native:#{native.fetch("id")}",
          "resource:#{args.dig(:identity, "resource_id")}",
          "slug:#{native.fetch("slug")}"
        ].sort
      )
      original = journal.retained(args.fetch(:command_id))
      expect {
        journal.prepare(**args.merge(command_id: SecureRandom.uuid))
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    with_journal(other) do |journal, _context|
      same_native = source_move_arguments("a" * 24)
      expect { journal.prepare(**same_native) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      same_slug = arguments
      expect { journal.prepare(**same_slug) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      independent = source_move_arguments("b" * 24)
      journal.prepare(**independent)
    end
    with_journal do |journal, _context|
      expect(journal.retained(args.fetch(:command_id))).to eq(original)
    end
  end

  it "rolls back permanent assignment handoff together with completion and temporary release on a crash" do
    args = arguments
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      stub_native_reads(args, native)
      before = encrypted_snapshot
      crash =
        TracePoint.new(:call) do |event|
          if event.self.equal?(journal) && event.method_id == :release_claims!
            raise "SYNTHETIC assignment handoff crash"
          end
        end
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      begin
        crash.enable
        expect { executor.recover(args.fetch(:command_id)) }.to raise_error(
          RuntimeError,
          /SYNTHETIC/
        )
      ensure
        crash.disable
      end
      expect(encrypted_snapshot).to eq(before)
      expect(
        @installation
          .operational_records
          .where(kind: %w[native_assignment native_assignment_handoff])
          .count
      ).to eq(0)
      expect(
        journal.retained(args.fetch(:command_id)).dig("state", "completion")
      ).to eq(nil)
      executor.recover(args.fetch(:command_id))
      expect(
        @installation.operational_records.where(kind: "native_assignment").count
      ).to eq(3)
      expect(
        @installation.operational_records.where(kind: "native_barrier").count
      ).to eq(0)
    end
    expect(
      a_request(
        :post,
        @installation.native_target.admin_origin + args.dig(:request, "path")
      )
    ).to have_been_made.once
  end

  it "qualifies a completed legacy physical assignment from original history even when its installation is disabled" do
    args = arguments
    other = make_installation(@installation.native_target)
    original = nil
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      stub_native_reads(args, native)
      DiscussionBridgeGhost::NativeExecutor.new(
        context: context,
        journal: journal,
        api_key: "a" * 24 + ":" + "12" * 32
      ).recover(args.fetch(:command_id))
      @installation
        .operational_records
        .where(
          kind: %w[
            native_assignment
            native_assignment_handoff
            native_assignment_enrollment
          ]
        )
        .delete_all
      row("native_command", args.fetch(:command_id)).update_columns(
        native_assignment_version: nil
      )
      original = retained_history_snapshot
    end
    @installation.update!(enabled: false)
    WebMock.reset!
    with_journal(other) do |journal, _context|
      expect(
        row("native_command", args.fetch(:command_id)).native_assignment_version
      ).to eq(1)
      expect(
        @installation.operational_records.where(kind: "native_assignment").count
      ).to eq(3)
      expect {
        journal.prepare(**source_move_arguments("a" * 24))
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    retained =
      retained_history_snapshot.reject do |_id, kind, _key, _payload|
        %w[
          native_assignment
          native_assignment_handoff
          native_assignment_enrollment
        ].include?(kind)
      end
    expect(retained).to eq(original)
    expect(a_request(:any, /ghost-native-/)).not_to have_been_made
  end

  it "does not repair a qualified assignment whose handoff or claim is missing and detects the protected version enrollment" do
    args = arguments
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      stub_native_reads(args, native)
      DiscussionBridgeGhost::NativeExecutor.new(
        context: context,
        journal: journal,
        api_key: "a" * 24 + ":" + "12" * 32
      ).recover(args.fetch(:command_id))
      saved = row("native_assignment_handoff", args.fetch(:command_id))
      payload = saved.encrypted_payload
      saved.delete
      expect { journal.retained(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect {
        journal.qualify_retained_assignment!(args.fetch(:command_id))
      }.to raise_error(DiscussionBridgeGhost::Error)
      @installation.operational_records.create!(
        kind: "native_assignment_handoff",
        record_key: args.fetch(:command_id),
        encrypted_payload: payload
      )
      expect(
        journal.retained(args.fetch(:command_id)).dig("state", "completion")
      ).not_to eq(nil)
      row("native_assignment", "native:#{native.fetch("id")}").delete
      expect { journal.retained(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
  end

  it "does not create a permanent assignment for a merely pending or retired intent" do
    args = arguments
    with_journal do |journal, _context|
      journal.prepare(**args)
      row("native_command", args.fetch(:command_id)).update_columns(
        native_assignment_version: nil
      )
      journal.qualify_retained_assignment!(args.fetch(:command_id))
      expect(
        @installation.operational_records.where(kind: "native_assignment").count
      ).to eq(0)
      journal.retire_unsent!(args.fetch(:command_id))
      expect(
        @installation
          .operational_records
          .where(kind: "native_assignment_handoff")
          .count
      ).to eq(0)
      row("native_assignment_enrollment", args.fetch(:command_id)).delete
      expect { journal.retained(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
  end

  it "keeps a native ID exclusive across kinds while allowing many distinct resources on one target" do
    args = arguments
    with_journal do |journal, context|
      _command, native = completed_response(journal, context, args)
      stub_native_reads(args, native)
      DiscussionBridgeGhost::NativeExecutor.new(
        context: context,
        journal: journal,
        api_key: "a" * 24 + ":" + "12" * 32
      ).recover(args.fetch(:command_id))
      page = arguments(action: "publish")
      page[:identity]["kind"] = "page"
      page[:request]["path"] = "/ghost/api/admin/pages/#{native.fetch("id")}/"
      page[:request]["body_bytes"] = JSON.generate(
        "pages" => [page.fetch(:candidate)]
      )
      expect { journal.prepare(**page) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      independent = arguments(action: "publish")
      independent[:identity]["native_id"] = "b" * 24
      independent[:baseline].merge!(
        "id" => "b" * 24,
        "slug" => "second-article"
      )
      independent[:candidate].merge!(
        "id" => "b" * 24,
        "slug" => "second-article"
      )
      independent[:request].merge!(
        "path" => "/ghost/api/admin/posts/#{"b" * 24}/",
        "body_bytes" =>
          JSON.generate("posts" => [independent.fetch(:candidate)])
      )
      journal.prepare(**independent)
    end
  end

  it "records physical withdrawal with its original null revision but does not grant new publication authority" do
    args = arguments(action: "withdraw")
    args[:baseline]["lexical"] = '{"root":{"children":[]}}'
    with_journal do |journal, context|
      command = journal.prepare(**args)
      native =
        args
          .fetch(:baseline)
          .merge(args.fetch(:candidate))
          .merge("type" => "post", "updated_at" => "2026-11-03T10:01:00.000Z")
      post =
        stub_request(
          :put,
          @installation.native_target.admin_origin + args.dig(:request, "path")
        ).to_return(
          status: 200,
          headers: {
            "Content-Type" => "application/json"
          },
          body: JSON.generate("posts" => [native])
        )
      http = native_http(context)
      attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
      result = send_command(http, command, attempt)
      journal.retain_dispatch(
        args.fetch(:command_id),
        attempt: attempt,
        http: http,
        outcome: result
      )
      stub_native_reads(args, native)
      executor =
        DiscussionBridgeGhost::NativeExecutor.new(
          context: context,
          journal: journal,
          api_key: "a" * 24 + ":" + "12" * 32
        )
      expect(
        executor.recover(args.fetch(:command_id)).dig("native", "status")
      ).to eq("draft")
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "command",
          "owner",
          "source_revision"
        )
      ).to eq(nil)
      expect(post).to have_been_requested.once
    end
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

  %w[create_draft publish source_move].each do |action|
    it "retires an unstarted #{action} intent as no effect, preserves terminal history and permits a separately prepared replacement" do
      args =
        (
          if action == "source_move"
            source_move_arguments("a" * 24)
          else
            arguments(action: action)
          end
        )
      original, retired = nil, nil
      with_journal do |journal, context|
        original = journal.prepare(**args)
        original_bytes =
          row("native_command", args.fetch(:command_id)).encrypted_payload
        retired = journal.retire_unsent!(args.fetch(:command_id))
        expect(retired.fetch("format")).to eq("ghost-native-retirement-1")
        expect(retired.fetch("reason")).to eq("no_pending_dispatch")
        expect(retired.fetch("history_event_count")).to eq(0)
        expect(retired.fetch("history_tail_sha256")).to eq(nil)
        expect(retired.fetch("released_claims")).to eq(original.fetch("claims"))
        expect(
          row("native_command", args.fetch(:command_id)).encrypted_payload
        ).to eq(original_bytes)
        expect(
          journal.retained(args.fetch(:command_id)).dig("state", "completion")
        ).to eq(nil)
        before = encrypted_snapshot
        expect(journal.retire_unsent!(args.fetch(:command_id))).to eq(retired)
        expect(journal.prepare(**args)).to eq(original)
        expect(encrypted_snapshot).to eq(before)
        expect {
          journal.begin_attempt(
            args.fetch(:command_id),
            http: native_http(context)
          )
        }.to raise_error(DiscussionBridgeGhost::Error)
        executor =
          DiscussionBridgeGhost::NativeExecutor.new(
            context: context,
            journal: journal,
            api_key: "a" * 24 + ":" + "12" * 32
          )
        %i[execute recover].each do |operation|
          expect {
            executor.public_send(operation, args.fetch(:command_id))
          }.to raise_error(DiscussionBridgeGhost::Error) { |error|
            expect(error.code).to eq("native_command_retired")
          }
        end
        expect {
          journal.observe(args.fetch(:command_id), { "new" => "observation" })
        }.to raise_error(DiscussionBridgeGhost::Error)
        replacement = args.deep_dup
        replacement[:command_id] = SecureRandom.uuid
        journal.prepare(**replacement)
        expect(
          journal.retained(args.fetch(:command_id)).fetch("command")
        ).to eq(original)
        expect(
          journal.retained(args.fetch(:command_id)).dig("state", "retirement")
        ).to eq(retired)
      end
      with_journal do |journal, _context|
        expect(
          journal.retained(args.fetch(:command_id)).dig("state", "retirement")
        ).to eq(retired)
        expect(
          journal.retained(args.fetch(:command_id)).fetch("command")
        ).to eq(original)
      end
      expect(a_request(:any, %r{ghost/api/admin})).not_to have_been_made
    end
  end

  it "retires after genuine retained no-send across restart without rewriting the original attempts or executing again" do
    args = arguments
    original_events, original_bytes = nil, nil
    with_journal do |journal, context|
      command = journal.prepare(**args)
      original_bytes =
        row("native_command", args.fetch(:command_id)).encrypted_payload
      http =
        native_http(
          context,
          guard: -> { raise DiscussionBridgeGhost::Error.new("disabled") }
        )
      2.times do
        attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
        error = nil
        expect { send_command(http, command, attempt) }.to raise_error(
          DiscussionBridgeGhost::Error
        ) { |value| error = value }
        journal.retain_dispatch(
          args.fetch(:command_id),
          attempt: attempt,
          http: http,
          outcome: error
        )
      end
      original_events =
        @installation
          .operational_records
          .where(kind: "native_event")
          .order(:id)
          .pluck(:id, :encrypted_payload)
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "state",
          "pending_attempt"
        )
      ).to eq(nil)
    end
    with_journal do |journal, _context|
      retired = journal.retire_unsent!(args.fetch(:command_id))
      expect(retired.fetch("history_event_count")).to eq(4)
      expect(
        row("native_command", args.fetch(:command_id)).encrypted_payload
      ).to eq(original_bytes)
      expect(
        @installation
          .operational_records
          .where(id: original_events.map(&:first))
          .order(:id)
          .pluck(:id, :encrypted_payload)
      ).to eq(original_events)
      expect(journal.retained(args.fetch(:command_id)).fetch("response")).to eq(
        nil
      )
      expect(
        @installation.operational_records.where(kind: "native_barrier")
      ).not_to exist
      expect(
        @installation.operational_records.where(kind: "native_unknown_create")
      ).not_to exist
      before = encrypted_snapshot
      expect(journal.retire_unsent!(args.fetch(:command_id))).to eq(retired)
      expect(encrypted_snapshot).to eq(before)
    end
    expect(a_request(:any, %r{ghost/api/admin})).not_to have_been_made
  end

  %w[
    pending
    no-send-then-pending
    may-have-sent
    response
    completed
  ].each do |shape|
    it "refuses no-effect retirement for #{shape} native work and preserves all evidence" do
      args = arguments
      with_journal do |journal, context|
        if %w[response completed].include?(shape)
          _command, native = completed_response(journal, context, args)
          if shape == "completed"
            stub_native_reads(args, native)
            DiscussionBridgeGhost::NativeExecutor.new(
              context: context,
              journal: journal,
              api_key: "a" * 24 + ":" + "12" * 32
            ).recover(args.fetch(:command_id))
          end
        else
          command = journal.prepare(**args)
          if shape == "no-send-then-pending"
            deny =
              native_http(
                context,
                guard: -> { raise DiscussionBridgeGhost::Error.new("disabled") }
              )
            first = journal.begin_attempt(args.fetch(:command_id), http: deny)
            error = nil
            expect { send_command(deny, command, first) }.to raise_error(
              DiscussionBridgeGhost::Error
            ) { |value| error = value }
            journal.retain_dispatch(
              args.fetch(:command_id),
              attempt: first,
              http: deny,
              outcome: error
            )
          end
          http = native_http(context)
          attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
          if shape == "may-have-sent"
            stub_request(
              :post,
              @installation.native_target.admin_origin +
                args.dig(:request, "path")
            ).to_raise(EOFError)
            failure = nil
            expect { send_command(http, command, attempt) }.to raise_error(
              DiscussionBridgeGhost::Error
            ) { |value| failure = value }
            journal.retain_dispatch(
              args.fetch(:command_id),
              attempt: attempt,
              http: http,
              outcome: failure
            )
          end
        end
        before = encrypted_snapshot
        expect {
          journal.retire_unsent!(args.fetch(:command_id))
        }.to raise_error(DiscussionBridgeGhost::Error)
        expect(encrypted_snapshot).to eq(before)
        expect(
          journal.retained(args.fetch(:command_id)).dig("state", "retirement")
        ).to eq(nil)
      end
    end
  end

  it "rolls back retirement and claim release together when the local commit is interrupted" do
    args = arguments
    with_journal do |journal, _context|
      journal.prepare(**args)
      before = encrypted_snapshot
      fired = false
      injection =
        TracePoint.new(:return) do |event|
          if !fired && event.self.equal?(journal) &&
               event.method_id == :release_claims!
            fired = true
            raise DiscussionBridgeGhost::Error.new("native_lock_lost")
          end
        end
      begin
        injection.enable
        expect {
          journal.retire_unsent!(args.fetch(:command_id))
        }.to raise_error(DiscussionBridgeGhost::Error)
      ensure
        injection.disable
      end
      expect(fired).to eq(true)
      expect(encrypted_snapshot).to eq(before)
      expect(
        journal.retained(args.fetch(:command_id)).dig("state", "retirement")
      ).to eq(nil)
      journal.retire_unsent!(args.fetch(:command_id))
    end
    expect(a_request(:any, %r{ghost/api/admin})).not_to have_been_made
  end

  it "refuses foreign history-only retirement and detects lost retirement history rather than fabricating an unstarted intent" do
    args = arguments
    other = make_installation(@installation.native_target)
    with_journal { |journal, _context| journal.prepare(**args) }
    @installation.update!(enabled: false)
    with_journal(other) do |_journal, context|
      history =
        described_class.new(
          context: context,
          history_installation: @installation
        )
      before = encrypted_snapshot
      expect { history.retire_unsent!(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect(encrypted_snapshot).to eq(before)
    end
    @installation.update!(enabled: true)
    with_journal do |journal, _context|
      initial_progress =
        row("native_progress", args.fetch(:command_id)).encrypted_payload
      journal.retire_unsent!(args.fetch(:command_id))
      @installation.operational_records.where(kind: "native_event").delete_all
      row("native_progress", args.fetch(:command_id)).update!(
        encrypted_payload: initial_progress
      )
      expect { journal.retained(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
      expect { journal.retire_unsent!(args.fetch(:command_id)) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect(a_request(:any, %r{ghost/api/admin})).not_to have_been_made
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
        "move_id" => SecureRandom.uuid,
        "proof_nonce" =>
          Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
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

  def compatible_work!(context, args)
    owner = args.fetch(:owner)
    work = {
      "work_id" => owner.fetch("work_id"),
      "mapping_id" => owner.fetch("mapping_id"),
      "source_id" => "topic:24",
      "source_revision" => owner.fetch("source_revision"),
      "policy_revision" => "policy:1",
      "action" =>
        owner.fetch("action") == "withdraw" ? "withdraw" : "publish_revision",
      "state" => "leased",
      "attempt_cycle" => SecureRandom.uuid,
      "attempt" => 1,
      "lease_generation" => owner.fetch("generation"),
      "retry_at" => nil,
      "last_failure_code" => nil
    }
    context.protocol.validate!("Work", work)
    guard = DiscussionBridgeGhost::WorkAuthority.allocate
    guard.instance_variable_set(:@protocol, context.protocol)
    # Actual pinned validator compatibility, not a forged successful guard or
    # a claim that this synthetic fixture obtained current effect authority.
    guard.send(
      :validate_work_identity!,
      work.slice(*DiscussionBridgeGhost::WorkAuthority::WORK_FIELDS)
    )
  end

  it "retains null original withdrawal revision across restart separately from the prior owned revision" do
    args = arguments(action: "withdraw")
    args[:baseline]["prior_owned_source_revision"] = "post:24:version:1"
    with_journal do |journal, context|
      compatible_work!(context, args)
      retained = journal.prepare(**args)
      expect(retained.dig("owner", "source_revision")).to eq(nil)
      expect(retained.dig("baseline", "prior_owned_source_revision")).to eq(
        "post:24:version:1"
      )
      before = encrypted_snapshot
      [false, "post:24:version:1", "invented"].each do |revision|
        expect {
          journal.prepare(
            **args.merge(
              owner: args.fetch(:owner).merge("source_revision" => revision)
            )
          )
        }.to raise_error(DiscussionBridgeGhost::Error)
        expect(encrypted_snapshot).to eq(before)
      end
    end
    with_journal do |journal, context|
      compatible_work!(context, args)
      expect(journal.prepare(**args).dig("owner", "source_revision")).to eq(nil)
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "command",
          "baseline",
          "prior_owned_source_revision"
        )
      ).to eq("post:24:version:1")
    end
  end

  it "retains actual From presentation-move identity without calling it an ordinary publication or To move" do
    args = arguments(action: "publish")
    args[:baseline]["slug"] = "old-presentation"
    args[:owner]["move_id"] = SecureRandom.uuid
    args[:owner]["proof_nonce"] = Base64.urlsafe_encode64(
      SecureRandom.random_bytes(32),
      padding: false
    )
    with_journal do |journal, context|
      compatible_work!(context, args)
      context.protocol.validate!(
        "UrlMove",
        {
          "move_id" => args.dig(:owner, "move_id"),
          "mapping_id" => args.dig(:owner, "mapping_id"),
          "expected_mapping_revision" => "mapping:1",
          "old_url" =>
            "#{@installation.native_target.ghost_origin}/old-presentation/",
          "new_url" =>
            "#{@installation.native_target.ghost_origin}/#{args.dig(:candidate, "slug")}/",
          "proof_nonce" => args.dig(:owner, "proof_nonce"),
          "state" => "prepared",
          "prepared_at" => @clock.iso8601(3)
        }
      )
      journal.prepare(**args)
      before = encrypted_snapshot
      [
        args[:owner].merge("move_id" => nil, "proof_nonce" => nil),
        args[:owner].merge("proof_nonce" => nil),
        args[:owner].merge("move_id" => SecureRandom.uuid)
      ].each do |owner|
        expect { journal.prepare(**args.merge(owner: owner)) }.to raise_error(
          DiscussionBridgeGhost::Error
        )
        expect(encrypted_snapshot).to eq(before)
      end
    end
    with_journal do |journal, _context|
      expect(journal.prepare(**args).fetch("owner")).to eq(args.fetch(:owner))
    end
  end

  it "retains valid To source-move provenance without a From mapping or lease" do
    args = arguments(action: "publish")
    args[:baseline]["slug"] = "old-source"
    args[:owner].merge!(
      "direction" => "to_discourse",
      "action" => "source_move",
      "mapping_id" => nil,
      "work_id" => nil,
      "generation" => 0,
      "move_id" => SecureRandom.uuid,
      "proof_nonce" =>
        Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
    )
    args[:request]["body_bytes"] = JSON.generate(
      "posts" => [args.fetch(:candidate).slice("id", "slug", "updated_at")]
    )
    with_journal do |journal, context|
      context.protocol.validate!(
        "SourceUrlMove",
        {
          "move_id" => args.dig(:owner, "move_id"),
          "resource_id" => args.dig(:identity, "resource_id"),
          "expected_source_revision" => args.dig(:owner, "source_revision"),
          "old_url" =>
            "#{@installation.native_target.ghost_origin}/old-source/",
          "new_url" =>
            "#{@installation.native_target.ghost_origin}/#{args.dig(:candidate, "slug")}/",
          "proof_nonce" => args.dig(:owner, "proof_nonce"),
          "state" => "prepared",
          "prepared_at" => @clock.iso8601(3)
        }
      )
      expect(journal.prepare(**args).fetch("owner")).to eq(args.fetch(:owner))
      expect {
        journal.prepare(
          **args.merge(
            owner: args[:owner].merge("mapping_id" => SecureRandom.uuid)
          )
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    with_journal do |journal, _context|
      expect(journal.prepare(**args).fetch("owner")).to eq(args.fetch(:owner))
    end
  end

  def interrupted_duplicate(http, command, attempt)
    fired = false
    registry = http.instance_variable_get(:@dispatches)
    trace =
      TracePoint.new(:c_call) do |event|
        if event.self.equal?(registry) && event.method_id == :key?
          trace.disable
          fired = true
          raise Timeout::Error
        end
      end
    trace.enable
    send_command(http, command, attempt)
  ensure
    trace&.disable
    expect(fired).to eq(true)
  end

  it "refuses interrupted duplicate proof through the actual durable journal without clearing the sent attempt" do
    args = arguments
    with_journal do |journal, context|
      command = journal.prepare(**args)
      request =
        stub_request(
          :post,
          @installation.native_target.admin_origin +
            command.dig("request", "path")
        ).to_return(
          status: 201,
          headers: {
            "Content-Type" => "application/json"
          },
          body: '{"posts":[]}'
        )
      http = native_http(context)
      attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
      response = send_command(http, command, attempt)
      error = nil
      expect { interrupted_duplicate(http, command, attempt) }.to raise_error(
        DiscussionBridgeGhost::Error
      ) { |value| error = value }
      before = encrypted_snapshot
      expect {
        journal.retain_dispatch(
          args.fetch(:command_id),
          attempt: attempt,
          http: http,
          outcome: error
        )
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(encrypted_snapshot).to eq(before)
      expect(
        journal.retained(args.fetch(:command_id)).dig(
          "state",
          "pending_attempt"
        )
      ).to eq(attempt)
      3.times { GC.start(full_mark: true, immediate_sweep: true) }
      journal.retain_dispatch(
        args.fetch(:command_id),
        attempt: attempt,
        http: http,
        outcome: response
      )
      expect {
        journal.begin_attempt(args.fetch(:command_id), http: http)
      }.to raise_error(DiscussionBridgeGhost::Error)
      expect(request).to have_been_requested.once
    end
  end

  it "retains actual pre-send and post-send errors after GC without allowing forged outcome copies" do
    %w[not_sent may_have_sent].each do |phase|
      args = arguments
      args[:candidate]["slug"] += "-#{phase.tr("_", "-")}"
      body = JSON.parse(args.dig(:request, "body_bytes"))
      body["posts"].first["slug"] = args.dig(:candidate, "slug")
      args[:request]["body_bytes"] = JSON.generate(body)
      with_journal do |journal, context|
        command = journal.prepare(**args)
        request =
          stub_request(
            :post,
            @installation.native_target.admin_origin +
              command.dig("request", "path")
          ).to_timeout
        guard =
          phase == "not_sent" ?
            -> { raise DiscussionBridgeGhost::Error.new("disabled").freeze } :
            -> {}
        http = native_http(context, guard: guard)
        attempt = journal.begin_attempt(args.fetch(:command_id), http: http)
        error = nil
        expect { send_command(http, command, attempt) }.to raise_error(
          DiscussionBridgeGhost::Error
        ) { |value| error = value }
        3.times { GC.start(full_mark: true, immediate_sweep: true) }
        before = encrypted_snapshot
        expect {
          journal.retain_dispatch(
            args.fetch(:command_id),
            attempt: attempt,
            http: http,
            outcome: error.dup
          )
        }.to raise_error(DiscussionBridgeGhost::Error)
        expect(encrypted_snapshot).to eq(before)
        journal.retain_dispatch(
          args.fetch(:command_id),
          attempt: attempt,
          http: http,
          outcome: error
        )
        expect(
          journal
            .retained(args.fetch(:command_id))
            .dig("state", "pending_attempt")
            .nil?
        ).to eq(phase == "not_sent")
        if phase == "not_sent"
          expect(request).not_to have_been_requested
        else
          expect(request).to have_been_requested.once
        end
      end
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
