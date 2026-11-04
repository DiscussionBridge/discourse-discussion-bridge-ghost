# frozen_string_literal: true

require "cgi"
require "json"

module DiscussionBridgeGhost
  # Native Ghost API translation, separate from receiver protocol JSON. Native
  # API metadata may contain legitimate decimals; integer wire rules must not
  # silently reinterpret it. Native IDs and resource type are checked explicitly.
  class GhostAdminClient
    include ProtectedDiagnostics

    def initialize(http:)
      @http = http
    end

    def get(id, kind: "post", maximum_bytes: 262_144, source: false)
      valid_id =
        id.is_a?(String) && /\A[a-f0-9]{24}\z/.match?(id) &&
          (!source || kind == "post")
      raise Error.new("identity_conflict") unless valid_id
      resource = resource_type(kind)
      query = "formats=html,lexical&include=authors,tags"
      data = read("/ghost/api/admin/#{resource}/#{id}/?#{query}", maximum_bytes)
      values = native_objects(data, kind)
      unless values.length == 1 && values.first["id"] == id
        raise Error.new("identity_conflict")
      end
      values.first
    end

    def find_by_resource(resource_id, maximum_bytes: 262_144)
      unless resource_id.is_a?(String) &&
               SecretEnvelope::UUID.match?(resource_id)
        raise Error.new("identity_conflict")
      end
      lookup(
        "tag:hash-discussionbridge-resource-#{resource_id}",
        maximum_bytes,
        3
      )
    end

    def find_by_slug(slug, maximum_bytes: 262_144)
      unless slug.is_a?(String) && slug.bytesize.between?(1, 191) &&
               /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.match?(slug)
        raise Error.new("identity_conflict")
      end
      values = lookup("slug:#{slug}", maximum_bytes, 2)
      unless values.all? { |value| value["slug"] == slug }
        raise Error.new("identity_conflict")
      end
      values
    end

    # One bounded page, not an unbounded in-memory crawl. The job will persist
    # snapshot identity/continuation and atomically advance after staging it.
    def catalog_page(kind, page:, maximum_bytes: 262_144)
      unless %w[authors taxonomy].include?(kind) && page.is_a?(Integer) &&
               page.positive?
        raise Error.new("configuration_invalid")
      end
      resource = kind == "authors" ? "users" : "tags"
      fields = kind == "authors" ? "id,name,status" : "id,name,slug"
      data =
        read(
          "/ghost/api/admin/#{resource}/?limit=100&page=#{page}&fields=#{CGI.escape(fields)}",
          maximum_bytes
        )
      items = data[resource]
      meta = data["meta"]
      raise Error.new("response_invalid") unless meta.is_a?(Hash)
      pagination = meta["pagination"]
      valid_page =
        items.is_a?(Array) && items.length <= 100 && pagination.is_a?(Hash) &&
          pagination["page"].is_a?(Integer) && pagination["page"] == page &&
          pagination["total"].is_a?(Integer) && pagination["total"] >= 0 &&
          pagination.key?("next") &&
          (
            pagination["next"].nil? ||
              (
                pagination["next"].is_a?(Integer) &&
                  pagination["next"] == page + 1
              )
          )
      raise Error.new("response_invalid") unless valid_page
      selected_field = kind == "authors" ? "status" : "slug"
      ids =
        items.map do |item|
          valid_item =
            item.is_a?(Hash) && item["id"].is_a?(String) &&
              /\A[a-f0-9]{24}\z/.match?(item["id"]) &&
              item["name"].is_a?(String) &&
              (!item.key?(selected_field) || item[selected_field].is_a?(String))
          raise Error.new("response_invalid") unless valid_item
          item["id"]
        end
      if items.length > pagination["total"] ||
           (!pagination["next"].nil? && items.empty?)
        raise Error.new("response_invalid")
      end
      raise Error.new("identity_conflict") unless ids.uniq.length == ids.length
      selected_fields =
        kind == "authors" ? %w[id name status] : %w[id name slug]
      {
        "items" => items.map { |item| item.slice(*selected_fields) },
        "pagination" => pagination.slice("page", "total", "next")
      }
    end

    # One bounded slice of the operator's selected native IDs, not a crawl of
    # the complete catalog. A coordinator may stage larger selections in
    # successive slices. Returned labels are metadata, NOT current authority or
    # an instruction to change a post. The bound HTTP guard still runs for this
    # exact read and no private staff fields leave the projection.
    def selected_metadata(kind, ids:, maximum_bytes: 262_144)
      unless %w[authors taxonomy].include?(kind) && ids.is_a?(Array) &&
               ids.length <= 100 && ids.uniq == ids &&
               ids.all? { |id|
                 id.is_a?(String) && /\A[a-f0-9]{24}\z/.match?(id)
               }
        raise Error.new("configuration_invalid")
      end
      return [] if ids.empty?

      resource = kind == "authors" ? "users" : "tags"
      fields = kind == "authors" ? %w[id name status] : %w[id name slug]
      filter = CGI.escape("id:[#{ids.join(",")}]")
      data =
        read(
          "/ghost/api/admin/#{resource}/?filter=#{filter}&limit=#{ids.length}&page=1&fields=#{CGI.escape(fields.join(","))}",
          maximum_bytes
        )
      items = data[resource]
      pagination = data.dig("meta", "pagination") if data["meta"].is_a?(Hash)
      unless items.is_a?(Array) && items.length == ids.length &&
               pagination.is_a?(Hash) && pagination["page"].is_a?(Integer) &&
               pagination["page"] == 1 && pagination["total"].is_a?(Integer) &&
               pagination["total"] == ids.length && pagination.key?("next") &&
               pagination["next"].nil? &&
               items.all? { |item|
                 item.is_a?(Hash) && item["id"].is_a?(String) &&
                   /\A[a-f0-9]{24}\z/.match?(item["id"]) &&
                   item["name"].is_a?(String) && item[fields.last].is_a?(String)
               }
        raise Error.new("response_invalid")
      end
      by_id = items.to_h { |item| [item.fetch("id"), item] }
      unless by_id.keys.sort == ids.sort && by_id.length == items.length
        raise Error.new("identity_conflict")
      end
      # Native sort order must not change the selected primary author/tag.
      ids.map { |id| by_id.fetch(id).slice(*fields) }
    end

    private

    def lookup(filter, maximum_bytes, limit)
      %w[post page].flat_map do |kind|
        resource = resource_type(kind)
        data =
          read(
            "/ghost/api/admin/#{resource}/?filter=#{CGI.escape(filter)}&limit=#{limit}&formats=html,lexical&include=authors,tags",
            maximum_bytes
          )
        values = native_objects(data, kind)
        raise Error.new("response_invalid") if values.length > limit
        values
      end
    end

    def resource_type(kind)
      raise Error.new("configuration_invalid") if %w[post page].index(kind).nil?
      "#{kind}s"
    end

    def native_objects(data, kind)
      resource = resource_type(kind)
      other = kind == "post" ? "pages" : "posts"
      values = data[resource]
      valid_objects =
        values.is_a?(Array) && !data.key?(other) &&
          values.all? do |item|
            item.is_a?(Hash) && item["id"].is_a?(String) &&
              /\A[a-f0-9]{24}\z/.match?(item["id"]) &&
              (!item.key?("type") || item["type"] == kind)
          end
      raise Error.new("identity_conflict") unless valid_objects
      values.map { |item| item.merge("type" => kind) }
    end

    def read(path, maximum_bytes)
      response =
        @http.request(
          "GET",
          path,
          maximum_bytes: maximum_bytes,
          authenticated: true
        )
      bytes = response.bytes.dup.force_encoding(Encoding::UTF_8)
      unless bytes.valid_encoding? && !bytes.start_with?("\uFEFF")
        raise Error.new("response_invalid")
      end
      value = JSON.parse(bytes, object_class: WireJson::StrictObject)
      unless value.is_a?(Hash) && finite_numbers?(value)
        raise Error.new("response_invalid")
      end
      value
    rescue JSON::ParserError, EncodingError, ArgumentError
      raise Error.new("response_invalid"), cause: nil
    end

    def finite_numbers?(value)
      case value
      when Hash
        value.values.all? { |member| finite_numbers?(member) }
      when Array
        value.all? { |member| finite_numbers?(member) }
      when Float
        value.finite?
      else
        true
      end
    end
  end
end
