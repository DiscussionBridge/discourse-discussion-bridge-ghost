# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridgeGhost::HistoryGuard do
  def installation
    public_id = SecureRandom.uuid
    target =
      DiscussionBridgeGhost::NativeTarget.create!(
        public_id: SecureRandom.uuid,
        ghost_origin: "https://guard-#{public_id}.example",
        admin_origin: "https://guard-#{public_id}.example"
      )
    envelope =
      DiscussionBridgeGhost::SecretEnvelope.new(
        application_key: Rails.application.secret_key_base,
        installation_id: public_id
      )
    DiscussionBridgeGhost::Installation.create!(
      public_id: public_id,
      native_target: target,
      connection_public_id: "dbc_#{SecureRandom.hex(12)}",
      encrypted_configuration:
        envelope.encrypt("configuration", { "secret" => "synthetic" })
    )
  end

  def page(owner, key)
    owner.operational_records.create!(
      kind: "policy_history_page",
      record_key: key,
      encrypted_payload: "synthetic-trigger-fixture"
    )
  end

  def token(owner, key)
    described_class.revision!(installation_id: owner.id, key: "pages:#{key}")
  end

  it "invalidates inserts, raw/bulk changes, deletion and byte restoration without an ABA reset" do
    owner = installation
    key = "#{SecureRandom.uuid}:#{"a" * 64}:0000000000000001"
    first = page(owner, "#{key}:0000000000000001")
    before = token(owner, key)
    second = page(owner, "#{key}:0000000000000002")
    expect(token(owner, key)).not_to eq(before)
    before = token(owner, key)
    first.class.where(id: first.id).update_all(encrypted_payload: "changed")
    expect(token(owner, key)).not_to eq(before)
    before = token(owner, key)
    first.class.connection.execute(
      "UPDATE discussion_bridge_ghost_records SET encrypted_payload = 'restored' WHERE id = #{first.id}"
    )
    expect(token(owner, key)).not_to eq(before)
    before = token(owner, key)
    second.class.where(id: second.id).delete_all
    expect(token(owner, key)).not_to eq(before)
    described_class.where(
      installation_id: owner.id,
      guard_key: "pages:#{key}"
    ).delete_all
    expect { token(owner, key) }.to raise_error(DiscussionBridgeGhost::Error)
    first.update!(encrypted_payload: "restored")
    expect(token(owner, key)).not_to eq(before)
  end

  it "invalidates OLD and NEW groups on key, kind and installation relocation" do
    first_owner, second_owner = installation, installation
    first_key = "#{SecureRandom.uuid}:#{"a" * 64}:0000000000000001"
    second_key = "#{SecureRandom.uuid}:#{"b" * 64}:0000000000000001"
    record = page(first_owner, "#{first_key}:0000000000000001")
    before = token(first_owner, first_key)
    record.update!(record_key: "#{second_key}:0000000000000001")
    expect(token(first_owner, first_key)).not_to eq(before)
    before = token(first_owner, second_key)
    record.update!(installation_id: second_owner.id)
    expect(token(first_owner, second_key)).not_to eq(before)
    before = token(second_owner, second_key)
    record.update!(kind: "not_history")
    expect(token(second_owner, second_key)).not_to eq(before)
    before = token(second_owner, second_key)
    record.update!(kind: "policy_history_page")
    expect(token(second_owner, second_key)).not_to eq(before)
  end

  it "does not reuse a cached guard after an out-of-band native database mutation" do
    owner = installation
    key = "#{SecureRandom.uuid}:#{"a" * 64}:0000000000000001"
    record = page(owner, "#{key}:0000000000000001")
    connection = owner.class.connection
    raw = connection.raw_connection
    connection.cache do
      previous = token(owner, key)
      cached =
        described_class.where(
          installation_id: owner.id,
          guard_key: "pages:#{key}"
        )
      expect(cached.pick(:revision)).to eq(previous)
      # Raw PostgreSQL intentionally bypasses Active Record cache invalidation,
      # as another process's write would; the real database trigger still runs.
      raw.exec(
        "UPDATE discussion_bridge_ghost_records SET encrypted_payload = 'outside-cache' WHERE id = #{record.id}"
      )
      # Establish the stale-cache prerequisite; a fresh sentinel read must not
      # accidentally pass this test because the driver cleared the cache.
      expect(cached.pick(:revision)).to eq(previous)
      expect(token(owner, key)).not_to eq(previous)
    end
  end

  it "rejects malformed history locators and transactionally covers TRUNCATE" do
    owner = installation
    key = "#{SecureRandom.uuid}:#{"a" * 64}:0000000000000001"
    page(owner, "#{key}:0000000000000001")
    before = token(owner, key)
    owner
      .class
      .transaction(requires_new: true) do
        owner.class.connection.execute(
          "TRUNCATE discussion_bridge_ghost_records"
        )
        expect(token(owner, key)).not_to eq(before)
        raise ActiveRecord::Rollback
      end
    expect(token(owner, key)).to eq(before)
    expect do
      owner.class.transaction(requires_new: true) { page(owner, "bad") }
    end.to raise_error(ActiveRecord::StatementInvalid)
  end
end
