#!/bin/bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Checks that the secure-code-policy plugin is loaded and enforcing on a Bifrost
gateway, via GET /api/plugins. Exits 0 only when the plugin is enabled, its
status is "active", and it implements the "llm" interface. On failure, prints
the plugin's status.logs (the load error) and exits 1.

Designed for cron/alerting and for an automatic check after every Bifrost
upgrade (the plugin silently stops loading on core/glibc mismatch, and GET
/health does NOT cover plugins).

Options:
  --gateway <url>     Gateway base URL (default: \$BIFROST_GATEWAY or
                     https://llm-gateway-prod.growwcorp.in)
  --plugin <name>    Plugin display name from config (default: secure-code-policy)
  --key-file <path>  File containing the Bifrost management API key (scoped
                     Plugins:View). Key is read, never logged.
  --cookie <value>   Authenticate with a dashboard session cookie instead of
                     an API key (manual one-off checks only — cookies expire)

The management API key can also be provided via \$BIFROST_MGMT_KEY.
Virtual keys (sk-bf-*) do NOT work on management APIs.

Examples:
  BIFROST_MGMT_KEY=... $(basename "$0")
  $(basename "$0") --key-file /run/secrets/bifrost-mgmt-key
  */5 * * * * BIFROST_MGMT_KEY=... $(basename "$0") --gateway https://llm-gateway-stage.growwcorp.in || page-oncall
EOF
  exit 1
}

die() { echo "UNHEALTHY: $*" >&2; exit 1; }

GATEWAY="${BIFROST_GATEWAY:-https://llm-gateway-prod.growwcorp.in}"
PLUGIN_NAME="secure-code-policy"
KEY_FILE=""
COOKIE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --gateway)      [ $# -ge 2 ] || die "--gateway needs a value"; GATEWAY="$2"; shift 2 ;;
    --plugin)       [ $# -ge 2 ] || die "--plugin needs a value"; PLUGIN_NAME="$2"; shift 2 ;;
    --key-file)     [ $# -ge 2 ] || die "--key-file needs a value"; KEY_FILE="$2"; shift 2 ;;
    --cookie)       [ $# -ge 2 ] || die "--cookie needs a value"; COOKIE="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *)              die "unknown option: $1 (see --help)" ;;
  esac
done

command -v curl >/dev/null || die "curl not found"
command -v jq >/dev/null || die "jq not found"

AUTH_ARGS=()
if [ -n "$COOKIE" ]; then
  AUTH_ARGS=(-b "bf_oidc_session=${COOKIE}")
else
  KEY="${BIFROST_MGMT_KEY:-}"
  if [ -z "$KEY" ] && [ -n "$KEY_FILE" ]; then
    [ -f "$KEY_FILE" ] || die "key file not found: $KEY_FILE"
    KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
  fi
  [ -n "$KEY" ] || die "no management API key: set BIFROST_MGMT_KEY or use --key-file (virtual keys sk-bf-* do not work on /api/*)"
  AUTH_ARGS=(-H "Authorization: Bearer ${KEY}")
fi

URL="${GATEWAY%/}/api/plugins"
RESP="$(curl -s "${AUTH_ARGS[@]}" -w $'\n%{http_code}' "$URL")"
HTTP_CODE="${RESP##*$'\n'}"
BODY="${RESP%$'\n'*}"

[ "$HTTP_CODE" = "200" ] || die "GET $URL returned HTTP ${HTTP_CODE}: $(printf '%s' "$BODY" | head -c 300)"

PLUGIN_JSON="$(printf '%s' "$BODY" | jq -r --arg name "$PLUGIN_NAME" '.plugins[]? | select(.name == $name)')"
[ -n "$PLUGIN_JSON" ] || die "plugin '${PLUGIN_NAME}' not found in the gateway plugin list — it was never created or was deleted"

printf '%s' "$PLUGIN_JSON" | jq -e '
  .enabled == true and
  .status.status == "active" and
  .actualName != null and .actualName != "" and
  (.status.types | index("llm") != null)
' >/dev/null || {
  echo "UNHEALTHY: plugin '${PLUGIN_NAME}' is not loaded/active — policy enforcement is DOWN on this gateway" >&2
  echo "--- plugin status ---" >&2
  printf '%s' "$PLUGIN_JSON" | jq '{name, actualName, enabled, status: .status.status, logs: .status.logs, types: .status.types}' >&2
  exit 1
}

STATUS="$(printf '%s' "$PLUGIN_JSON" | jq -r '.status.status')"
TYPES="$(printf '%s' "$PLUGIN_JSON" | jq -c '.status.types')"
echo "HEALTHY: ${PLUGIN_NAME} — status=${STATUS}, types=${TYPES}"
