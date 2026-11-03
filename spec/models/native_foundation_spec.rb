# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "DiscussionBridge Ghost native foundation" do
  def fixture_target
    DiscussionBridgeGhost::NativeTarget.create!(
      public_id: SecureRandom.uuid,
      ghost_origin: "https://ghost-native.example",
      admin_origin: "https://ghost-admin.example"
    )
  end

  def fixture_installation(target = fixture_target)
    id = SecureRandom.uuid
    envelope = DiscussionBridgeGhost::SecretEnvelope.new(
      application_key: Rails.application.secret_key_base,
      installation_id: id
    )
    DiscussionBridgeGhost::Installation.create!(
      native_target: target,
      public_id: id,
      connection_public_id: "dbc_#{SecureRandom.hex(12)}",
      encrypted_configuration: envelope.encrypt("configuration", "secret" => "SYNTHETIC-configuration-secret")
    )
  end

  it "loads alongside the exact unchanged receiver and pinned Core" do
    expect(DiscussionBridgeGhost::VERSION).to eq("0.4.0-alpha.1")
    expect(DiscussionBridge::CmsProtocol::CONTRACT_SHA256).to eq("808042688cbde88fac0acdf1187e4cb8c251e13025bfcf09cf3a3c361ca02003")
    expect(DiscussionBridge::CmsProtocol::SCHEMA_SHA256).to eq("e6a15a6d70f7bc8b8ee82aa22a0b9c2ff1bbf2da6277f7087118be9e026ce5c0")
    receiver_root = Rails.root.join("plugins/discourse-discussion-bridge")
    receiver_sha, receiver_status = Open3.capture2("git", "-C", receiver_root.to_s, "rev-parse", "HEAD")
    expect(receiver_status.success?).to eq(true)
    expect(receiver_sha.strip).to eq("685eb3c6be54b8ef41b68949867b884703e2768e")
    core_sha, core_status = Open3.capture2("git", "-C", Rails.root.to_s, "rev-parse", "HEAD")
    expect(core_status.success?).to eq(true)
    expect(core_sha.strip).to eq("acf8e70129f5359635f8227ad8a91a792204147e")
  end

  it "does not enable processing merely by installing the plugin" do
    expect(SiteSetting.discussion_bridge_ghost_enabled).to eq(false)
    installation = fixture_installation
    expect(installation.enabled).to eq(false)
    expect { installation.assert_enabled! }.to raise_error(DiscussionBridgeGhost::Error, /disabled/)
  end

  it "persists encrypted state and authenticates the installation and record identity" do
    installation = fixture_installation
    other = fixture_installation(installation.native_target)
    value = { "lease_token" => "SYNTHETIC-private-lease", "native_id" => "native-one" }
    binding = JSON.generate(["publication", "resource-one"])
    record = installation.operational_records.create!(
      kind: "publication",
      record_key: "resource-one",
      encrypted_payload: installation.envelope.encrypt("operational_record", value, binding: binding)
    )
    expect(record.reload.private_payload).to eq(value)
    expect(record.encrypted_payload).not_to include("SYNTHETIC")
    record.installation = other
    expect { record.private_payload }.to raise_error(DiscussionBridgeGhost::Error)
    record.installation = installation
    record.record_key = "resource-two"
    expect { record.private_payload }.to raise_error(DiscussionBridgeGhost::Error)
  end

  it "retains one target domain for two legitimate connections and refuses duplicate target aliases" do
    first = fixture_installation
    second = fixture_installation(first.native_target)
    expect(first.native_target_id).to eq(second.native_target_id)
    expect(first.connection_public_id).not_to eq(second.connection_public_id)
    expect {
      DiscussionBridgeGhost::NativeTarget.create!(
        public_id: SecureRandom.uuid,
        ghost_origin: first.native_target.ghost_origin,
        admin_origin: "https://different-admin.example"
      )
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "serializes actual PostgreSQL writers across two connections to the same target" do
    target = fixture_target
    DiscussionBridgeGhost::NativeLock.synchronize(target.public_id) do |lease|
      result = Thread.new do
        DiscussionBridgeGhost::NativeLock.synchronize(target.public_id) { "unexpected second writer" }
      rescue DiscussionBridgeGhost::Error => error
        error.code
      end.value
      expect(result).to eq("native_lock_busy")
      expect(lease.assert!).to eq(true)
    end
    expect(DiscussionBridgeGhost::NativeLock.synchronize(target.public_id) { "released" }).to eq("released")
  end

  it "detects a lost actual PostgreSQL lock before another native effect" do
    id = SecureRandom.uuid
    DiscussionBridgeGhost::NativeLock.synchronize(id) do |lease|
      key = DiscussionBridgeGhost::NativeLock.key(id)
      # Deliberately release only this test's private lock session. The normal
      # model connection is not the connector's dedicated lock checkout.
      lease.instance_variable_get(:@connection).select_value("SELECT pg_advisory_unlock(#{key})")
      expect { lease.assert! }.to raise_error(DiscussionBridgeGhost::Error, /no longer owns/)
    end
  end
end
