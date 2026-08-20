# Assertion accounting for the host-side Ruby tests.
#
# Every test file here fails fast: an assertion that does not hold
# prints and exits 1. That says nothing about a file whose assertions
# stopped running. A suite gutted by a bad refactor, an early return,
# or a stubbed-out helper still reaches its last line and prints
# "all tests passed".
#
# So every assertion helper counts itself, and every file ends with
# `test_passed`, which states the count and refuses to report a pass
# below the floor the file declares.
#
# The file name stays outside the tools/test_*.rb CI glob on purpose:
# this is a library, not a test.

$assertions = 0

# Counts one assertion. Call it from every assertion helper, at the
# top, before any early return for the passing case.
def asserted
  $assertions += 1
end

# Ends a test file. `floor` is how many assertions the file ran when
# it was last reviewed. Raise it when the file gains checks. A run
# below it means checks went missing, which is the failure this
# guards against.
def test_passed(name, floor)
  if $assertions < floor
    warn "FAIL: #{name} ran #{$assertions} assertions, expected at least #{floor}"
    warn '  Checks went missing. Fix them, or lower the floor on purpose.'
    exit 1
  end

  puts "#{name}: #{$assertions} assertions passed"
end
