# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Runs several suites in one launch, in the order MKXP_TEST_SUITES
# names them, separated by spaces. tools/run-engine-tests.sh sets it
# when it gets more than one --suite.
#
# Each suite ends with `exit`, so the runner catches SystemExit and
# starts the next one. A suite that raises anything else gets a FAIL
# line and a DONE line, so the runner reads it as a failure.
#
# This file must parse on Ruby 1.8, 1.9, and 3.x.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

ENV['MKXP_TEST_SUITES'].to_s.split.each do |suite|
  path = File.join(File.dirname(__FILE__), suite)
  begin
    eval(File.read(path), TOPLEVEL_BINDING, path) # rubocop:disable Security/Eval
  rescue SystemExit
    next
  # The engine's error classes descend from Exception, not from
  # StandardError.
  rescue Exception => e # rubocop:disable Lint/RescueException
    EngineTest.record_failure(suite, "#{e.class}: #{e.message}")
    EngineTest.finish
  end
end

exit
