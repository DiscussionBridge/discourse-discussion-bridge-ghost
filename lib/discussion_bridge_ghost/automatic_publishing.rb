# frozen_string_literal: true

module DiscussionBridgeGhost
  class AutomaticPublishing
    SETTINGS = "discussionbridge-ghost-automatic-publishing"
    PROGRESS = "discussionbridge-ghost-automatic-progress"
    INSPECTION_PROGRESS = "discussionbridge-ghost-inspection-progress"
    BATCH_SIZE = 5

    def self.enable!(connection_id:, admin_url:, admin_key:, kind: "post", url_label: nil)
      raise Error.new("ghost_kind_invalid") unless GhostSite::COLLECTIONS.key?(kind)
      connection, descriptor = ConnectionCheck.receiver(connection_id)
      Publication.validate_policy!(descriptor)
      ghost = GhostSite.new(admin_url, admin_key)
      Publication.validate_destination!(connection, descriptor, ghost)
      ghost.read_access

      options = { "admin_url" => admin_url, "admin_key" => admin_key, "kind" => kind, "url_label" => url_label }
      encrypted = ::DiscussionBridge::CmsReceiptCipher.encrypt(options)
      unless PluginStore.set(SETTINGS, connection.public_id, encrypted)
        raise Error.new("ghost_schedule_storage_failed")
      end
      ::DiscussionBridge::CmsSourceLifecycle.wake_connection(connection.id)
      true
    end

    def self.disable!(connection_id:)
      PluginStore.remove(SETTINGS, connection_id)
    end

    def self.run
      return unless SupervisedScope::CURRENT.active?("outbound") &&
        defined?(::DiscussionBridge::CmsSourceLifecycle) &&
        !Discourse.readonly_mode? && ::DiscussionBridge::CmsSourceLifecycle.globally_enabled?

      PluginStoreRow.where(plugin_name: SETTINGS).find_each do |row|
        next unless SupervisedScope::CURRENT.connection?("outbound", row.key)

        new(row.key).run
      rescue StandardError => error
        Rails.logger.error("DiscussionBridge Ghost outbound connection=#{row.key} error=#{error.class}")
      end
    end

    def initialize(connection_id)
      @connection_id = connection_id
    end

    def run
      return unless SupervisedScope::CURRENT.connection?("outbound", @connection_id)

      encrypted = PluginStore.get(SETTINGS, @connection_id)
      return unless encrypted

      @connection, @descriptor = ConnectionCheck.receiver(@connection_id)
      Publication.validate_policy!(@descriptor)
      options = ::DiscussionBridge::CmsReceiptCipher.decrypt(encrypted)
      inspect_waiting(encrypted, options)
      cursor = PluginStore.get(PROGRESS, @connection_id).to_i

      ready_batch(cursor).each do |intent_id, topic_id, mapping_id|
        break unless PluginStore.get(SETTINGS, @connection_id) == encrypted

        publish(topic_id, mapping_id, options)
        PluginStore.set(PROGRESS, @connection_id, intent_id)
      end
    rescue Error, ::DiscussionBridge::CmsProtocol::Error => error
      log(error)
    end

    private

    def inspect_waiting(encrypted, options)
      scope = DiscussionBridgeCmsAttentionInspection.joins(cms_mapping: { content_binding: :bridge_record })
        .where(content_connection_id: @connection.id, status: "waiting").order(:id)
      if (category_id = SupervisedScope::CURRENT.category("outbound"))
        scope = scope.where(discussion_bridge_bridge_records: { topic_id: Topic.where(category_id: category_id).select(:id) })
      end

      id = DiscussionBridgeCmsAttentionInspection.arel_table[:id]
      cursor = PluginStore.get(INSPECTION_PROGRESS, @connection_id).to_i
      columns = [id, :inspection_id, "discussion_bridge_bridge_records.topic_id"]
      rows = scope.where(id.gt(cursor)).limit(BATCH_SIZE).pluck(*columns)
      if rows.size < BATCH_SIZE && cursor.positive?
        rows += scope.where(id.lteq(cursor)).limit(BATCH_SIZE - rows.size).pluck(*columns)
      end
      rows.each do |row_id, inspection_id, topic_id|
        break unless PluginStore.get(SETTINGS, @connection_id) == encrypted

        inspect_publication(inspection_id, topic_id, options)
        PluginStore.set(INSPECTION_PROGRESS, @connection_id, row_id)
      end
    end

    def inspect_publication(inspection_id, topic_id, options)
      state = PluginStore.get(Publication::STORE, "#{@connection_id}:#{topic_id}")
      return unless state

      Publication.inspect_attention(
        inspection_id: inspection_id, topic_id: topic_id, kind: state.fetch("kind"),
        connection_id: @connection_id, admin_url: options.fetch("admin_url"),
        admin_key: options.fetch("admin_key"), supervised: true,
      )
    rescue Error, ::DiscussionBridge::CmsProtocol::Error => error
      log(error, topic_id)
    rescue StandardError => error
      Rails.logger.error("DiscussionBridge Ghost inspection connection=#{@connection_id} error=#{error.class}")
    end

    def ready_batch(cursor)
      scope = candidates
      if (category_id = SupervisedScope::CURRENT.category("outbound"))
        scope = scope.where(topic_id: Topic.where(category_id: category_id).select(:id))
      end
      columns = ["discussion_bridge_cms_source_intents.id", :topic_id, "ghost_mapping.mapping_id"]
      rows = scope.where("discussion_bridge_cms_source_intents.id > ?", cursor).limit(BATCH_SIZE).pluck(*columns)
      if rows.size < BATCH_SIZE && cursor.positive?
        rows += scope.where("discussion_bridge_cms_source_intents.id <= ?", cursor)
          .limit(BATCH_SIZE - rows.size).pluck(*columns)
      end
      rows
    end

    def candidates
      # R7 owns discovery and reconciliation. Its source intent admits an initial
      # publication, while an existing mapping must have pending receiver work.
      stream = DiscussionBridgeCmsSourceStream.where(
        content_connection_id: @connection.id, publication_lane: @descriptor.fetch("publication_lane"),
      )
      DiscussionBridgeCmsSourceIntent.where(cms_source_stream_id: stream.select(:id))
        .joins(<<~SQL)
          LEFT JOIN discussion_bridge_cms_mappings ghost_mapping
            ON ghost_mapping.content_connection_id = #{@connection.id}
           AND ghost_mapping.source_id = discussion_bridge_cms_source_intents.source_id
        SQL
        .where(<<~SQL)
          (ghost_mapping.id IS NULL AND discussion_bridge_cms_source_intents.state = 'active')
          OR (ghost_mapping.mapping_state = 'pending' AND discussion_bridge_cms_source_intents.state IN ('active', 'revoked'))
        SQL
        .order(:id)
    end

    def publish(topic_id, mapping_id, options)
      if (category_id = SupervisedScope::CURRENT.category("outbound"))
        return unless Topic.exists?(id: topic_id, category_id: category_id)
      end

      state = PluginStore.get(Publication::STORE, "#{@connection_id}:#{topic_id}")
      return if mapping_id && !state

      kind = state ? state.fetch("kind", "post") : options.fetch("kind")
      Publication.call(
        kind: kind, connection_id: @connection_id, topic_id: topic_id,
        admin_url: options.fetch("admin_url"), admin_key: options.fetch("admin_key"), url_label: options["url_label"],
        supervised: true,
      )
    rescue Error, ::DiscussionBridge::CmsProtocol::Error => error
      log(error, topic_id) unless %w[receiver_work_unavailable ghost_publication_busy].include?(error.code)
    end

    def log(error, topic_id = nil)
      Rails.logger.warn("DiscussionBridge Ghost schedule connection=#{@connection_id} topic=#{topic_id} code=#{error.code}")
    end
  end
end
