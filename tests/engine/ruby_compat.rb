# Interpreter compatibility suite.
#
# The engine ships Ruby 1.8, 1.9 and 3.1, and a launcher picks one
# per game. A game that runs on one must run on the others, so every
# check here states a behaviour that has to be the same on all three.
#
# Run it on each interpreter:
#
#   tools/run-engine-tests.sh --suite ruby_compat.rb --ruby 18
#   tools/run-engine-tests.sh --suite ruby_compat.rb --ruby 19
#   tools/run-engine-tests.sh --suite ruby_compat.rb --ruby 31
#
# This file must parse on all three.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('ruby-compat', 6)

# A path with no per-cent sign in it, and a spare argument after it.
# Pokemon Essentials writes many calls in this shape.
SPARE = 'Graphics/Pictures/Logros/img/3c.png'.freeze

def with_debug
  $DEBUG = true
  yield
ensure
  $DEBUG = false
end

EngineTest.test('$DEBUG keeps what a game writes') do
  with_debug do
    EngineTest.assert_equal(true, $DEBUG, '$DEBUG after a game turns it on')
  end
  EngineTest.assert_equal(false, $DEBUG, '$DEBUG after a game turns it off')
end

EngineTest.test('$-d follows $DEBUG') do
  with_debug do
    EngineTest.assert_equal(true, $-d, '$-d')
  end
end

EngineTest.test('sprintf drops a spare argument while $DEBUG is on') do
  with_debug do
    # rubocop:disable Style/FormatString -- the three entry points into
    # rb_str_format are the subject, so each check names its own.
    EngineTest.assert_equal(SPARE, sprintf(SPARE, 3), 'sprintf')
    # rubocop:enable Style/FormatString
  end
end

EngineTest.test('format drops a spare argument while $DEBUG is on') do
  with_debug do
    EngineTest.assert_equal(SPARE, format(SPARE, 3), 'format')
  end
end

EngineTest.test('String#% drops a spare argument while $DEBUG is on') do
  with_debug do
    # rubocop:disable Style/FormatString -- see the sprintf check above.
    EngineTest.assert_equal(SPARE, SPARE % [3], 'String#%')
    # rubocop:enable Style/FormatString
  end
end

EngineTest.test('sprintf still fills the directives it has') do
  with_debug do
    # rubocop:disable Style/FormatString, Style/RedundantFormat, Style/FormatStringToken
    # The literal result is the point: the call must still read its
    # directives, and plain tokens are what a game writes.
    EngineTest.assert_equal('a 2', sprintf('%s %d', 'a', 2), 'sprintf with directives')
    # rubocop:enable Style/FormatString, Style/RedundantFormat, Style/FormatStringToken
  end
end

EngineTest.finish
exit
