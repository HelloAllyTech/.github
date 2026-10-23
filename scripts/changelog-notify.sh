#!/usr/bin/env bash
# Fires a `repository_dispatch` at HelloAllyTech/ally-changelog for one push to a
# release branch, carrying enough context for that repo's append-entry.yml to draft a
# customer-facing changelog line.
#
# Fetched at runtime by each source repo's changelog-notify.yml — one copy of the logic,
# not six — the same pattern docs.yml uses for docs_guard.py.
#
# Required env:
#   GITHUB_REPOSITORY        set by Actions automatically ("HelloAllyTech/ally-platform")
#   GITHUB_TOKEN              default token, read-only access to *this* repo's own API
#   BEFORE_SHA, AFTER_SHA     the push event's before/after commits
#   CHANGELOG_DISPATCH_TOKEN  PAT scoped to ally-changelog only, for the dispatch call
#
# Untrusted text (PR titles/bodies, commit subjects) is written straight to a JSON file
# with jq -n --arg, never interpolated into a shell command or eval'd.
set -euo pipefail

REPO_FULL="$GITHUB_REPOSITORY"
REPO="${REPO_FULL#*/}"

# A first push (or a force-push) leaves BEFORE unreachable — fall back to the head's
# parent so we describe something real instead of the whole history. Same fallback docs.yml
# uses for the same reason.
if [ -z "${BEFORE_SHA:-}" ] || [ "${BEFORE_SHA//0/}" = "" ] \
   || ! git rev-parse --verify --quiet "${BEFORE_SHA}^{commit}" >/dev/null; then
  BEFORE_SHA="${AFTER_SHA}^"
fi

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMPARE_URL="https://github.com/${REPO_FULL}/compare/${BEFORE_SHA}...${AFTER_SHA}"

# Was AFTER the merge commit of a merged PR? Read-only lookup against this repo's own
# API, using the default token — no cross-repo access needed for this part. This endpoint
# has a brief eventual-consistency lag right after a merge, so retry a couple of times
# before giving up. Critically: check gh's own exit code, don't just look at whether
# stdout came back non-empty — on a 404 or any other error, `gh api` still writes its
# JSON error body (e.g. {"message":"Not Found",...}) to *stdout*, and blindly trusting
# that as if it were PR data produced a real broken entry (all-null PR fields) the first
# time this ran in production.
PR_JSON=""
for attempt in 1 2 3; do
  if PR_LIST="$(GH_TOKEN="$GITHUB_TOKEN" gh api "repos/${REPO_FULL}/commits/${AFTER_SHA}/pulls" 2>/dev/null)"; then
    PR_JSON="$(echo "$PR_LIST" | jq '[.[] | select(.merged_at != null)] | .[0] // empty')"
    break
  fi
  echo "PR lookup failed (attempt ${attempt}), retrying shortly..."
  sleep 3
done

if [ -n "$PR_JSON" ]; then
  PR_ARGS=(--argjson pr "$(echo "$PR_JSON" | jq '{number, title, body: (.body // ""), url: .html_url, author: .user.login}')")
else
  PR_ARGS=(--argjson pr null)
fi

# Always gather the raw commit list too — used as the fallback path when there's no PR,
# and as extra context alongside a PR either way. Built from git log + a NUL-delimited
# format, with python3 doing the JSON escaping, so no commit subject ever reaches jq or
# the shell as anything but literal data.
COMMITS_JSON="$(git log "${BEFORE_SHA}..${AFTER_SHA}" --no-merges \
  --pretty=format:'%H%x01%an%x01%s%x00' \
  | python3 -c '
import sys, json
raw = sys.stdin.read()
commits = []
for rec in raw.split("\x00"):
    rec = rec.strip()
    if not rec:
        continue
    sha, author, subject = rec.split("\x01", 2)
    commits.append({"sha": sha, "author": author, "subject": subject})
print(json.dumps(commits))
')"

# ally-web ships three independently-released apps; tag which one(s) this push touched.
CHANGED_APPS_JSON="[]"
if [ "$REPO" = "ally-web" ]; then
  CHANGED_FILES="$(git diff --name-only "${BEFORE_SHA}..${AFTER_SHA}" 2>/dev/null || true)"
  CHANGED_APPS_JSON="$(python3 -c '
import json, sys
files = sys.stdin.read().splitlines()
apps = []
for prefix, name in [
    ("apps/ally-web/", "ally-web"),
    ("apps/ally-admin-dashboard/", "ally-admin-dashboard"),
    ("apps/ally-helpline-dashboard/", "ally-helpline-dashboard"),
]:
    if any(f.startswith(prefix) for f in files):
        apps.append(name)
print(json.dumps(apps))
' <<<"$CHANGED_FILES")"
fi

# ally-platform (the monorepo since 2026-10-23) holds every service as a folder, so the
# repo name alone no longer says what shipped. Name each service folder the push touched,
# and ally-web's apps by name as above. ally-be's product-update ingest reads these names
# from the entry header when it cannot get the PR's file list.
if [ "$REPO" = "ally-platform" ]; then
  CHANGED_FILES="$(git diff --name-only "${BEFORE_SHA}..${AFTER_SHA}" 2>/dev/null || true)"
  CHANGED_APPS_JSON="$(python3 -c '
import json, sys
files = sys.stdin.read().splitlines()
apps = []
for service in ["ally-be", "ally-ai", "ally-ai-learn", "ally-mobile"]:
    if any(f.startswith(service + "/") for f in files):
        apps.append(service)
web = [f[len("ally-web/"):] for f in files if f.startswith("ally-web/")]
web_apps = [
    name
    for name in ["ally-web", "ally-admin-dashboard", "ally-helpline-dashboard"]
    if any(f.startswith("apps/" + name + "/") for f in web)
]
apps += web_apps or (["ally-web"] if web else [])
print(json.dumps(apps))
' <<<"$CHANGED_FILES")"
fi

jq -n \
  --arg repo "$REPO" \
  --arg repo_full "$REPO_FULL" \
  --arg branch "${GITHUB_REF_NAME:-}" \
  --arg actor "${GITHUB_ACTOR:-}" \
  --arg timestamp "$TIMESTAMP" \
  --arg compare_url "$COMPARE_URL" \
  --argjson commits "$COMMITS_JSON" \
  --argjson changed_apps "$CHANGED_APPS_JSON" \
  "${PR_ARGS[@]}" \
  '{
    repo: $repo,
    repo_full: $repo_full,
    branch: $branch,
    actor: $actor,
    timestamp: $timestamp,
    compare_url: $compare_url,
    pr: $pr,
    commits: $commits,
    changed_apps: $changed_apps
  }' > payload.json

echo "Dispatch payload:"
cat payload.json

# `gh api -F key=@file` reads the file as a raw string, not JSON — it would send
# client_payload as an escaped string rather than an object and the API rejects it.
# Build the whole request body with jq instead and send it as-is.
jq -n --slurpfile payload payload.json \
  '{event_type: "new-entry", client_payload: $payload[0]}' > dispatch-body.json

GH_TOKEN="$CHANGELOG_DISPATCH_TOKEN" gh api \
  "repos/HelloAllyTech/ally-changelog/dispatches" \
  --input dispatch-body.json

echo "Dispatched changelog entry for ${REPO_FULL}@${AFTER_SHA}"
