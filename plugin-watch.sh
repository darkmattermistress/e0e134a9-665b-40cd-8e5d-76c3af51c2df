#!/bin/bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Bifrost secure-code-policy plugin watcher. Two checks per run:

1. Plugin health — GET /api/plugins: the plugin must exist, be enabled, be
   status "active", and implement the "llm" interface.
2. Version match — the gateway's version (GET /api/version, e.g.
   "v2.2.3-enterprise") must match the ent-version the loaded artifact was
   built for (parsed from the plugin's configured path, e.g.
   .../secure-policy-plugin-ent-v2.2.3-core1103.so -> 2.2.3).

Exit 0 = healthy and version-matched. Exit 1 = ALERT (unhealthy, missing,
unparseable, or version mismatch) with an actionable message on stderr.
Note: GET /health does NOT cover plugins — this script is the check.

Options:
  --gateway <url>     Gateway base URL (default: \$BIFROST_GATEWAY or
                     https://llm-gateway-prod.growwcorp.in)
  --plugin <name>     Plugin display name from config (default: secure-code-policy)
  --key-file <path>   File containing the Bifrost management API key
                     (scopes: Plugins:View). Key is read, never logged.
  --cookie <value>    Dashboard session cookie instead of an API key
                     (manual one-off runs only)
  --notify-cmd <cmd>  Shell command executed when the run ALERTS (e.g. a
                     Slack/PagerDuty webhook curl). Receives the alert text
                     on stdin.

The management API key can also be provided via \$BIFROST_MGMT_KEY.
Virtual keys (sk-bf-*) do NOT work on management APIs.

Cron example (every 5 min, log + notify hook):
  */5 * * * * /path/to/plugin-watch.sh --key-file ~/.config/bifrost/mgmt-key \\
    --notify-cmd 'curl -s -X POST -H "Content-type: application/json" \\
    -d @- https://hooks.slack.com/services/XXX' \\
    >> ~/Library/Logs/bifrost-plugin-watch.log 2>&1
EOF
  exit 1
}

alert() {
  echo "ALERT [$(date -u '+%Y-%m-%dT%H:%M:%SZ')]: $*" >&2
  if [ -n "$NOTIFY_CMD" ]; then
    printf '%s\n' "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | bash -c "$NOTIFY_CMD" || true
  fi
  exit 1
}
info() { echo "OK   [$(date -u '+%Y-%m-%dT%H:%M:%SZ')]: $*"; }

GATEWAY="${BIFROST_GATEWAY:-https://llm-gateway-prod.growwcorp.in}"
PLUGIN_NAME="secure-code-policy"
KEY_FILE=""
COOKIE=""
NOTIFY_CMD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --gateway)     [ $# -ge 2 ] || alert "--gateway needs a value"; GATEWAY="$2"; shift 2 ;;
    --plugin)      [ $# -ge 2 ] || alert "--plugin needs a value"; PLUGIN_NAME="$2"; shift 2 ;;
    --key-file)    [ $# -ge 2 ] || alert "--key-file needs a value"; KEY_FILE="$2"; shift 2 ;;
    --cookie)      [ $# -ge 2 ] || alert "--cookie needs a value"; COOKIE="$2"; shift 2 ;;
    --notify-cmd)  [ $# -ge 2 ] || alert "--notify-cmd needs a value"; NOTIFY_CMD="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *)             alert "unknown option: $1 (see --help)" ;;
  esac
done

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

command -v curl >/dev/null || alert "curl not found"
command -v jq >/dev/null || alert "jq not found"

AUTH_ARGS=()
if [ -n "$COOKIE" ]; then
  AUTH_ARGS=(-b "bf_oidc_session=${COOKIE}")
else
  KEY="${BIFROST_MGMT_KEY:-}"
  if [ -z "$KEY" ] && [ -n "$KEY_FILE" ]; then
    [ -f "$KEY_FILE" ] || alert "key file not found: $KEY_FILE"
    KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
  fi
  [ -n "$KEY" ] || alert "no management API key: set BIFROST_MGMT_KEY or use --key-file"
  AUTH_ARGS=(-H "Authorization: Bearer ${KEY}")
fi

GW_VERSION_RAW="$(curl -s "${GATEWAY%/}/api/version")"
GW_VERSION="$(printf '%s' "$GW_VERSION_RAW" | tr -d '"' | sed -nE 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
[ -n "$GW_VERSION" ] || alert "cannot parse gateway version from /api/version response: ${GW_VERSION_RAW:-<empty>}"

RESP="$(curl -s "${AUTH_ARGS[@]}" -w $'\n%{http_code}' "${GATEWAY%/}/api/plugins")"
HTTP_CODE="${RESP##*$'\n'}"
BODY="${RESP%$'\n'*}"
[ "$HTTP_CODE" = "200" ] || alert "GET /api/plugins returned HTTP ${HTTP_CODE}: $(printf '%s' "$BODY" | head -c 300)"

PLUGIN_JSON="$(printf '%s' "$BODY" | jq -r --arg name "$PLUGIN_NAME" '.plugins[]? | select(.name == $name)')"
[ -n "$PLUGIN_JSON" ] || alert "plugin '${PLUGIN_NAME}' not found in the gateway plugin list — it was never created or was deleted"

printf '%s' "$PLUGIN_JSON" | jq -e '
  .enabled == true and
  .status.status == "active" and
  .actualName != null and .actualName != "" and
  (.status.types | index("llm") != null)
' >/dev/null || alert "plugin '${PLUGIN_NAME}' is NOT healthy — policy enforcement is DOWN. status: $(printf '%s' "$PLUGIN_JSON" | jq -c '{enabled, status: .status.status, logs: .status.logs}')"

PLUGIN_PATH="$(printf '%s' "$PLUGIN_JSON" | jq -r '.path // empty')"
[ -n "$PLUGIN_PATH" ] || alert "plugin '${PLUGIN_NAME}' has no path configured — cannot determine which version it was built for"
BASENAME="${PLUGIN_PATH##*/}"
PLUGIN_VERSION="$(printf '%s' "$BASENAME" | sed -nE 's/.*ent-v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
[ -n "$PLUGIN_VERSION" ] || alert "cannot parse the built-for version from plugin path: ${BASENAME} (artifact filename must contain ent-v<X.Y.Z>)"

if [ "$GW_VERSION" = "$PLUGIN_VERSION" ]; then
  info "gateway v${GW_VERSION} = plugin built for v${PLUGIN_VERSION} — plugin active and enforcing (${BASENAME})"
else
  alert "VERSION MISMATCH: gateway runs v${GW_VERSION} but the loaded plugin was built for v${PLUGIN_VERSION} (${BASENAME}). Rebuild for the new gateway: trigger the 'Build Secure Policy Plugin' workflow for ent-v${GW_VERSION} (Actions tab), then PUT the new artifact path to /api/plugins/${PLUGIN_NAME}. Until then the plugin may fail to load on the upgraded gateway."
fi
