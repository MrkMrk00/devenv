#!/bin/sh
set -eu

# Credential volume layout:
#   /mnt/claude/.claude/           — Claude config dir (contains .credentials.json, etc.)
#   /mnt/claude/.claude.json       — Claude settings file
#
# We symlink these into $HOME so the Claude SDK and Meridian can find them.

if ! [ -d /mnt/claude ]; then
    echo '[entrypoint] ERROR: please mount the claude-config volume at /mnt/claude' >&2
    exit 1
fi

# Ensure the credential directory and settings file exist
mkdir -p /mnt/claude/.claude
[ -f /mnt/claude/.claude.json ] || echo '{}' > /mnt/claude/.claude.json

# Symlink into $HOME for the SDK to discover
ln -sf /mnt/claude/.claude      "$HOME/.claude"
ln -sf /mnt/claude/.claude.json "$HOME/.claude.json"

exec "$@"
