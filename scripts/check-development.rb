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
         "98d7904e987fbe306a51632d1fb37d6f78564915d127145027b992ec9a2723dc"
  abort "Wrong normative identity"
end
unless manifest["schema_sha256"] ==
         "b6ab0efa3247f9c93a76ccb591a2ed9a5b0fd4805427f87e67c72a23b88edd0a"
  abort "Wrong schema identity"
end
if File
     .read(File.join(root, "plugin.rb"))
     .index("# name: discourse-discussion-bridge-ghost")
     .nil?
  abort "Missing native plugin"
end
if File.read(File.join(root, "LICENSE")).index("GPL-2.0-or-later").nil?
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
