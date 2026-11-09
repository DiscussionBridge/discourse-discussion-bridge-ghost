# frozen_string_literal: true

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

    def self.run
      PluginStoreRow.where(plugin_name: SETTINGS).find_each do |row|
        new(row.key).run
      end
    end

    def initialize(connection_id)
      @connection_id = connection_id
    end

    def run
      encrypted = PluginStore.get(SETTINGS, @connection_id)
      return unless encrypted

      @connection, @descriptor = ConnectionCheck.receiver(@connection_id)
      self.class.validate_direction!(@descriptor)
      options = ::DiscussionBridge::CmsReceiptCipher.decrypt(encrypted)
      @tag = options.fetch("tag")
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
      return unless entry["visibility"] == "public" && entry["access"] == true &&
        Array(entry["tags"]).any? { |tag| tag.is_a?(Hash) && tag["slug"] == @tag }
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
      input = { "mutation_id" => SecureRandom.uuid, "bridge_record" => source }
      raise Error.new("body_too_large") if JSON.generate(input).bytesize > 65_536

      response = @records.resolve(input)
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

    def source_record(kind, entry, fragment)
      canonical = ::DiscussionBridge::CanonicalSource.call(
        connection_id: @connection_id, source_url: entry.fetch("url"),
      ).source_url
      ConnectionCheck.check_site!(@connection, @descriptor, canonical)
      # Use the pinned receiver's target-preserving conversion before hashing.
      ::DiscussionBridge::PortableContent.send(:resolve_references!, fragment, canonical)
      html = fragment.to_html
      raise Error.new("body_too_large") if html.bytesize > 49_152
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

    def log(code, id = nil)
      Rails.logger.warn("DiscussionBridge Ghost inbound connection=#{@connection_id} source=#{id} code=#{code}")
    end
  end
end
