# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module DiscussionBridgeGhost
  class Error < StandardError
    attr_reader :code, :status

    def initialize(code, status: nil)
      @code = code
      @status = status
      super(status ? "#{code} (HTTP #{status})" : code)
    end
  end

  class GhostSite
    API_VERSION = "v6.0"
    MAX_BYTES = 8 * 1024 * 1024
    COLLECTIONS = { "post" => "posts", "page" => "pages" }.freeze
    NATIVE_ID = /\A[0-9a-f]{24}\z/
    TAG = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

    module Transport
      def public_article(url)
        request(Net::HTTP::Get, https_url(url), headers: { "Accept" => "text/html" }, statuses: [200, 404, 410])
      end

      private

      def https_url(value)
        raise Error.new("ghost_url_invalid") unless value.is_a?(String) && value.valid_encoding?
        uri = URI.parse(value)
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
          raise Error.new("ghost_url_invalid")
        end
        uri
      rescue URI::InvalidURIError
        raise Error.new("ghost_url_invalid"), cause: nil
      end

      def request(method, uri, headers:, statuses:, body: nil)
        request = method.new(uri.request_uri, headers)
        if body
          request.content_type = "application/json"
          request.body = JSON.generate(body)
        end
        http = FinalDestination::HTTP.new(uri.hostname, uri.port, nil)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = http.read_timeout = http.write_timeout = 5
        http.max_retries = 0
        status = nil
        raw = +"".b
        Timeout.timeout(15) do
          http.start do |session|
            session.request(request) do |response|
              status = response.code.to_i
              raise Error.new("ghost_http_error", status: status) unless statuses.include?(status)
              response.read_body do |chunk|
                raise Error.new("ghost_response_too_large") if raw.bytesize + chunk.bytesize > MAX_BYTES
                raw << chunk
              end
            end
          end
        end
        [status, raw.force_encoding(Encoding::UTF_8)]
      rescue SocketError, SystemCallError, Timeout::Error, IOError, Net::HTTPBadResponse, OpenSSL::SSL::SSLError
        raise Error.new("ghost_transport_failed"), cause: nil
      end
    end
    private_constant :Transport

    include Transport
    extend Transport

    def initialize(admin_url, admin_key = nil, content_key: nil)
      @admin = https_url(admin_url)
      if content_key
        unless content_key.is_a?(String) && /\A[0-9a-f]{26}\z/i.match?(content_key)
          raise Error.new("ghost_content_key_invalid")
        end
        @content_key = content_key
        return
      end
      key = /\A([0-9a-f]{24}):([0-9a-f]{64})\z/i.match(admin_key) if admin_key.is_a?(String)
      raise Error.new("ghost_admin_key_invalid") unless key
      @key_id = key[1]
      @key_secret = [key[2]].pack("H*")
    end

    def site
      value = admin_request(Net::HTTP::Get, "site/", authenticate: false)["site"]
      unless value.is_a?(Hash) && text_field?(value["version"]) && !value["version"].empty?
        raise Error.new("ghost_response_invalid")
      end
      https_url(value["url"])
      value
    rescue Error => error
      raise unless error.code == "ghost_url_invalid"
      raise Error.new("ghost_response_invalid"), cause: nil
    end

    def read_access
      %w[posts pages].each do |collection|
        result = admin_request(Net::HTTP::Get, "#{collection}/?limit=1&fields=id")[collection]
        unless result.is_a?(Array) && result.length <= 1 &&
               result.all? { |item| item.is_a?(Hash) && valid_native_id?(item["id"]) }
          raise Error.new("ghost_response_invalid")
        end
      end
    end

    def article_by_slug(kind, slug)
      collection = COLLECTIONS.fetch(kind)
      object(admin_request(Net::HTTP::Get, "#{collection}/slug/#{slug}/?formats=html"), collection)
    rescue Error => error
      raise unless error.status == 404
      nil
    end

    def article(kind, id)
      collection = COLLECTIONS.fetch(kind)
      id = native_id!(id)
      object(admin_request(Net::HTTP::Get, "#{collection}/#{id}/?formats=html"), collection, id: id)
    end

    def public_entries(kind, tag:, limit:, after_id: nil)
      filter = public_filter(tag)
      filter += "+id:>'#{native_id!(after_id)}'" if after_id
      entries = content_entries(kind, filter: filter, limit: limit)
      ids = entries.map { |entry| entry.fetch("id") }
      unless ids == ids.sort.uniq && (!after_id || ids.empty? || ids.first > after_id)
        raise Error.new("ghost_response_invalid")
      end
      entries
    end

    def public_entry(kind, id:, tag:)
      id = native_id!(id)
      entry = content_entries(kind, filter: "#{public_filter(tag)}+id:'#{id}'", limit: 1).first
      raise Error.new("ghost_response_invalid") if entry && entry["id"] != id
      entry
    end

    def create_draft(kind, slug:, title:, marker:)
      collection = COLLECTIONS.fetch(kind)
      fields = { slug: slug, title: title, status: "draft", lexical: lexical(marker) }
      response = admin_request(Net::HTTP::Post, "#{collection}/?formats=html", body: { collection => [fields] }, statuses: [201])
      object(response, collection)
    end

    def publish(kind, article, title:, html:)
      update(kind, article, title: title, lexical: lexical(html), status: "published")
    end

    def withdraw(kind, article)
      update(kind, article, status: "draft")
    end

    private

    def public_filter(tag)
      unless tag.is_a?(String) && tag.bytesize <= 100 && TAG.match?(tag)
        raise Error.new("ghost_source_tag_invalid")
      end
      "visibility:public+tag:#{tag}"
    end

    def content_entries(kind, filter:, limit:)
      collection = COLLECTIONS.fetch(kind)
      uri = @admin.dup
      uri.path = "#{uri.path.delete_suffix('/')}/ghost/api/content/#{collection}/"
      uri.query = URI.encode_www_form(
        key: @content_key, filter: filter, limit: limit, order: "id asc", include: "tags,authors", formats: "html",
      )
      headers = { "Accept" => "application/json", "Accept-Version" => API_VERSION }
      _, raw = request(Net::HTTP::Get, uri, headers: headers, statuses: [200])
      body = JSON.parse(raw)
      entries = body[collection] if body.is_a?(Hash)
      unless entries.is_a?(Array) && entries.size <= limit &&
             entries.all? { |entry| entry.is_a?(Hash) && valid_native_id?(entry["id"]) }
        raise Error.new("ghost_response_invalid")
      end
      entries
    rescue JSON::ParserError, EncodingError
      raise Error.new("ghost_response_invalid"), cause: nil
    end

    def update(kind, article, **fields)
      collection = COLLECTIONS.fetch(kind)
      raise Error.new("ghost_response_invalid") unless article.is_a?(Hash)
      id = native_id!(article["id"])
      fields[:updated_at] = timestamp!(article["updated_at"])
      response = admin_request(Net::HTTP::Put, "#{collection}/#{id}/?formats=html", body: { collection => [fields] })
      object(response, collection, id: id)
    end

    def native_id!(id)
      raise Error.new("native_ownership_conflict") unless valid_native_id?(id)
      id
    end

    def valid_native_id?(id)
      text_field?(id) && NATIVE_ID.match?(id)
    end

    def text_field?(value)
      value.is_a?(String) && value.valid_encoding?
    end

    def timestamp!(value)
      raise Error.new("ghost_response_invalid") unless text_field?(value)
      Time.iso8601(value)
      value
    rescue ArgumentError
      raise Error.new("ghost_response_invalid"), cause: nil
    end

    def object(body, collection, id: nil)
      entries = body[collection] if body.is_a?(Hash)
      unless entries.is_a?(Array) && entries.size == 1 && entries.first.is_a?(Hash)
        raise Error.new("ghost_response_invalid")
      end
      article = entries.first
      unless valid_native_id?(article["id"]) && (!id || article["id"] == id) &&
             %w[slug status url title html].all? { |field| text_field?(article[field]) }
        raise Error.new("ghost_response_invalid")
      end
      timestamp!(article["updated_at"])
      article
    end

    def lexical(html)
      JSON.generate(root: {
        children: [{ type: "html", version: 1, html: html }],
        direction: "ltr", format: "", indent: 0, type: "root", version: 1,
      })
    end

    def admin_request(method, path, authenticate: true, body: nil, statuses: [200])
      uri = @admin.dup
      resource, query = path.split("?", 2)
      uri.path = "#{uri.path.delete_suffix('/')}/ghost/api/admin/#{resource}"
      uri.query = query
      headers = { "Accept" => "application/json", "Accept-Version" => API_VERSION }
      headers["Authorization"] = "Ghost #{token}" if authenticate
      _, raw = request(method, uri, headers: headers, body: body, statuses: statuses)
      value = JSON.parse(raw)
      raise Error.new("ghost_response_invalid") unless value.is_a?(Hash)
      value
    rescue JSON::ParserError, EncodingError
      raise Error.new("ghost_response_invalid"), cause: nil
    end

    def token
      now = Time.now.to_i
      header = { alg: "HS256", typ: "JWT", kid: @key_id }
      claims = { iat: now, exp: now + 60, aud: "/admin/" }
      unsigned = [header, claims].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }.join(".")
      signature = OpenSSL::HMAC.digest("SHA256", @key_secret, unsigned)
      "#{unsigned}.#{Base64.urlsafe_encode64(signature, padding: false)}"
    end
  end
end
