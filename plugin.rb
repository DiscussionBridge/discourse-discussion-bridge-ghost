# frozen_string_literal: true

# name: discourse-discussion-bridge-ghost
# about: Optional native Discourse execution host for the DiscussionBridge Ghost adapter.
# version: 0.4.0-alpha.1
# authors: DiscussionBridge
# url: https://discussionbridge.dev/

enabled_site_setting :discussion_bridge_ghost_enabled

Rails.application.config.filter_parameters += [
  /ghost_admin_api_key/i,
  /ghost_webhook_secret/i,
  /ghost_connection_secret/i,
  /encrypted_configuration/i,
  /request_ciphertext/i,
  /response_ciphertext/i,
  /encrypted_payload/i
]

after_initialize do
  module ::DiscussionBridgeGhost
    PLUGIN_NAME = "discourse-discussion-bridge-ghost"
    VERSION = "0.4.0-alpha.1"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscussionBridgeGhost
    end
  end

  %w[
    error
    protected_diagnostics
    secret_envelope
    webhook_signature
    admin_token
    native_lock
    wire_json
    wire_protocol
    rack_transport
    mutation_journal
    ghost_http
    ghost_admin_client
  ].each { |name| require_relative "lib/discussion_bridge_ghost/#{name}" }
  %w[native_target installation operational_record mutation].each do |name|
    require_relative "app/models/discussion_bridge_ghost/#{name}"
  end
end
