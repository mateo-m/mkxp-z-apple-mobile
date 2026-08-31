# Legacy-method suite.
#
# Ruby 1.9 removed a set of methods that Pokemon Essentials forks
# still call. The Ruby 3.1 build defines each one again in
# binding/binding-mri.cpp and lets it run only for a script the
# syntax transform parsed. Everywhere else the method raises
# NoMethodError and respond_to? answers false.
#
# The engine sets the transform flag on the sections of
# Scripts.rxdata alone, so this game boots from Scripts.rxdata.
# Run pack_scripts.rb first. See README.md.

EngineTest.suite('legacy-methods', 6)

# Without this check the suite would still pass on a native Ruby 1.8
# dispatch, where every method below is real and nothing under test
# runs. Array#filter_map arrived in 2.7.
EngineTest.test('the interpreter is Ruby 3.x') do
  EngineTest.assert([].respond_to?(:filter_map),
                    'Array#filter_map is missing, so this is not Ruby 3.x')
end

EngineTest.test('Array#nitems counts the entries that are not nil') do
  EngineTest.assert_equal(3, [1, nil, 2, nil, 3].nitems, 'mixed')
  EngineTest.assert_equal(0, [].nitems, 'empty')
  EngineTest.assert_equal(0, [nil, nil].nitems, 'all nil')
end

EngineTest.test('Array#nitems answers respond_to?') do
  EngineTest.assert([].respond_to?(:nitems), 'Array#nitems')
end

EngineTest.test('Array#choice returns a member') do
  EngineTest.assert_equal(7, [7].choice, 'one-member array')
end

EngineTest.test('Array#indexes reads the positions') do
  EngineTest.assert_equal(%w[a c], %w[a b c].indexes(0, 2), 'first and last')
end

EngineTest.test('Object#id returns the object id') do
  object = Object.new
  EngineTest.assert_equal(object.object_id, object.id, 'Object#id')
end

exit(EngineTest.finish.zero? ? 0 : 1)
