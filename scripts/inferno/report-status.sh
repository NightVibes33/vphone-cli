#!/usr/bin/env bash
# Write the current Inferno CI stage to status/inferno.json on the dedicated
# inferno-status branch. This branch is not a workflow trigger, so reporting
# progress cannot recursively start new emulation jobs.

set -u

STATE="${1:-running}"
STAGE="${2:-unknown}"
MESSAGE="${3:-}"
DETAILS_FILE="${4:-}"
STATUS_BRANCH="inferno-status"
STATUS_PATH="status/inferno.json"
WORKTREE="${RUNNER_TEMP:-/tmp}/inferno-status-worktree"

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

DETAILS=''
if [ -n "$DETAILS_FILE" ] && [ -f "$DETAILS_FILE" ]; then
  DETAILS="$(tail -n 120 "$DETAILS_FILE" 2>/dev/null || true)"
fi

for attempt in 1 2 3; do
  git fetch origin "$STATUS_BRANCH" >/dev/null 2>&1 || true

  if [ ! -d "$WORKTREE/.git" ] && [ ! -f "$WORKTREE/.git" ]; then
    rm -rf "$WORKTREE"
    git worktree add -B "$STATUS_BRANCH" "$WORKTREE" "origin/$STATUS_BRANCH" >/dev/null 2>&1 || {
      sleep 2
      continue
    }
  else
    git -C "$WORKTREE" fetch origin "$STATUS_BRANCH" >/dev/null 2>&1 || true
    git -C "$WORKTREE" reset --hard "origin/$STATUS_BRANCH" >/dev/null 2>&1 || true
  fi

  mkdir -p "$WORKTREE/$(dirname "$STATUS_PATH")"

  STATE_JSON="$(printf '%s' "$STATE" | json_escape)"
  STAGE_JSON="$(printf '%s' "$STAGE" | json_escape)"
  MESSAGE_JSON="$(printf '%s' "$MESSAGE" | json_escape)"
  DETAILS_JSON="$(printf '%s' "$DETAILS" | json_escape)"

  cat > "$WORKTREE/$STATUS_PATH" <<EOF
{
  "state": $STATE_JSON,
  "stage": $STAGE_JSON,
  "updated_at": "$(date -u +%FT%TZ)",
  "repository": "${GITHUB_REPOSITORY:-unknown}",
  "run_id": "${GITHUB_RUN_ID:-unknown}",
  "run_attempt": "${GITHUB_RUN_ATTEMPT:-unknown}",
  "head_sha": "${GITHUB_SHA:-unknown}",
  "runner": "${RUNNER_NAME:-unknown}",
  "message": $MESSAGE_JSON,
  "details": $DETAILS_JSON
}
EOF

  git -C "$WORKTREE" config user.name 'github-actions[bot]'
  git -C "$WORKTREE" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git -C "$WORKTREE" add "$STATUS_PATH"

  if git -C "$WORKTREE" diff --cached --quiet; then
    exit 0
  fi

  git -C "$WORKTREE" commit -m "Inferno status: $STAGE" >/dev/null 2>&1 || true
  if git -C "$WORKTREE" push origin "HEAD:$STATUS_BRANCH" >/dev/null 2>&1; then
    exit 0
  fi

  sleep $((attempt * 3))
done

echo 'warning: unable to publish Inferno status' >&2
exit 0
