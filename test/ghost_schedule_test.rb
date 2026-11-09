# frozen_string_literal: true

# Run with ruby test/ghost_schedule_test.rb. This process stubs the job host.
require "minitest/autorun"

module Jobs
  class Scheduled
    def self.every(*) = nil
    def self.sidekiq_options(**) = nil
  end
end

module DiscussionBridge
  CmsRecordStore = Class.new
end

module DiscussionBridgeGhost
  AutomaticPublishing = Class.new
  InboundPublishing = Class.new
end

module SiteSetting
  def self.discussion_bridge_enabled = true
  def self.discussion_bridge_endpoint_enabled = true
  def self.discussion_bridge_ghost_sync_interval_minutes = Struct.new(:minutes).new(60)
end

module Discourse; end
module Rails; end

unless 1.respond_to?(:minute)
  class Integer
    def minute = self * 60
  end
  added_minute = true
end
require_relative "../jobs/scheduled/discussion_bridge_ghost_publish"
Integer.remove_method(:minute) if added_minute

class GhostScheduleTest < Minitest::Test
  def test_unexpected_outbound_error_does_not_skip_inbound
    invoked = []
    redis = Object.new
    redis.define_singleton_method(:set) { |*, **| true }
    logger = Object.new
    errors = []
    logger.define_singleton_method(:error) { |message| errors << message }
    Discourse.define_singleton_method(:redis) { redis }
    Rails.define_singleton_method(:logger) { logger }
    DiscussionBridgeGhost::AutomaticPublishing.define_singleton_method(:run) do
      invoked << :outbound
      raise KeyError, "untrusted response content"
    end
    DiscussionBridgeGhost::InboundPublishing.define_singleton_method(:run) { invoked << :inbound }
    Jobs::DiscussionBridgeGhostPublish.new.execute({})

    assert_equal %i[outbound inbound], invoked
    assert_equal 1, errors.size
    assert_includes errors.first, "error=KeyError"
    refute_includes errors.first, "untrusted response content"
  end
end
