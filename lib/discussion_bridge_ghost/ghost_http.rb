# frozen_string_literal: true

require "digest"
require "net/http"
require "openssl"
require "timeout"
require "uri"

module DiscussionBridgeGhost
  # Fixed-origin outbound transport. Production uses Core's DNS/IP filtering,
  # never an environment proxy, ambient cookies, redirects or automatic retries.
  # The caller's guard is its current installation/work/lease authority check;
  # completing HTTP alone never grants a native receipt or verified ACK.
  class GhostHttp
    include ProtectedDiagnostics

    Response =
      Struct.new(:status, :headers, :bytes, keyword_init: true) do
        include ProtectedDiagnostics
      end

    # Private process-local dispatch facts only, not native ownership, current
    # authority, successful application or remote quiescence. A manufactured
    # object is not returned by actual_dispatch_evidence.
    DispatchEvidence =
      Struct.new(:value, :response, keyword_init: true) do
        include ProtectedDiagnostics
      end

    class Failure < Error
      attr_reader :status, :retry_after_seconds

      def initialize(status: nil, retry_after_seconds: nil)
        @status = status
        @retry_after_seconds = retry_after_seconds
        super(status == 429 ? "ghost_rate_limited" : "ghost_http_failed")
      end
    end

    def initialize(
      origin:,
      protocol:,
      guard:,
      api_key: nil,
      factory: nil,
      now: -> { Time.now.to_i },
      deadline_seconds: 10
    )
      valid_deadline =
        guard.respond_to?(:call) &&
          (deadline_seconds.is_a?(Integer) || deadline_seconds.is_a?(Float)) &&
          deadline_seconds.finite? && deadline_seconds.positive? &&
          deadline_seconds <= 10
      raise Error.new("configuration_invalid") unless valid_deadline
      @deadline_seconds = deadline_seconds
      @origin = protocol.origin_key(origin).freeze
      @protocol = protocol
      @address = URI.parse(@origin)
      @guard, @now = guard, now
      @api_key = api_key&.dup&.freeze
      AdminToken.generate(@api_key, now: @now.call) if @api_key
      @factory =
        factory ||
          ->(host, port) { ::FinalDestination::HTTP.new(host, port, nil) }
      @dispatch_evidence = EvidenceRegistry.new
      @dispatches = {}
      @dispatch_mutex = Mutex.new
    end

    def bound_origin?(protocol:, origin:)
      @protocol.equal?(protocol) && @origin == protocol.origin_key(origin)
    end

    def actual_dispatch_evidence(outcome, dispatch:)
      evidence = @dispatch_evidence[outcome]
      evidence if evidence && evidence.value.fetch("dispatch") == dispatch
    end

    def request(
      method,
      path,
      maximum_bytes:,
      payload: nil,
      authenticated: false,
      media: "json",
      allowed_statuses: [200],
      retained_body: nil,
      dispatch: nil
    )
      descriptor = nil
      dispatch_claimed = false
      may_have_sent = false
      response = nil
      unless %w[GET POST PUT].include?(method) && path.is_a?(String) &&
               path.ascii_only? && path.start_with?("/") &&
               !path.start_with?("//") &&
               !path.match?(/[\p{Space}\p{Cc}#\\]/) &&
               maximum_bytes.is_a?(Integer) && maximum_bytes.positive? &&
               %w[json html any].include?(media) &&
               allowed_statuses.is_a?(Array) && !allowed_statuses.empty? &&
               allowed_statuses.all? { |status|
                 status.is_a?(Integer) && status.between?(200, 599)
               }
        raise Error.new("configuration_invalid")
      end
      valid_body =
        retained_body.nil? ||
          (
            payload.nil? && retained_body.is_a?(String) &&
              retained_body.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          )
      raise Error.new("configuration_invalid") unless valid_body
      valid_authority =
        (
          !authenticated || (@api_key && path.start_with?("/ghost/api/admin/"))
        ) && (method != "GET" || (payload.nil? && retained_body.nil?)) &&
          (authenticated || method == "GET")
      raise Error.new("configuration_invalid") unless valid_authority
      # Validate the whole address without normalizing navigable dot segments or
      # introducing another authority. All API paths are assembled by the client.
      uri = URI.parse(@origin + path)
      unless uri.scheme == "https" && uri.host == @address.host &&
               uri.port == @address.port && !uri.userinfo && !uri.fragment
        raise Error.new("configuration_invalid")
      end
      if uri
           .path
           .split("/")
           .any? { |segment| %w[. ..].include?(segment.gsub(/%2e/i, ".")) }
        raise Error.new("configuration_invalid")
      end
      unless dispatch.nil?
        # Exact native command bytes are already retained. Snapshot them before
        # any guard callback; a mutated caller string cannot change the request
        # after its provenance was bound. Preparation is separately bounded and
        # precedes the fresh effect-authority check/network deadline.
        Timeout.timeout(@deadline_seconds, Timeout::Error) do
          descriptor, retained_body =
            prepare_dispatch(
              dispatch,
              method,
              path,
              retained_body,
              authenticated: authenticated
            )
          key = descriptor.fetch("dispatch")
          @dispatch_mutex.synchronize do
            if @dispatches.key?(key) || @dispatches.size >= 10_000
              raise Error.new("identity_conflict")
            end
            @dispatches[key] = true
            # Only THIS invocation's exclusive registration permits a no-send
            # observation. Interruption before this assignment is UNKNOWN,
            # never a new proof for a prior sent/pending invocation.
            dispatch_claimed = true
          end
          method = descriptor.fetch("method")
        end
      end
      @guard.call
      # The default Timeout internal exception bypasses Net::HTTP's
      # StandardError cleanup while TLS still owns a local, not-yet-installed
      # socket. An explicit exception traverses that cleanup; max_retries stays
      # zero, and an interrupted write still has an uncertain native outcome.
      Timeout.timeout(@deadline_seconds, Timeout::Error) do
        http = @factory.call(@address.hostname, @address.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = @deadline_seconds
        http.read_timeout = @deadline_seconds
        http.write_timeout = @deadline_seconds
        http.max_retries = 0
        headers = {
          "Accept" => {
            "json" => "application/json",
            "html" => "text/html",
            "any" => "*/*"
          }.fetch(media),
          "Accept-Encoding" => "identity",
          "User-Agent" => "DiscussionBridge-Ghost-native/0.4.0-alpha.1"
        }
        headers[
          "Authorization"
        ] = "Ghost #{AdminToken.generate(@api_key, now: @now.call)}" if authenticated
        body =
          (
            retained_body || (payload.nil? ? nil : JSON.generate(payload))
          )&.dup&.freeze
        headers["Content-Type"] = "application/json; charset=utf-8" if body
        klass = {
          "GET" => Net::HTTP::Get,
          "POST" => Net::HTTP::Post,
          "PUT" => Net::HTTP::Put
        }.fetch(method)
        outgoing = klass.new(uri.request_uri, headers)
        outgoing.body = body if body
        http.start do |connection|
          # Conservative boundary: entering this call MAY send bytes, even if
          # the call fails before receiving headers. Never infer no-send later.
          may_have_sent = true
          connection.request(outgoing) do |incoming|
            status = Integer(incoming.code, 10)
            if status == 429
              value = incoming["retry-after"].to_s
              cooldown =
                /\A[0-9]{1,8}\z/.match?(value) ? Integer(value, 10) : nil
              raise Failure.new(status: status, retry_after_seconds: cooldown)
            end
            if allowed_statuses.index(status).nil?
              raise Failure.new(status: status)
            end
            content_type = incoming["content-type"].to_s
            content_encoding = incoming["content-encoding"]
            unless content_encoding.nil? ||
                     content_encoding.downcase == "identity"
              raise Failure.new(status: status)
            end
            valid_media =
              media == "any" ||
                (
                  media == "json" &&
                    WireProtocol::JSON_MEDIA.match?(content_type)
                ) ||
                (
                  media == "html" &&
                    %r{\Atext/html(?:\s*;[^\r\n]*)?\z}i.match?(content_type)
                )
            raise Failure.new(status: status) unless valid_media
            declared = incoming["content-length"]
            if declared &&
                 (
                   !/\A[0-9]+\z/.match?(declared) ||
                     declared.to_i > maximum_bytes
                 )
              raise Failure.new(status: status)
            end
            bytes = +"".b
            incoming.read_body do |chunk|
              if chunk.bytesize > maximum_bytes - bytes.bytesize
                raise Failure.new(status: status)
              end
              bytes << chunk.b
            end
            if declared && bytes.bytesize != declared.to_i
              raise Failure.new(status: status)
            end
            retained_headers =
              %w[content-type content-encoding location retry-after]
                .to_h { |name| [name, incoming[name]&.dup&.freeze] }
                .freeze
            response =
              Response.new(
                status: status,
                headers: retained_headers,
                bytes: bytes.freeze
              )
            EvidenceRegistry.prepare(response)
            response.freeze
          end
        end
        @guard.call
      end
      result = response || raise(Failure.new)
      remember_dispatch(
        result,
        dispatch_claimed ? descriptor : nil,
        may_have_sent,
        response
      )
      result
    rescue Error => error
      remember_dispatch(
        error,
        dispatch_claimed ? descriptor : nil,
        may_have_sent,
        response
      )
      raise
    rescue StandardError
      # A failed POST/PUT may already have reached Ghost. The native coordinator
      # must retain its prior intent and look up ownership; never create again
      # merely because a reply or this transport's deadline was lost.
      error = Failure.new
      remember_dispatch(
        error,
        dispatch_claimed ? descriptor : nil,
        may_have_sent,
        response
      )
      raise error, cause: nil
    end

    private

    def prepare_dispatch(dispatch, method, path, body, authenticated:)
      unless dispatch.is_a?(Hash) &&
               dispatch.keys.sort == %w[attempt_id command_id execution_id] &&
               dispatch.values.all? { |id|
                 id.is_a?(String) && SecretEnvelope::UUID.match?(id)
               } && authenticated && %w[POST PUT].include?(method) &&
               body.is_a?(String)
        raise Error.new("configuration_invalid")
      end
      snapshot = body.dup.force_encoding(Encoding::UTF_8).freeze
      identity = dispatch.transform_values { |id| id.dup.freeze }.freeze
      descriptor = {
        "format" => "ghost-http-dispatch-1",
        "dispatch" => identity,
        "origin" => @origin,
        "method" => method.dup.freeze,
        "path" => path.dup.freeze,
        "body_sha256" => Digest::SHA256.hexdigest(snapshot).freeze
      }.freeze
      [descriptor, snapshot]
    end

    def remember_dispatch(outcome, descriptor, may_have_sent, response)
      return unless descriptor
      phase =
        if response
          "response_received"
        elsif may_have_sent
          "may_have_sent"
        else
          "not_sent"
        end
      @dispatch_evidence.retain(
        outcome,
        DispatchEvidence.new(
          value: descriptor.merge("phase" => phase.freeze).freeze,
          response: response
        ).freeze
      )
    end
  end
end
