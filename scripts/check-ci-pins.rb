# frozen_string_literal: true

require "json"
require "yaml"

# CI source regression guard, not a runtime plugin dependency or a claim that
# provider-managed runners are bit-reproducible. No writes or network calls.
module GhostCiPins
  CORE = "acf8e70129f5359635f8227ad8a91a792204147e"
  RECEIVER = "43be31be616b397c21786f74366e0a1c76b8f667"
  IMAGE =
    "discourse/discourse_test@sha256:5df460f3592a1adacc924775b6c690191572d8efe9e51d3f823c38c092d9f6a3"
  ACTIONS = {
    "actions/checkout" => "d23441a48e516b6c34aea4fa41551a30e30af803",
    "actions/cache" => "caa296126883cff596d87d8935842f9db880ef25",
    "actions/upload-artifact" => "b7c566a772e6b6bfb58ed0dc250532a479d7789f"
  }.freeze
  FOUNDATION_CHECKOUT = "11d5960a326750d5838078e36cf38b85af677262"
  WRAPPER = ".github/workflows/discourse-plugin.yml"
  NATIVE = ".github/workflows/discourse-plugin-pinned.yml"

  class Invalid < StandardError
  end

  def self.documents(root)
    Dir
      .glob(File.join(root, ".github/workflows/*.yml"))
      .to_h do |path|
        [
          path.delete_prefix("#{root}/"),
          YAML.safe_load(File.read(path), aliases: false)
        ]
      end
  end

  def self.verify!(documents:, about:)
    if about.dig("tests", "requiredPlugins")
      reject!("Implicit branch-based plugin cloning is not admitted")
    end
    documents.each_value do |document|
      visit(document) do |key, value|
        if key == "uses"
          if value == "./#{NATIVE}"
            reject!("Local workflow is missing") unless documents.key?(NATIVE)
          else
            name, commit = value.to_s.split("@", 2)
            pinned =
              ACTIONS[name] == commit ||
                (name == "actions/checkout" && commit == FOUNDATION_CHECKOUT)
            unless pinned && commit.to_s.match?(/\A[a-f0-9]{40}\z/)
              reject!("Unpinned CI action")
            end
          end
        elsif key == "container"
          declaration = value == { "type" => "string", "required" => true }
          unless declaration ||
                   [IMAGE, "${{ inputs.container }}"].include?(value)
            reject!("Mutable CI image")
          end
        end
      end
    end
    caller = documents.fetch(WRAPPER).fetch("jobs").fetch("native")
    unless caller.fetch("uses") == "./#{NATIVE}" &&
             caller.fetch("with") ==
               { "core_ref" => CORE, "container" => IMAGE }
      reject!("Native caller must use the exact suite inputs")
    end
    native = documents.fetch(NATIVE)
    unless native.fetch("env").fetch("BUNDLE_FROZEN") == "true"
      reject!("CI Bundler lock must be frozen")
    end
    # Psych uses YAML 1.1, where GitHub's unquoted `on` key is boolean true.
    events = native.key?("on") ? native.fetch("on") : native.fetch(true)
    inputs = events.fetch("workflow_call").fetch("inputs")
    %w[core_ref container].each do |input|
      unless inputs.fetch(input).fetch("required") == true &&
               !inputs.fetch(input).key?("default")
        reject!("Required immutable input has a default")
      end
    end
    %w[skip_linting skip_annotations].each do |input|
      unless inputs.fetch(input).fetch("default") == false
        reject!("A native check is disabled")
      end
    end
    jobs = native.fetch("jobs")
    unless jobs.keys.sort == %w[check_for_tests linting tests]
      reject!("Native matrix changed")
    end
    census =
      jobs
        .fetch("check_for_tests")
        .fetch("steps")
        .find { |step| step["id"] == "check_tests" }
        .fetch("run")
    unless %w[frontend backend system annotations].all? { |kind|
             census.include?("'#{kind}'")
           }
      reject!("A native test type is missing")
    end
    steps = jobs.fetch("tests").fetch("steps")
    receiver_index =
      steps.index do |step|
        step["name"] == "Install pinned DiscussionBridge receiver"
      end
    verify_index =
      steps.index do |step|
        step["name"] == "Verify exact source and receiver checkouts"
      end
    setup_index = steps.index { |step| step["name"] == "Setup gems" }
    unless receiver_index && verify_index && setup_index &&
             receiver_index < verify_index && verify_index < setup_index
      reject!("Dependency identity must be checked before setup")
    end
    receiver = steps.fetch(receiver_index)
    unless receiver.fetch("uses") ==
             "actions/checkout@#{ACTIONS.fetch("actions/checkout")}" &&
             receiver.fetch("with") ==
               {
                 "repository" => "DiscussionBridge/discourse-discussion-bridge",
                 "ref" => RECEIVER,
                 "path" => "plugins/discourse-discussion-bridge",
                 "fetch-depth" => 1,
                 "persist-credentials" => false
               }
      reject!("Receiver checkout is not immutable")
    end
    verification = steps.fetch(verify_index).fetch("run")
    unless [RECEIVER, "$EXPECTED_CORE", "$EXPECTED_CONNECTOR"].all? { |expected|
             verification.include?(expected)
           }
      reject!("Actual checkout identity assertions are missing")
    end
    target = steps.find { |step| step["id"] == "core-target" }
    unless target.fetch("run").include?('/\A[a-f0-9]{40}\z/') &&
             target.fetch("env") == { "CORE_REF" => "${{ inputs.core_ref }}" }
      reject!("Core target is not admitted as an immutable commit")
    end
    true
  rescue KeyError, NoMethodError, TypeError
    reject!("CI pin declaration is incomplete")
  end

  def self.visit(value, &block)
    case value
    when Hash
      value.each do |key, member|
        yield key, member
        visit(member, &block)
      end
    when Array
      value.each { |member| visit(member, &block) }
    end
  end
  private_class_method :visit

  def self.reject!(message)
    raise Invalid, message
  end
  private_class_method :reject!
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("..", __dir__)
  GhostCiPins.verify!(
    documents: GhostCiPins.documents(root),
    about: JSON.parse(File.read(File.join(root, "about.json")))
  )
  puts "Exact CI action/Core/receiver/image pins and native test matrix verified."
end
