# Legacy-method suite for a game that runs with the syntax transform off.
#
# The Ruby 3.1 build defines the methods Ruby 1.9 removed again, and each
# one raises NoMethodError unless the caller runs under the older syntax
# mode. The transform target is a whole-run setting, so with the transform
# off no script can ever call them. The engine must leave the names alone,
# because a game tests for them and installs its own copy:
#
#   if !Array.method_defined?(:nitems)
#     class Array
#       def nitems
#         count { |x| !x.nil? }
#       end
#     end
#   end
#
# Run it on Ruby 3.1:
#
#   tools/run-engine-tests.sh --suite legacy_methods_off.rb --ruby 31
#
# The game folder has no "syntaxTransform" key, which the engine reads as
# off. tests/legacy-methods covers the other side, with the transform on.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('legacy-methods-off', 6)

# Without this check the suite would pass on Ruby 1.8, where the methods
# below are real and nothing under test runs. Array#filter_map arrived
# in 2.7.
EngineTest.test('the interpreter is Ruby 3.x') do
  EngineTest.assert([].respond_to?(:filter_map),
                    'Array#filter_map is missing, so this is not Ruby 3.x')
end

EngineTest.test('method_defined? does not report the Ruby 1.8 methods') do
  EngineTest.assert_equal(false, Array.method_defined?(:nitems), 'Array#nitems')
  EngineTest.assert_equal(false, Array.method_defined?(:choice), 'Array#choice')
  EngineTest.assert_equal(false, Array.method_defined?(:indexes), 'Array#indexes')
  EngineTest.assert_equal(false, Symbol.method_defined?(:to_i), 'Symbol#to_i')
  EngineTest.assert_equal(false, Kernel.method_defined?(:id), 'Kernel#id')
end

EngineTest.test('respond_to? does not report the Ruby 1.8 methods') do
  EngineTest.assert_equal(false, [].respond_to?(:nitems), 'Array#nitems')
  EngineTest.assert_equal(false, :a.respond_to?(:to_i), 'Symbol#to_i')
  EngineTest.assert_equal(false, Object.new.respond_to?(:id), 'Object#id')
end

# Ruby 3.0 removed Hash#index, which the 1.8 group above does not cover.
EngineTest.test('Hash#index stays away as well') do
  EngineTest.assert_equal(false, Hash.method_defined?(:index), 'Hash#index')
  EngineTest.assert_equal(false, {}.respond_to?(:index), 'Hash#index respond_to?')
end

# Ruby 3.1 still has Object#=~, and it answers nil. The engine must not
# replace it with a method that raises.
EngineTest.test('Object#=~ answers nil') do
  EngineTest.assert_equal(nil, Object.new =~ /anything/, 'Object#=~')
end

# What a Pokemon Essentials fork does. This runs last, because it leaves
# Array#nitems defined for the rest of the run.
EngineTest.test('a game can install its own Array#nitems') do
  unless Array.method_defined?(:nitems)
    class Array
      def nitems
        count { |x| !x.nil? }
      end
    end
  end
  EngineTest.assert_equal(3, [1, nil, 2, nil, 3].nitems, 'mixed')
  EngineTest.assert_equal(0, [nil, nil].nitems, 'all nil')
end

exit(EngineTest.finish.zero? ? 0 : 1)
