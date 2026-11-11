# frozen_string_literal: true

require "cgi"
require "digest"
require "securerandom"
require "time"

module DiscussionBridgeGhost
  class InboundPublishing
    SETTINGS = "discussionbridge-ghost-inbound-publishing"
    PROGRESS = "discussionbridge-ghost-inbound-progress"
    REFUSALS = "discussionbridge-ghost-inbound-refusals"
    BATCH_SIZE = 5

    def self.enable!(connection_id:, admin_url:, content_key:, tag:)
      unless tag.is_a?(String) && tag.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) && tag.bytesize <= 100
        raise Error.new("ghost_source_tag_invalid")
      end
      connection, descriptor = ConnectionCheck.receiver(connection_id)
      validate_direction!(descriptor)
      ghost = GhostSite.new(admin_url, content_key: content_key)
      ConnectionCheck.check_site!(connection, descriptor, ghost.site.fetch("url"))
      GhostSite::COLLECTIONS.each_key { |kind| ghost.public_entries(kind, tag: tag, limit: 1) }
      options = { "admin_url" => admin_url, "content_key" => content_key, "tag" => tag }
      unless PluginStore.set(SETTINGS, connection_id, ::DiscussionBridge::CmsReceiptCipher.encrypt(options))
        raise Error.new("ghost_schedule_storage_failed")
      end
      true
    end

    def self.disable!(connection_id:)
      PluginStore.remove(SETTINGS, connection_id)
    end

    def self.validate_direction!(descriptor)
      raise Error.new("ghost_inbound_direction_required") unless descriptor.fetch("directions").include?("to_discourse")
    end

    def self.current_source?(binding)
      identity = /\Aghost-(post|page):([0-9a-f]{24})\z/.match(binding.external_id)
      return false unless identity

      connection_id = binding.content_connection.public_id
      encrypted = PluginStore.get(SETTINGS, connection_id)
      return false unless encrypted

      options = ::DiscussionBridge::CmsReceiptCipher.decrypt(encrypted)
      return false unless options.is_a?(Hash)

      tag = options.fetch("tag")
      ghost = GhostSite.new(options.fetch("admin_url"), content_key: options.fetch("content_key"))
      entry = ghost.public_entry(identity[1], id: identity[2], tag: tag)
      return false unless visible_entry?(entry, tag) && entry["id"] == identity[2] && entry["url"].is_a?(String)

      canonical = ::DiscussionBridge::CanonicalSource.call(connection_id: connection_id, source_url: entry["url"]).source_url
      canonical == binding.canonical_url && PluginStore.get(SETTINGS, connection_id) == encrypted
    rescue KeyError, TypeError
      false
    end

    def self.visible_entry?(entry, tag)
      entry.is_a?(Hash) && entry["visibility"] == "public" && entry["access"] == true &&
        entry["tags"].is_a?(Array) && entry["tags"].any? { |item| item.is_a?(Hash) && item["slug"] == tag }
    end

    def self.run
      return unless SupervisedScope::CURRENT.active?("inbound") && !Discourse.readonly_mode?

      PluginStoreRow.where(plugin_name: SETTINGS).find_each do |row|
        next unless SupervisedScope::CURRENT.connection?("inbound", row.key)

        new(row.key).run
      rescue StandardError => error
        Rails.logger.error("DiscussionBridge Ghost inbound connection=#{row.key} error=#{error.class}")
      end
    end

    def initialize(connection_id)
      @connection_id = connection_id
    end

    def run
      return unless SupervisedScope::CURRENT.connection?("inbound", @connection_id)

      encrypted = PluginStore.get(SETTINGS, @connection_id)
      return unless encrypted

      @connection, @descriptor = ConnectionCheck.receiver(@connection_id)
      self.class.validate_direction!(@descriptor)
      options = ::DiscussionBridge::CmsReceiptCipher.decrypt(encrypted)
      @tag = options.fetch("tag")
      return unless inbound_scope?

      @ghost = GhostSite.new(options.fetch("admin_url"), content_key: options.fetch("content_key"))
      ConnectionCheck.check_site!(@connection, @descriptor, @ghost.site.fetch("url"))
      @records = ::DiscussionBridge::CmsRecordStore.new(@connection)
      GhostSite::COLLECTIONS.each_key { |kind| poll(kind, encrypted) }
    rescue Error, ::DiscussionBridge::CmsProtocol::Error => error
      log(error.code)
    end

    private

    def poll(kind, encrypted)
      key = "#{@connection_id}:#{@tag}:#{kind}"
      cursor = PluginStore.get(PROGRESS, key)
      entries = @ghost.public_entries(kind, tag: @tag, limit: BATCH_SIZE, after_id: cursor)
      entries.each do |entry|
        return unless PluginStore.get(SETTINGS, @connection_id) == encrypted
        publish(kind, entry)
      end
      PluginStore.set(PROGRESS, key, entries.size == BATCH_SIZE ? entries.last.fetch("id") : nil)
    rescue Error => error
      log(error.code)
    end

    def publish(kind, entry)
      id = entry.fetch("id")
      return unless self.class.visible_entry?(entry, @tag)
      html = entry.fetch("html")
      return unless html.is_a?(String) && !html.include?("<!--members-only-->")
      # Skip Ghost articles already owned by a Discourse publication.
      fragment = ::DiscussionBridge::PortableContent.article_fragment(html)
      return if fragment.at_css("section[data-db-owner]") ||
        DiscussionBridgeCmsMapping.exists?(destination_native_id: id)

      source = source_record(kind, entry, fragment)
      binding = @connection.content_bindings.find_by(external_id: source.fetch("external_id"))
      revision = binding&.bridge_record&.cms_source_publication&.fetch("revision", nil)
      return if revision == source.fetch("source_revision")

      refusal_key = "#{@connection_id}:#{kind}:#{id}:#{source.fetch('source_revision')}"
      return if PluginStore.get(REFUSALS, refusal_key)
      status, = @ghost.public_article(source.fetch("canonical_url"))
      raise Error.new("ghost_source_not_public", status: status) unless status == 200
      source["expected_source_revision"] = revision
      source = publication_representation(source, fragment)
      input = { "mutation_id" => SecureRandom.uuid, "bridge_record" => source }

      response = resolve(input)
      return unless response

      log(response.body.fetch("reason"), id) unless [200, 201].include?(response.status)
    rescue ::DiscussionBridge::CmsProtocol::Error => error
      if input && %w[invalid_field content_preservation_unavailable].include?(error.code)
        PluginStore.set(REFUSALS, refusal_key, {
          "code" => error.code, "request" => ::DiscussionBridge::CmsReceiptCipher.encrypt(input),
        })
      end
      log(error.code, id)
    rescue Error => error
      log(error.code, id)
    rescue ::DiscussionBridge::PortableContent::PreparationUnavailable => error
      log(error.diagnostic_code, id)
    rescue ArgumentError, KeyError
      log("ghost_source_metadata_invalid", id)
    end

    def inbound_scope?
      self.class.scope_allows?(@connection, @tag)
    end

    def self.scope_allows?(connection, tag)
      scope = SupervisedScope::CURRENT
      return true unless scope.category("inbound")

      descriptor = ::DiscussionBridge::CmsConfiguration.current!(connection, required_direction: "to_discourse")
      lane = ::DiscussionBridge::LanePolicies.resolve(
        value: SiteSetting.discussion_bridge_lane_policies, lane: descriptor.fetch("publication_lane"),
      )
      category_id = lane.category_id || connection.default_category_id || SiteSetting.discussion_bridge_effective_category_id
      lane.allowed && scope.inbound?(connection.public_id, category_id.to_i, tag)
    end

    def resolve(input)
      category_id = SupervisedScope::CURRENT.category("inbound")
      return @records.resolve(input) unless category_id

      @connection.with_lock do
        next unless inbound_scope?

        external_id = input.fetch("bridge_record").fetch("external_id")
        existing = @connection.content_bindings.find_by(external_id: external_id)
        if existing
          topic = Topic.lock.find_by(id: existing.bridge_record.topic_id)
          next unless topic&.category_id == category_id
        end

        response = @records.resolve(input)
        if [200, 201].include?(response.status) &&
           !Topic.exists?(id: response.body.fetch("topic_id"), category_id: category_id)
          raise Error.new("ghost_supervised_scope_changed")
        end
        response
      end
    end

    def source_record(kind, entry, fragment)
      unless %w[url title created_at updated_at].all? { |field| entry[field].is_a?(String) }
        raise Error.new("ghost_source_metadata_invalid")
      end
      canonical = ::DiscussionBridge::CanonicalSource.call(
        connection_id: @connection_id, source_url: entry.fetch("url"),
      ).source_url
      ConnectionCheck.check_site!(@connection, @descriptor, canonical)
      # Use the pinned receiver's target-preserving conversion before hashing.
      ::DiscussionBridge::PortableContent.send(:resolve_references!, fragment, canonical)
      html = fragment.to_html
      authors = entry["authors"]
      unless authors.is_a?(Array) && authors.all? { |author| author.is_a?(Hash) }
        raise Error.new("ghost_source_metadata_invalid")
      end
      authors = authors.map { |author| author.slice("id", "name") }
      source = {
        "direction" => "to_discourse", "external_id" => "ghost-#{kind}:#{entry.fetch('id')}",
        "canonical_url" => canonical, "title" => entry.fetch("title"),
        "content_html" => html, "published" => true,
        "source_created_at" => Time.iso8601(entry.fetch("created_at")).utc.iso8601(3),
        "source_updated_at" => Time.iso8601(entry.fetch("updated_at")).utc.iso8601(3),
        "source_content_sha256" => Digest::SHA256.hexdigest(html.b), "source_content_bytes" => html.bytesize,
        "source_authors" => authors, "representation" => { "kind" => "full" },
      }
      source["primary_source_author_id"] = authors.first.fetch("id") if authors.any?
      source["source_revision"] = Digest::SHA256.hexdigest(JSON.generate(source))
      source
    end

    def publication_representation(source, fragment)
      codec = ::DiscussionBridge::CmsGeneratedExcerpt
      full_bytes = ::DiscussionBridge::CmsProtocol.semantic_identity(
        { "mutation_id" => codec::MEASUREMENT_ID, "bridge_record" => source },
      ).bytesize
      return source if source.fetch("source_content_bytes") <= 49_152 && full_bytes <= 65_536

      # Keep complete top-level HTML nodes. A single large block still has a
      # usable excerpt without splitting markup or multibyte characters.
      article = +""
      fragment.children.each do |node|
        html = node.to_html
        break if article.bytesize + html.bytesize > 8_192 || html.downcase.include?(codec::MARKER)
        article << html
      end
      if article.strip.empty?
        prefix = fragment.text.strip.each_char.take(1_024).join
        raise Error.new("content_preservation_unavailable") if prefix.empty?

        article = "<p>#{CGI.escapeHTML(prefix)}</p>"
      end
      canonical = source.fetch("canonical_url")
      selected = source.merge(
        "content_html" => article + codec.link(canonical),
        "representation" => {
          "kind" => "generated_excerpt", "article_content_bytes" => article.bytesize,
          "article_content_sha256" => Digest::SHA256.hexdigest(article.b), "read_more_url" => canonical,
          "selection_full_request_bytes" => full_bytes, "selection_source_revision" => source.fetch("source_revision"),
        },
      )
      codec.validate_envelope!(selected)
    end

    def log(code, id = nil)
      Rails.logger.warn("DiscussionBridge Ghost inbound connection=#{@connection_id} source=#{id} code=#{code}")
    end
  end
end
