#!/usr/bin/env bash
# Provision or reuse a Corellium iPhone from a GitHub-hosted runner and return
# only after the device is powered on, the Corellium agent is ready, and
# jailbreak evidence is present.

set -Eeuo pipefail

: "${CORELLIUM_API_TOKEN:?Missing CORELLIUM_API_TOKEN}"
: "${CORELLIUM_PROJECT:?Missing CORELLIUM_PROJECT}"

CORELLIUM_UI_ENDPOINT="${CORELLIUM_UI_ENDPOINT:-https://app.corellium.com}"
CORELLIUM_API_ENDPOINT="${CORELLIUM_API_ENDPOINT:-${CORELLIUM_UI_ENDPOINT%/}/api}"
INSTANCE_NAME="${INSTANCE_NAME:-github-jailbroken-iphone}"
DEVICE_FLAVOR="${DEVICE_FLAVOR:-iphone16pm}"
IOS_VERSION="${IOS_VERSION:-18.0}"
EXISTING_INSTANCE_ID="${EXISTING_INSTANCE_ID:-}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-3600}"
POLL_SECONDS="${POLL_SECONDS:-20}"
LOG_DIR="${LOG_DIR:-${RUNNER_TEMP:-/tmp}/corellium-jailbroken-iphone}"

mkdir -p "$LOG_DIR"
INSTANCE_JSON="$LOG_DIR/instance.json"
APPS_LOG="$LOG_DIR/apps.txt"
FILES_LOG="$LOG_DIR/files.txt"
AGENT_JSON="$LOG_DIR/agent-ready.json"
CREATE_LOG="$LOG_DIR/create.txt"

fail() {
  echo "error: $*" >&2
  exit 1
}

api_get() {
  local path="$1"
  curl --silent --show-error --fail-with-body \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer ${CORELLIUM_API_TOKEN}" \
    "${CORELLIUM_API_ENDPOINT%/}${path}"
}

api_post() {
  local path="$1"
  curl --silent --show-error --fail-with-body \
    -X POST \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer ${CORELLIUM_API_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{}' \
    "${CORELLIUM_API_ENDPOINT%/}${path}"
}

extract_uuid() {
  grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n1
}

publish_early_outputs() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  {
    echo "instance_id=$INSTANCE_ID"
    echo "instance_name=$INSTANCE_NAME"
    echo "created_instance=$CREATED_INSTANCE"
  } >> "$GITHUB_OUTPUT"
}

command -v corellium >/dev/null || fail 'Corellium CLI is not installed.'
command -v curl >/dev/null || fail 'curl is not installed.'
command -v jq >/dev/null || fail 'jq is not installed.'

INSTANCE_ID="$EXISTING_INSTANCE_ID"
CREATED_INSTANCE=0

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Creating jailbroken Corellium iPhone: flavor=$DEVICE_FLAVOR iOS=$IOS_VERSION name=$INSTANCE_NAME"

  # Corellium's official iOS create flow defaults to the jailbroken patch set.
  # The final `true` waits for creation/restoration before returning.
  set +e
  CREATE_OUTPUT="$(corellium instance create \
    "$DEVICE_FLAVOR" "$IOS_VERSION" \
    --name "$INSTANCE_NAME" \
    "$CORELLIUM_PROJECT" true 2>&1)"
  CREATE_RC=$?
  set -e

  printf '%s\n' "$CREATE_OUTPUT" | tee "$CREATE_LOG"
  (( CREATE_RC == 0 )) || fail "Corellium instance creation failed with exit code $CREATE_RC."

  INSTANCE_ID="$(printf '%s\n' "$CREATE_OUTPUT" | extract_uuid || true)"
  if [[ -z "$INSTANCE_ID" ]]; then
    # Some CLI versions print only the ID without table formatting.
    INSTANCE_ID="$(printf '%s' "$CREATE_OUTPUT" | tr -d '[:space:]')"
  fi

  [[ "$INSTANCE_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fail 'Could not parse the Corellium instance ID.'
  CREATED_INSTANCE=1
else
  echo "Reusing Corellium instance: $INSTANCE_ID"
fi

# Publish the ID immediately. The workflow can still stop/delete the instance
# if a later boot or jailbreak verification step fails.
publish_early_outputs

api_get "/v1/instances/$INSTANCE_ID" > "$INSTANCE_JSON" || fail 'Corellium instance was not found.'

STATE="$(jq -r '.state // "unknown"' "$INSTANCE_JSON")"
if [[ "$STATE" == "off" ]]; then
  echo 'Starting existing Corellium instance.'
  api_post "/v1/instances/$INSTANCE_ID/start" > "$LOG_DIR/start.json"
fi

DEADLINE=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
while (( $(date +%s) < DEADLINE )); do
  api_get "/v1/instances/$INSTANCE_ID" > "$INSTANCE_JSON"
  STATE="$(jq -r '.state // "unknown"' "$INSTANCE_JSON")"
  TASK_STATE="$(jq -r '.taskState // "unknown"' "$INSTANCE_JSON")"

  echo "$(date -u +%FT%TZ) instance=$INSTANCE_ID state=$STATE taskState=$TASK_STATE"

  if [[ "$STATE" == "on" && "$TASK_STATE" == "none" ]]; then
    break
  fi

  case "$STATE" in
    creating|booting|rebooting|on) ;;
    deleting|deleted|error|failed)
      fail "Corellium entered terminal state: $STATE / $TASK_STATE"
      ;;
  esac

  sleep "$POLL_SECONDS"
done

[[ "$STATE" == "on" && "$TASK_STATE" == "none" ]] || fail 'Timed out waiting for the Corellium iPhone to boot.'

AGENT_READY=0
while (( $(date +%s) < DEADLINE )); do
  set +e
  AGENT_RESPONSE="$(api_get "/v1/instances/$INSTANCE_ID/agent/v1/app/ready" 2>"$LOG_DIR/agent-error.txt")"
  AGENT_RC=$?
  set -e

  if (( AGENT_RC == 0 )); then
    printf '%s\n' "$AGENT_RESPONSE" > "$AGENT_JSON"
    if [[ "$(jq -r '.ready // false' "$AGENT_JSON")" == "true" ]]; then
      AGENT_READY=1
      break
    fi
  fi

  echo "$(date -u +%FT%TZ) waiting for Corellium agent..."
  sleep "$POLL_SECONDS"
done

(( AGENT_READY == 1 )) || fail 'The iPhone booted, but the Corellium agent did not become ready.'

set +e
corellium agent apps \
  --project "$CORELLIUM_PROJECT" \
  --instance "$INSTANCE_ID" > "$APPS_LOG" 2>&1
APPS_RC=$?

corellium agent files \
  --project "$CORELLIUM_PROJECT" \
  --instance "$INSTANCE_ID" > "$FILES_LOG" 2>&1
FILES_RC=$?
set -e

cat "$INSTANCE_JSON" "$APPS_LOG" "$FILES_LOG" > "$LOG_DIR/jailbreak-evidence.txt"

JAILBREAK_VERIFIED=0
if grep -Eiq \
  'jailbroken|com\.saurik\.Cydia|(^|[^A-Za-z])Cydia([^A-Za-z]|$)|/var/jb|/private/var/root|frida-server|Substitute' \
  "$LOG_DIR/jailbreak-evidence.txt"; then
  JAILBREAK_VERIFIED=1
fi

if (( JAILBREAK_VERIFIED == 0 )) && (( APPS_RC == 0 && FILES_RC == 0 )); then
  PATCH_TEXT="$(jq -c '.patches // .patch // empty' "$INSTANCE_JSON" 2>/dev/null || true)"
  if [[ -n "$PATCH_TEXT" ]] && grep -qi 'jail' <<<"$PATCH_TEXT"; then
    JAILBREAK_VERIFIED=1
  fi
fi

(( JAILBREAK_VERIFIED == 1 )) || fail 'The VM booted, but jailbroken/root evidence could not be verified.'

INSTANCE_WEB_URL="$(jq -r '.webUrl // .webURL // empty' "$INSTANCE_JSON")"
if [[ -z "$INSTANCE_WEB_URL" || "$INSTANCE_WEB_URL" == "null" ]]; then
  INSTANCE_WEB_URL="$CORELLIUM_UI_ENDPOINT"
fi

{
  echo "INSTANCE_ID=$INSTANCE_ID"
  echo "INSTANCE_NAME=$INSTANCE_NAME"
  echo "INSTANCE_WEB_URL=$INSTANCE_WEB_URL"
  echo "CREATED_INSTANCE=$CREATED_INSTANCE"
  echo 'JAILBREAK_VERIFIED=1'
  echo 'AGENT_READY=1'
} | tee "$LOG_DIR/result.env"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "instance_web_url=$INSTANCE_WEB_URL"
    echo 'jailbreak_verified=true'
  } >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "CORELLIUM_INSTANCE_ID=$INSTANCE_ID"
    echo "CORELLIUM_INSTANCE_NAME=$INSTANCE_NAME"
    echo "CORELLIUM_INSTANCE_WEB_URL=$INSTANCE_WEB_URL"
  } >> "$GITHUB_ENV"
fi

echo 'BOOTED=1'
echo 'JAILBROKEN=1'
echo "INSTANCE_ID=$INSTANCE_ID"
echo "OPEN=$INSTANCE_WEB_URL"
