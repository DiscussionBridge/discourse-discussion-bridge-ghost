# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"

module DiscussionBridgeGhost
  # Exact private request/response history, separate from publication identity.
  # Commit an intent before dispatch; an uncertain outcome keeps that SAME body.
  # Completed/refused results are observations, not a new grant of authority for
  # a native write or a replacement for the coordinator's current Work checks.
  class MutationJournal
    include ProtectedDiagnostics

    attr_reader :context

    def initialize(
      installation:,
      protocol:,
      transport:,
      lease:,
      context: nil,
      now: -> { Time.now.utc }
    )
      unless transport.is_a?(RackTransport) &&
               transport.bound_to?(
                 protocol,
                 installation.connection_public_id
               ) && lease.is_a?(NativeLock::Lease) &&
               lease.native_target_id == installation.native_target.public_id
        raise Error.new("identity_conflict")
      end
      @installation, @protocol, @transport, @lease, @now =
        installation,
        protocol,
        transport,
        lease,
        now
      @context =
        context ||
          ExecutionContext.new(
            installation: installation,
            protocol: protocol,
            transport: transport,
            lease: lease
          )
      unless @context.is_a?(ExecutionContext) &&
               @context.bound_to?(
                 installation: installation,
                 protocol: protocol,
                 transport: transport,
                 lease: lease
               )
        raise Error.new("identity_conflict")
      end
      @binding = @context.binding
    end

    def call(operation_key, route_id, path: {}, retained_body: nil, &make_body)
      assert_no_transaction!
      assert_current!
      unless operation_key.is_a?(String) &&
               operation_key.bytesize.between?(1, 1024) &&
               operation_key.valid_encoding? &&
               !operation_key.match?(/[\p{Cc}]/)
        raise Error.new("identity_conflict")
      end
      operation, packet =
        prepare(operation_key, route_id, path, retained_body, make_body)
      previous = operation.private_response
      if previous
        result = retained_result(packet, previous)
        return result unless operation.state == "pending"
        return result if Time.iso8601(previous.fetch("retry_at")) > @now.call
      end
      assert_current!
      assert_no_transaction!
      result = @transport.execute(packet)
      retain_response(operation, packet, result)
      result
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    # Retained genuine dispatch evidence survives a restart. Merely parsing an
    # invented rejection cannot populate this journal's authenticated receipt.
    # The coordinator must still obtain current proof before a deliberate retry.
    def confirmed_source_refusal(operation_key)
      assert_current!
      operation =
        @installation.mutations.find_by(
          operation_key: operation_key,
          state: "refused"
        )
      return nil unless operation
      packet = retained_packet(operation)
      receipt = operation.private_response
      result = retained_result(packet, receipt)
      return nil unless result.source_refusal_shape?
      expected = {
        "route_id" => packet.route_id,
        "connection_id" => @installation.connection_public_id,
        "request_sha256" => packet.request_sha256,
        "status" => result.status,
        "envelope" => result.value
      }
      unless receipt.fetch("dispatch_proof") == expected
        raise Error.new("identity_conflict")
      end
      result
    rescue KeyError, ArgumentError, TypeError
      raise Error.new("identity_conflict"), cause: nil
    end

    private

    def assert_current!
      @context.assert!
    end

    def assert_no_transaction!
      @context.outside_transaction!
    end

    def prepare(key, route_id, path, retained_body, make_body)
      operation = nil
      packet = nil
      @installation.with_lock do
        assert_current!
        operation = @installation.mutations.find_by(operation_key: key)
        if operation
          request = operation.private_request
          unless operation.route_id == route_id && request.fetch("path") == path
            raise Error.new("identity_conflict")
          end
          packet = retained_packet(operation)
          if retained_body && retained_body != packet.body_bytes
            raise Error.new("identity_conflict")
          end
        else
          body = retained_body ? nil : make_body&.call
          packet =
            @protocol.prepare(
              route_id,
              body: body,
              path: path,
              retained_body: retained_body
            )
          unless packet.method == "POST" && packet.body_bytes
            raise Error.new("identity_conflict")
          end
          request = {
            "binding" => @binding,
            "route_id" => route_id,
            "path" => path,
            "body_bytes" => packet.body_bytes
          }
          operation =
            @installation.mutations.create!(
              operation_key: key,
              route_id: route_id,
              request_sha256: packet.request_sha256,
              request_ciphertext:
                @installation.envelope.encrypt(
                  "journal_request",
                  request,
                  binding: key
                )
            )
        end
      end
      [operation, packet]
    end

    def retained_packet(operation)
      request = operation.private_request
      unless request.is_a?(Hash) &&
               request.keys.sort == %w[binding body_bytes path route_id] &&
               request.fetch("route_id") == operation.route_id &&
               request.fetch("binding") == @binding
        raise Error.new("identity_conflict")
      end
      packet =
        @protocol.prepare(
          operation.route_id,
          path: request.fetch("path"),
          retained_body: request.fetch("body_bytes")
        )
      unless packet.method == "POST" &&
               packet.request_sha256 == operation.request_sha256
        raise Error.new("identity_conflict")
      end
      packet
    end

    def retained_result(packet, receipt)
      unless receipt.is_a?(Hash) &&
               receipt.keys.sort ==
                 %w[
                   binding
                   body_bytes
                   dispatch_proof
                   headers
                   received_at
                   retry_at
                   status
                 ] && receipt.fetch("binding") == @binding
        raise Error.new("identity_conflict")
      end
      @protocol.response(
        packet,
        status: receipt.fetch("status"),
        headers: receipt.fetch("headers"),
        bytes: receipt.fetch("body_bytes")
      )
    end

    def retain_response(operation, packet, result)
      rejected =
        result.value.is_a?(Hash) && result.value["outcome"] == "rejected"
      retryable = rejected && result.value["retryable"] == true
      state =
        if retryable
          "pending"
        elsif rejected
          "refused"
        else
          "completed"
        end
      observed_at = @now.call
      receipt = {
        "binding" => @binding,
        "status" => result.status,
        "headers" => result.response_headers,
        "body_bytes" => result.body_bytes,
        "received_at" => observed_at.iso8601(6),
        "retry_at" =>
          (
            if retryable
              (
                observed_at + (result.value["retry_after_seconds"] || 60)
              ).iso8601(6)
            else
              nil
            end
          ),
        "dispatch_proof" => @transport.actual_source_refusal(result)
      }
      assert_no_transaction!
      @installation.with_lock do
        operation.reload
        unless operation.state == "pending" &&
                 retained_packet(operation).request_sha256 ==
                   packet.request_sha256
          raise Error.new("identity_conflict")
        end
        # Append every actual response before updating the latest pointer. A
        # transient error never erases a historical response/claim/ACK receipt.
        record_key =
          "#{Digest::SHA256.hexdigest(operation.operation_key)}:#{SecureRandom.uuid}"
        binding = JSON.generate(["mutation_receipt", record_key])
        @installation.operational_records.create!(
          kind: "mutation_receipt",
          record_key: record_key,
          encrypted_payload:
            @installation.envelope.encrypt(
              "operational_record",
              receipt,
              binding: binding
            )
        )
        operation.update!(
          state: state,
          response_ciphertext:
            @installation.envelope.encrypt(
              "journal_response",
              receipt,
              binding: operation.operation_key
            )
        )
      end
    end
  end
end
