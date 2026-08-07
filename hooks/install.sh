#!/usr/bin/env bash
# Install the docs-guard pre-push hook into the repo you run this from.
#
#   curl -fsSL https://raw.githubusercontent.com/HelloAllyTech/.github/main/hooks/install.sh | bash
#
# The hook checks the same .docs-map.yml rules the CI guard checks, but before a push to
# the default branch — which is where most changes here land, and where CI never looks.
# It never blocks on tooling problems, and `git push --no-verify` always overrides it.
#
# Uninstall:  rm "$(git rev-parse --git-dir)/hooks/pre-push"
#
# Spec: https://tech.helloally.ai/#/wiki/contributing/docs-system.md

set -euo pipefail

HOOK_URL="https://raw.githubusercontent.com/HelloAllyTech/.github/main/hooks/pre-push"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m%s\033[0m\n' "$*"; }

GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" || die "not a git repository."
HOOKS_DIR="$GIT_DIR/hooks"
TARGET="$HOOKS_DIR/pre-push"

# core.hooksPath wins over .git/hooks, so installing into .git/hooks would silently do
# nothing. Say so rather than leaving someone with a hook that never fires.
CUSTOM_PATH="$(git config --get core.hooksPath || true)"
if [[ -n "$CUSTOM_PATH" ]]; then
  HOOKS_DIR="$CUSTOM_PATH"
  TARGET="$HOOKS_DIR/pre-push"
  printf 'This repo sets core.hooksPath=%s — installing there instead.\n' "$CUSTOM_PATH"
fi

mkdir -p "$HOOKS_DIR"

if [[ -e "$TARGET" ]] && ! grep -q "docs_guard.py" "$TARGET" 2>/dev/null; then
  cp "$TARGET" "$TARGET.replaced-by-docs-guard"
  printf 'Existing pre-push hook saved as %s\n' "$TARGET.replaced-by-docs-guard"
fi

curl -fsSL --max-time 10 "$HOOK_URL" -o "$TARGET.tmp" || die "could not download the hook."
mv "$TARGET.tmp" "$TARGET"
chmod +x "$TARGET"

ok "Installed the docs-guard pre-push hook at $TARGET"

if [[ ! -f .docs-map.yml ]]; then
  printf '\nNote: this repo has no .docs-map.yml, so the hook will stay silent until it does.\n'
fi
