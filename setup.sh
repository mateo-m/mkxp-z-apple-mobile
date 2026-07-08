#!/bin/sh
# Setup script for mkxp-z development.
# Run this once after cloning the repository if you want a one-shot
# bootstrap for local tools + hook install.

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "Installing repo-managed git hooks via LeftHook..."
if ! command -v bun >/dev/null 2>&1; then
    echo "Missing required tool: bun" >&2
    exit 1
fi
bun install
echo "Git hooks configured."

echo "Verifying required hook tools..."
. "$REPO_ROOT/scripts/hooks/ruby-env.sh"
for tool in bundle bun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool" >&2
        exit 1
    fi
done
echo "All required hook tools are installed."

echo "Installing Ruby lint deps..."
bundle install

echo "Done."
