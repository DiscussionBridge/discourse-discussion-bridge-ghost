# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
manifest = JSON.parse(File.read(File.join(root, "discussionbridge-release.json")))
abort "Wrong family identity" unless manifest.dig("family", "version") == "0.4.0-alpha.1"
abort "Wrong component identity" unless manifest.dig("component", "version") == "0.4.0-alpha.1"
abort "Wrong protocol" unless manifest["wire_version"] == "v4"
abort "Unexpected release" unless manifest["release_version"].nil?
abort "Unexpected acceptance claim" unless manifest["status"] == "unfinished_implementation_candidate_not_qualified"
abort "Wrong normative identity" unless manifest["normative_sha256"] == "808042688cbde88fac0acdf1187e4cb8c251e13025bfcf09cf3a3c361ca02003"
abort "Wrong schema identity" unless manifest["schema_sha256"] == "e6a15a6d70f7bc8b8ee82aa22a0b9c2ff1bbf2da6277f7087118be9e026ce5c0"
abort "Missing native plugin" unless File.read(File.join(root, "plugin.rb")).include?("# name: discourse-discussion-bridge-ghost")
abort "Missing preserved license" unless File.read(File.join(root, "LICENSE")).include?("Copyright (c) 2026 WebSynergetics")
abort "Unexpected Node runtime package" if File.exist?(File.join(root, "package.json"))
puts "Unfinished V4 native connector identities verified; no release or qualification asserted."
