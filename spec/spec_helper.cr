require "spec"
require "file_utils"

# Prevent CLI from running during tests
ENV["XERP_SPEC"] = "1"

require "../src/xerp"
