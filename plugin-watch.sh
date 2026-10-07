#!/bin/bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Bifrost secure-code-policy plugin watcher. Per run:

1. Fetch the gateway's current version (GET /api/version, e.g. "v2.2.3-enterprise").
2. Fetch the plugin's config + status (GET /api/plugins): must exist, be enabled,
   be status "active", and implement the "llm" interface.
3. Parse the ent-version the loaded artifact was built for from the plugin's
   configured path (e.g. .../secure-policy-plugin-ent-v2.2.3-core1103.so -> 2.2.3).
4. Compare. Mismatch (Bifrost upgraded, plugin stale) or any unhealthy state
   -> ALERT: log line on stderr, exit 1, and a Slack message sent to
   \$SLACK_WEBHOOK_URL if set. Every alert includes the gateway's current
   version, the plugin's built-for version, and the action to take.

Environment (secrets — never pass on the command line):
  SLACK_WEBHOOK_URL   Slack incoming-webhook URL. Set = alerts are posted to Slack.
  BIFROST_MGMT_KEY    Bifrost management API key (scope: Plugins:View).
                      Virtual keys (sk-bf-*) do NOT work on management APIs.

Options:
  --gateway <url>     Gateway base URL (default: \$BIFROST_GATEWAY or
                     https://llm-gateway-prod.growwcorp.in)
  --plugin <name>    Plugin display name from config (default: secure-code-policy)
  --key-file <path>  File containing the Bifrost management API key
  --test-alert       Send a test alert to \$SLACK_WEBHOOK_URL and exit (verifies
                     the Slack wiring without touching the gateway checks)
  -h, --help         Show this help

CronJob usage (ArgoCD): mount SLACK_WEBHOOK_URL and BIFROST_MGMT_KEY from a
Kubernetes Secret as env vars; a failed Job (exit 1) is additionally visible to
kube-state-metrics/Prometheus alerting.
EOF
  exit 1
}

GW_VERSION=""
PLUGIN_VERSION=""
PLUGIN_PATH=""

alert() {
  local msg="$1"
  local detail="gateway version: ${GW_VERSION:-unknown} | plugin built for: ${PLUGIN_VERSION:-unknown}"
  [ -n "$PLUGIN_PATH" ] && detail="${detail} | plugin path: ${PLUGIN_PATH}"
  local full=":rotating_light: Bifrost secure-code-policy plugin — ${msg} (${detail})"
  echo "ALERT [$(date -u '+%Y-%m-%dT%H:%M:%SZ')]: ${msg} (${detail})" >&2
  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    jq -n --arg t "$full" '{text: $t}' | curl -s -X POST -H 'Content-type: application/json' -d @- "$SLACK_WEBHOOK_URL" >/dev/null || echo "ALERT: Slack notification failed to send" >&2
  fi
  exit 1
}
info() { echo "OK   [$(date -u '+%Y-%m-%dT%H:%M:%SZ')]: $*"; }

GATEWAY="${BIFROST_GATEWAY:-https://llm-gateway-prod.growwcorp.in}"
PLUGIN_NAME="secure-code-policy"
KEY_FILE=""
TEST_ALERT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --gateway)    [ $# -ge 2 ] || { echo "--gateway needs a value" >&2; exit 1; }; GATEWAY="$2"; shift 2 ;;
    --plugin)     [ $# -ge 2 ] || { echo "--plugin needs a value" >&2; exit 1; }; PLUGIN_NAME="$2"; shift 2 ;;
    --key-file)   [ $# -ge 2 ] || { echo "--key-file needs a value" >&2; exit 1; }; KEY_FILE="$2"; shift 2 ;;
    --test-alert) TEST_ALERT=1; shift ;;
    -h|--help)    usage ;;
    *)            echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
done

command -v curl >/dev/null || { echo "ALERT: curl not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "ALERT: jq not found" >&2; exit 1; }

if [ "$TEST_ALERT" -eq 1 ]; then
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || { echo "SLACK_WEBHOOK_URL is not set — nothing to test" >&2; exit 1; }
  MSG=":white_check_mark: Bifrost plugin-watch — TEST ALERT. Slack wiring works; real alerts (plugin unhealthy / version mismatch) will reach this channel with the gateway version, plugin built-for version, and the action to take."
  if jq -n --arg t "$MSG" '{text: $t}' | curl -s -X POST -H 'Content-type: application/json' -d @- "$SLACK_WEBHOOK_URL" >/dev/null; then
    echo "OK   [$(date -u '+%Y-%m-%dT%H:%M:%SZ')]: test alert sent to Slack — check the channel"
    exit 0
  fi
  echo "ALERT: test alert FAILED to send to Slack" >&2
  exit 1
fi

KEY="${BIFROST_MGMT_KEY:-}"
if [ -z "$KEY" ] && [ -n "$KEY_FILE" ]; then
  [ -f "$KEY_FILE" ] || { echo "ALERT: key file not found: $KEY_FILE" >&2; exit 1; }
  KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
fi
[ -n "$KEY" ] || { echo "ALERT: no management API key: set BIFROST_MGMT_KEY or use --key-file" >&2; exit 1; }

GW_VERSION_RAW="$(curl -s "${GATEWAY%/}/api/version")"
GW_VERSION="$(printf '%s' "$GW_VERSION_RAW" | tr -d '"' | sed -nE 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
[ -n "$GW_VERSION" ] || alert "cannot parse the gateway's version from /api/version (response: ${GW_VERSION_RAW:-<empty>}) — check the gateway manually"

RESP="$(curl -s -H "Authorization: Bearer ${KEY}" -w $'\n%{http_code}' "${GATEWAY%/}/api/plugins")"
HTTP_CODE="${RESP##*$'\n'}"
BODY="${RESP%$'\n'*}"
[ "$HTTP_CODE" = "200" ] || alert "GET /api/plugins returned HTTP ${HTTP_CODE} — the watcher's management key is missing, expired, or lacks Plugins:View. Fix: $(printf '%s' "$BODY" | head -c 200)"

PLUGIN_JSON="$(printf '%s' "$BODY" | jq -r --arg name "$PLUGIN_NAME" '.plugins[]? | select(.name == $name)')"
[ -n "$PLUGIN_JSON" ] || alert "plugin '${PLUGIN_NAME}' not found in the gateway plugin list — it was never created or was deleted. Recreate it: PUT the artifact path to /api/plugins/${PLUGIN_NAME}"

PLUGIN_PATH="$(printf '%s' "$PLUGIN_JSON" | jq -r '.path // empty')"
BASENAME="${PLUGIN_PATH##*/}"
if [ -n "$PLUGIN_PATH" ]; then
  PLUGIN_VERSION="$(printf '%s' "$BASENAME" | sed -nE 's/.*ent-v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
fi

printf '%s' "$PLUGIN_JSON" | jq -e '
  .enabled == true and
  .status.status == "active" and
  .actualName != null and .actualName != "" and
  (.status.types | index("llm") != null)
' >/dev/null || alert "plugin '${PLUGIN_NAME}' is NOT healthy — policy enforcement is DOWN. Status: $(printf '%s' "$PLUGIN_JSON" | jq -c '{enabled, status: .status.status, logs: .status.logs}'). Action: if the gateway was upgraded to v${GW_VERSION}, rebuild for ent-v${GW_VERSION} (trigger the 'Build Secure Policy Plugin' workflow for ent-v${GW_VERSION}) and PUT the new artifact path to /api/plugins/${PLUGIN_NAME}; if the version matches, read status.logs for the load error (core/glibc/module mismatch) and rebuild accordingly."

[ -n "$PLUGIN_VERSION" ] || alert "cannot parse the built-for version from the plugin path: ${BASENAME:-<no path>} — artifact filenames must contain ent-v<X.Y.Z>. Rename/redeploy the artifact so version checks work."

if [ "$GW_VERSION" = "$PLUGIN_VERSION" ]; then
  info "gateway v${GW_VERSION} = plugin built for v${PLUGIN_VERSION} — plugin active and enforcing (${BASENAME})"
else
  alert "VERSION MISMATCH — the gateway was upgraded to v${GW_VERSION} but the loaded plugin was built for v${PLUGIN_VERSION} (${BASENAME}). The plugin will fail to load on the upgraded gateway (silent zero policy enforcement). Action: trigger the 'Build Secure Policy Plugin' workflow for ent-v${GW_VERSION} (Actions tab on darkmattermistress/e0e134a9-665b-40cd-8e5d-76c3af51c2df), wait for the bot commit in build/, then PUT the new artifact path to /api/plugins/${PLUGIN_NAME}."
fi
