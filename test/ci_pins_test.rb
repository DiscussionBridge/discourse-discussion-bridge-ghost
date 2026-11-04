# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/check-ci-pins"

class CiPinsTest < Minitest::Test
  def setup
    root = File.expand_path("..", __dir__)
    @documents = GhostCiPins.documents(root)
    @about = JSON.parse(File.read(File.join(root, "about.json")))
  end

  def verify
    GhostCiPins.verify!(documents: @documents, about: @about)
  end

  def native
    @documents.fetch(GhostCiPins::NATIVE)
  end

  def test_current_complete_workflow_is_pinned
    assert_equal true, verify
  end

  def test_mutable_action_tag_is_refused
    native
      .fetch("jobs")
      .fetch("linting")
      .fetch("steps")
      .find { |step| step["uses"] }[
      "uses"
    ] = "actions/checkout@v6"
    assert_raises(GhostCiPins::Invalid) { verify }
  end

  def test_mutable_image_and_core_caller_are_refused
    inputs =
      @documents
        .fetch(GhostCiPins::WRAPPER)
        .fetch("jobs")
        .fetch("native")
        .fetch("with")
    inputs["core_ref"] = "main"
    assert_raises(GhostCiPins::Invalid) { verify }
    inputs["core_ref"] = GhostCiPins::CORE
    inputs["container"] = "discourse/discourse_test:slim"
    assert_raises(GhostCiPins::Invalid) { verify }
  end

  def test_receiver_branch_or_compatibility_cloning_cannot_replace_commit
    receiver =
      native
        .fetch("jobs")
        .fetch("tests")
        .fetch("steps")
        .find do |step|
          step["name"] == "Install pinned DiscussionBridge receiver"
        end
    receiver.fetch("with")["ref"] = "codex/v4-install-readiness-20261029"
    assert_raises(GhostCiPins::Invalid) { verify }
  end

  def test_implicit_about_plugin_clone_is_refused
    @about["tests"] = {
      "requiredPlugins" => [
        "https://github.com/DiscussionBridge/discourse-discussion-bridge.git"
      ]
    }
    assert_raises(GhostCiPins::Invalid) { verify }
  end

  def test_lost_system_discovery_is_refused
    census =
      native
        .fetch("jobs")
        .fetch("check_for_tests")
        .fetch("steps")
        .find { |step| step["id"] == "check_tests" }
    census["run"] = census.fetch("run").gsub("'system'", "'removed'")
    assert_raises(GhostCiPins::Invalid) { verify }
  end

  def test_identity_check_after_dependency_setup_is_refused
    steps = native.fetch("jobs").fetch("tests").fetch("steps")
    check =
      steps.find do |step|
        step["name"] == "Verify exact source and receiver checkouts"
      end
    steps.delete(check)
    steps << check
    assert_raises(GhostCiPins::Invalid) { verify }
  end
end
