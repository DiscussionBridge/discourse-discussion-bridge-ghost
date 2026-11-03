# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridgeGhost::NativeTarget do
  def target(
    ghost = "https://Ghost.Example:443/",
    admin = "https://admin.example"
  )
    described_class.create!(
      public_id: SecureRandom.uuid,
      ghost_origin: ghost,
      admin_origin: admin
    )
  end

  it "keeps original origins while equivalent spellings share one unique identity" do
    original = target
    expect(original.reload.ghost_origin).to eq("https://Ghost.Example:443/")
    expect(original.ghost_origin_key).to eq("https://ghost.example")
    %w[
      https://ghost.example
      https://GHOST.example/
      https://ghost.example:443
    ].each do |alias_origin|
      expect {
        target(alias_origin, "https://other-admin.example")
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
    expect {
      target("https://other-ghost.example", "https://ADMIN.example:443/")
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "uses the approved IDNA policy rather than creating another Unicode-host owner" do
    first = target("https://bücher.example")
    expect(first.ghost_origin_key).to eq("https://xn--bcher-kva.example")
    expect {
      target("https://xn--bcher-kva.example", "https://other-admin.example")
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects non-HTTPS, path, query, fragment and userinfo origins" do
    %w[
      http://ghost.example
      https://ghost.example/blog
      https://ghost.example?x=1
      https://ghost.example/#x
      https://u:p@ghost.example
    ].each do |invalid|
      expect { target(invalid) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  it "does not silently edit an existing target's origin or lock identity" do
    original = target
    %i[public_id ghost_origin admin_origin].each do |field|
      value =
        field == :public_id ? SecureRandom.uuid : "https://changed.example"
      expect { original.update!(field => value) }.to raise_error(
        ActiveRecord::RecordInvalid
      )
      original.reload
    end
  end
end

RSpec.describe DiscussionBridgeGhost::NativeTarget do
  self.use_transactional_tests = false

  it "enforces canonical identity in PostgreSQL even after two writers validate" do
    base = Class.new(DiscussionBridgeGhost::NativeTarget)
    owned_ids = [SecureRandom.uuid, SecureRandom.uuid]
    stub_const(Object, :GhostNativeIdentityRace, base) do
      threads = []
      release = Queue.new
      begin
        base.establish_connection(
          ActiveRecord::Base.connection_db_config.configuration_hash.merge(
            pool: 2
          )
        )
        suffix = SecureRandom.hex(8)
        objects =
          owned_ids.each_with_index.map do |id, index|
            base.new(
              public_id: id,
              ghost_origin:
                "https://#{index.zero? ? "GHOST" : "ghost"}.#{suffix}.example#{index.zero? ? ":443/" : ""}",
              admin_origin: "https://admin#{index}.#{suffix}.example"
            )
          end
        objects.each { |object| expect(object.valid?).to eq(true) }
        base.connection_pool.release_connection
        ready = Queue.new
        threads =
          objects.map do |object|
            Thread.new do
              base.connection_pool.with_connection do |connection|
                ready << connection.select_value("SELECT pg_backend_pid()")
                release.pop
                object.save!(validate: false)
                :created
              end
            rescue ActiveRecord::RecordNotUnique
              :conflict
            end
          end
        pids = Timeout.timeout(10) { [ready.pop, ready.pop] }
        expect(pids.uniq.length).to eq(2)
        2.times { release << true }
        expect(threads.map(&:value).sort).to eq(%i[conflict created])
        expect(described_class.where(public_id: owned_ids).count).to eq(1)
      ensure
        2.times { release << true }
        threads.each do |thread|
          thread.join(5)
          thread.kill if thread.alive?
        end
        described_class.where(public_id: owned_ids).delete_all
        base.connection_pool.disconnect!
        base.remove_connection
      end
    end
  end
end
