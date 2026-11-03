# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
manifest =
  JSON.parse(File.read(File.join(root, "discussionbridge-release.json")))
unless manifest.dig("family", "version") == "0.4.0-alpha.1"
  abort "Wrong family identity"
end
unless manifest.dig("component", "version") == "0.4.0-alpha.1"
  abort "Wrong component identity"
end
abort "Wrong protocol" unless manifest["wire_version"] == "v4"
abort "Unexpected release" unless manifest["release_version"].nil?
abort "Wrong connector license" unless manifest["license"] == "GPL-2.0-or-later"
unless manifest["status"] == "unfinished_implementation_candidate_not_qualified"
  abort "Unexpected acceptance claim"
end
unless manifest["normative_sha256"] ==
         "808042688cbde88fac0acdf1187e4cb8c251e13025bfcf09cf3a3c361ca02003"
  abort "Wrong normative identity"
end
unless manifest["schema_sha256"] ==
         "e6a15a6d70f7bc8b8ee82aa22a0b9c2ff1bbf2da6277f7087118be9e026ce5c0"
  abort "Wrong schema identity"
end
if File
     .read(File.join(root, "plugin.rb"))
     .index("# name: discourse-discussion-bridge-ghost")
     .nil?
  abort "Missing native plugin"
end
unless File.read(File.join(root, "LICENSE")).include?("GPL-2.0-or-later")
  abort "Missing connector GPL license"
end
if File
     .read(File.join(root, "LICENSES", "MIT-Ghost.txt"))
     .index("Copyright (c) 2026 WebSynergetics")
     .nil?
  abort "Missing preserved license"
end
if File.exist?(File.join(root, "package.json"))
  abort "Unexpected Node runtime package"
end
puts "Unfinished V4 native connector identities verified; no release or qualification asserted."
