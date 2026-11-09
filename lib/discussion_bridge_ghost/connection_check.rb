# frozen_string_literal: true

module DiscussionBridgeGhost
  class ConnectionCheck
    CONTRACT_SHA256 = "808042688cbde88fac0acdf1187e4cb8c251e13025bfcf09cf3a3c361ca02003"
    SCHEMA_SHA256 = "e6a15a6d70f7bc8b8ee82aa22a0b9c2ff1bbf2da6277f7087118be9e026ce5c0"
    Error = DiscussionBridgeGhost::Error

    def self.receiver(connection_id)
      unless defined?(::DiscussionBridge::CmsProtocol::CONTRACT_SHA256) &&
             defined?(::DiscussionBridge::CmsProtocol::SCHEMA_SHA256) &&
             DiscussionBridge::CmsProtocol::CONTRACT_SHA256 == CONTRACT_SHA256 &&
             DiscussionBridge::CmsProtocol::SCHEMA_SHA256 == SCHEMA_SHA256
        raise Error.new("r7_receiver_required")
      end

      describe(connection_id)
    end

    def self.call(connection_id:, admin_url:, admin_key:)
      connection, descriptor = receiver(connection_id)
      ghost = GhostSite.new(admin_url, admin_key)
      site = ghost.site
      check_site!(connection, descriptor, site.fetch("url"))
      ghost.read_access
      {
        connection_id: descriptor.fetch("connection_id"),
        destination_origin: descriptor.fetch("destination_origin"),
        directions: descriptor.fetch("directions"),
        from_discourse_policy_enabled: descriptor.dig("policy", "enabled"),
        ghost_version: site.fetch("version"),
        ghost_admin_read: %w[posts pages],
      }
    end

    def self.check_site!(connection, descriptor, url)
      DiscussionBridge::CmsConfiguration.destination_url!(connection, descriptor, url)
    rescue DiscussionBridge::CmsProtocol::Error => error
      raise Error.new("receiver_#{error.code}"), cause: nil
    end

    def self.describe(connection_id)
      connection = DiscussionBridgeContentConnection.find_by(public_id: connection_id)
      raise Error.new("receiver_connection_missing") unless connection

      descriptor = DiscussionBridge::CmsAuthorityStore.new(connection).descriptor.body
      unless descriptor.fetch("profile") == "ghost" &&
             descriptor.dig("native_capabilities", "publication_kind") == "dynamic"
        raise Error.new("ghost_dynamic_connection_required")
      end
      [connection, descriptor]
    rescue DiscussionBridge::CmsProtocol::Error => error
      raise Error.new("receiver_#{error.code}"), cause: nil
    end
    private_class_method :describe
  end
end
