# frozen_string_literal: true

module DiscussionBridgeGhost
  class AdminSetup
    DIRECTIONS = {
      "from_discourse" => [AutomaticPublishing, "admin_key"],
      "to_discourse" => [InboundPublishing, "content_key"],
    }.freeze

    def self.connections
      ConnectionCheck.require_receiver!
      eligible_connections.order(:name, :id).map do |connection|
        {
          id: connection.public_id,
          name: connection.name,
          origin: connection.cms_configuration.fetch("destination_origin"),
          directions: DIRECTIONS.keys.filter_map do |direction|
            new(connection, direction).configuration if connection.allows_direction?(direction)
          end,
        }
      end
    end

    def self.find(connection_id, direction)
      ConnectionCheck.require_receiver!
      connection = eligible_connections.find_by(public_id: connection_id)
      raise Error.new("receiver_connection_missing") unless connection
      unless DIRECTIONS.key?(direction) && connection.allows_direction?(direction)
        raise Error.new("ghost_setup_direction_unavailable")
      end
      new(connection, direction)
    end

    def self.eligible_connections
      DiscussionBridgeContentConnection.where(platform: "ghost", enabled: true)
        .where("cms_configuration->>'profile' = ?", "ghost")
    end
    private_class_method :eligible_connections

    def initialize(connection, direction)
      @connection = connection
      @direction = direction
      @publisher, @key_name = DIRECTIONS.fetch(direction)
    end

    def configuration
      saved = saved_options
      {
        id: @direction,
        enabled: saved.present?,
        publishing_status: publishing_status(saved),
        admin_url: saved["admin_url"] || @connection.cms_configuration.fetch("destination_origin"),
        credential_saved: saved[@key_name].present?,
        kind: saved["kind"] || "post",
        url_label: saved["url_label"],
        tag: saved["tag"],
      }
    end

    def update!(options)
      case options["enabled"]
      when false
        @publisher.disable!(connection_id: @connection.public_id)
      when true
        enable!(options)
      else
        raise Error.new("ghost_setup_input_invalid")
      end
      configuration
    end

    private

    def publishing_status(saved)
      return "disabled" if saved.blank?

      outbound = @direction == "from_discourse"
      direction = outbound ? "outbound" : "inbound"
      scope = SupervisedScope::CURRENT
      return "paused" unless scope.active?(direction)
      return "outside_scope" unless scope.connection?(direction, @connection.public_id)
      return "unavailable" unless ::Jobs::DiscussionBridgeGhostPublish.globally_enabled? && !Discourse.readonly_mode?

      if outbound
        return "unavailable" unless ::DiscussionBridge::CmsSourceLifecycle.globally_enabled?

        _, descriptor = ConnectionCheck.receiver(@connection.public_id)
        Publication.validate_policy!(descriptor)
      elsif !InboundPublishing.scope_allows?(@connection, saved["tag"])
        return "outside_scope"
      end

      scope.category(direction) ? "scoped" : "scheduled"
    rescue Error, ::DiscussionBridge::CmsProtocol::Error
      "unavailable"
    end

    def enable!(options)
      admin_url = text_option(options, "admin_url", max: 2048)
      credential = text_option(options, "ghost_credential", max: 128)
      if credential.blank?
        saved = saved_options
        unless admin_url == saved["admin_url"] && saved[@key_name].present?
          raise Error.new("ghost_setup_credential_required")
        end
        credential = saved.fetch(@key_name)
      end

      arguments = { connection_id: @connection.public_id, admin_url: admin_url }
      arguments[@key_name.to_sym] = credential
      if @direction == "from_discourse"
        arguments[:kind] = text_option(options, "kind", max: 8)
        arguments[:url_label] = text_option(options, "url_label", max: 191).presence
      else
        arguments[:tag] = text_option(options, "tag", max: 100)
      end
      @publisher.enable!(**arguments)
    end

    def text_option(options, name, max:)
      value = options[name]
      return "" if value.nil?
      unless value.is_a?(String) && value.bytesize <= max
        raise Error.new("ghost_setup_input_invalid")
      end
      value.strip
    end

    def saved_options
      encrypted = PluginStore.get(@publisher::SETTINGS, @connection.public_id)
      encrypted ? ::DiscussionBridge::CmsReceiptCipher.decrypt(encrypted) : {}
    rescue ::DiscussionBridge::CmsProtocol::Error => error
      raise Error.new("receiver_#{error.code}"), cause: nil
    end
  end
end
