#!/bin/sh
# Fails when the engine names a launcher or asks a host for a
# function. A host sets each value through src/app_bridge.h. The
# engine must never reach up to a name that the host defines.
#
# Two things fail:
#   - The launcher names "empo" and "mkxp-ios" anywhere in the repo's
#     own files or in hmode7. The ANGLE download from the empo-deps
#     release is a file location, not launcher code, so that one name
#     is allowed.
#   - A weak declaration or a weak import in the engine sources. A weak
#     name is how a library calls a function that the host may define.
set -eu

cd "$(dirname "$0")/.."

status=0

launcher='(^|[^[:alnum:]_])(empo|mkxp-ios)([^[:alnum:]_]|$)'

if git grep -niIE "$launcher" -- . ':!tools/check-no-host-code.sh' | grep -v 'mateo-m/empo-deps/'
then
    echo "error: the lines above name a launcher" >&2
    status=1
fi

if git -C hmode7 grep -niIE "$launcher"
then
    echo "error: hmode7 names a launcher" >&2
    status=1
fi

weak='__attribute__ *\(\( *weak|weak_import|#pragma weak'
if git grep -nE "$weak" -- src binding multiruby deps ':!deps/sources'
then
    echo "error: the engine has a weak name" >&2
    status=1
fi
if git -C hmode7 grep -nE "$weak"
then
    echo "error: hmode7 has a weak name" >&2
    status=1
fi

exit "$status"
