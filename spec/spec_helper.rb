# frozen_string_literal: true

require "stringio"

# Specs run from the repo root so the scripts can read schema.json / reserved.json
# by relative path, exactly as they do in CI.
REPO_ROOT = File.expand_path("..", __dir__)

# Run a block with stdout/stderr captured, so script logging stays out of the
# spec report. Returns the block's value.
def quietly
  orig_out = $stdout
  orig_err = $stderr
  $stdout = StringIO.new
  $stderr = StringIO.new
  yield
ensure
  $stdout = orig_out
  $stderr = orig_err
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :defined
end
