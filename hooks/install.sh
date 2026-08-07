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

# Husky owns core.hooksPath and regenerates everything under .husky/_, so writing there is
# both temporary and destructive: its pre-push file is the dispatcher that runs every other
# husky hook. The file a project is meant to own is .husky/<hookname>.
HOOKS_PATH="$(git config --get core.hooksPath || true)"
if [[ -d .husky ]] || [[ "$HOOKS_PATH" == .husky/_* ]]; then
  MODE="husky"
  TARGET=".husky/pre-push"
  mkdir -p .husky
elif [[ -n "$HOOKS_PATH" ]]; then
  MODE="plain"
  TARGET="$HOOKS_PATH/pre-push"
  mkdir -p "$HOOKS_PATH"
  printf 'This repo sets core.hooksPath=%s — installing there.\n' "$HOOKS_PATH"
else
  MODE="plain"
  TARGET="$GIT_DIR/hooks/pre-push"
  mkdir -p "$GIT_DIR/hooks"
fi

# Never silently replace a hook we did not write.
if [[ -e "$TARGET" ]] && ! grep -q "ally-docs-guard" "$TARGET" 2>/dev/null; then
  die "$TARGET already exists and was not installed by us.
    Move it aside and re-run, or chain to $HOOK_URL from within it."
fi

if [[ "$MODE" == "husky" ]]; then
  # A shim rather than a copy: the logic stays canonical in helloallytech/.github, and
  # because .husky/pre-push is committed, the whole team gets it without running anything.
  cat > "$TARGET" <<SHIM
#!/usr/bin/env bash
# ally-docs-guard — checks .docs-map.yml before a push to the default branch.
# Canonical source: $HOOK_URL
# Caches into .git/docs-guard/, refreshes daily, and never blocks on its own failures.
set -u
CACHE="\$(git rev-parse --git-dir)/docs-guard/pre-push"
if [ ! -f "\$CACHE" ] || [ -n "\$(find "\$CACHE" -mmin +1440 2>/dev/null)" ]; then
  mkdir -p "\$(dirname "\$CACHE")"
  curl -fsSL --max-time 5 "$HOOK_URL" -o "\$CACHE.tmp" 2>/dev/null \\
    && mv "\$CACHE.tmp" "\$CACHE" || rm -f "\$CACHE.tmp"
fi
[ -f "\$CACHE" ] || exit 0
command -v bash >/dev/null 2>&1 || exit 0
exec bash "\$CACHE"
SHIM
else
  curl -fsSL --max-time 10 "$HOOK_URL" -o "$TARGET.tmp" || die "could not download the hook."
  mv "$TARGET.tmp" "$TARGET"
fi

chmod +x "$TARGET"
ok "Installed the docs-guard pre-push hook at $TARGET"
[[ "$MODE" == "husky" ]] && printf 'Commit %s so the rest of the team gets it too.\n' "$TARGET"

if [[ ! -f .docs-map.yml ]]; then
  printf '\nNote: this repo has no .docs-map.yml, so the hook will stay silent until it does.\n'
fi
