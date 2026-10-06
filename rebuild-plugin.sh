#!/bin/bash
set -euo pipefail

DOCS_HOST="docs.getbifrost.ai"
DOCS_BASE="https://${DOCS_HOST}/changelogs"

usage() {
  cat <<EOF
Usage: $(basename "$0") --version <ent-version> [options]
   or: $(basename "$0") --url <changelog-url> [options]

Rebuilds the Bifrost secure-policy plugin as a linux/amd64 .so against the
exact deps the target Bifrost release pins for plugins.

Options:
  --version <v>     Bifrost ent version, e.g. ent-v2.2.3
                    (changelog URL: ${DOCS_BASE}/<v>)
  --url <url>       Full changelog URL (anchors allowed; host must be
                    ${DOCS_HOST})
  --core <version>  Optional manual override of the bifrost/core version.
                    Leave it out: the version is auto-resolved from the
                    changelog (the Base OSS version section wins if the docs
                    contradict themselves). Use only if the built plugin
                    then fails to load on the gateway.
  --dir <path>      Plugin source dir (default: <repo>/secure-policy-plugin)
  --name <name>     Output artifact base name (default: PLUGIN_NAME from
                    Makefile + -core<tag>, e.g. secure-policy-plugin-anthfix-core1103)
  --ref <file.so>   Known-good loaded .so; dep sets are diffed after build
  --dry-run         Fetch, parse and print the plan; modify nothing
  -h, --help        Show this help

Examples:
  $(basename "$0") --version ent-v2.2.3 --core v1.10.3
  $(basename "$0") --url "https://${DOCS_HOST}/changelogs/ent-v2.2.3#if-you-are-compiling-plugin-against-this-release-use-following-deps" --core v1.10.3
EOF
  exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

VERSION="" URL="" CORE_OVERRIDE="" PLUGIN_DIR="" OUT_NAME="" REF="" DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --url)     [ $# -ge 2 ] || die "--url needs a value"; URL="$2"; shift 2 ;;
    --core)    [ $# -ge 2 ] || die "--core needs a value"; CORE_OVERRIDE="$2"; shift 2 ;;
    --dir)     [ $# -ge 2 ] || die "--dir needs a value"; PLUGIN_DIR="$2"; shift 2 ;;
    --name)    [ $# -ge 2 ] || die "--name needs a value"; OUT_NAME="$2"; shift 2 ;;
    --ref)     [ $# -ge 2 ] || die "--ref needs a value"; REF="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$VERSION" ] || [ -n "$URL" ] || die "need --version or --url (see --help)"
[ -z "$VERSION" ] || [ -z "$URL" ] || die "--version and --url are mutually exclusive"

if [ -n "$VERSION" ]; then
  URL="${DOCS_BASE}/${VERSION}"
fi
URL="${URL%%#*}"
case "$URL" in
  "https://${DOCS_HOST}/"*) ;;
  *) die "refusing to fetch non-${DOCS_HOST} URL: $URL" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR="${SCRIPT_DIR}/secure-policy-plugin"
fi
[ -f "${PLUGIN_DIR}/main.go" ] || die "no main.go in ${PLUGIN_DIR} (use --dir)"
[ -f "${PLUGIN_DIR}/go.mod" ] || die "no go.mod in ${PLUGIN_DIR} (use --dir)"
[ -f "${PLUGIN_DIR}/Makefile" ] || die "no Makefile in ${PLUGIN_DIR} (use --dir)"

command -v curl >/dev/null || die "curl not found"
command -v go >/dev/null || die "go not found"

TMP="$(mktemp -d /tmp/bifrost-rebuild.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

info "fetching changelog: ${URL}.md"
curl -sL --fail "${URL}.md" -o "${TMP}/changelog.md" || die "failed to fetch ${URL}.md (does the version exist?)"

DEPS_BLOCK="$(sed -n '/```go/,/^```$/p' "${TMP}/changelog.md" | sed '1d;$d')"
[ -n "$DEPS_BLOCK" ] || die "could not extract the plugin-deps go.mod block from the changelog"

GO_VERSION="$(printf '%s\n' "$DEPS_BLOCK" | grep -E '^[[:space:]]*go [0-9]' | head -1 | awk '{print $2}')"
DEPS_CORE="$(printf '%s\n' "$DEPS_BLOCK" | grep -E '^[[:space:]]*github\.com/maximhq/bifrost/core[[:space:]]' | head -1 | awk '{print $2}')"
BASE_CORE="$(grep -A 3 'Base OSS version' "${TMP}/changelog.md" | grep -oE 'core[[:space:]]+`v[0-9]+\.[0-9]+\.[0-9]+`' | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"

[ -n "$GO_VERSION" ] || die "could not parse go version from deps block"
[ -n "$DEPS_CORE" ] || die "could not parse bifrost/core version from deps block"

info "changelog plugin-deps block : go ${GO_VERSION}, bifrost/core ${DEPS_CORE}"
if [ -n "$BASE_CORE" ]; then
  info "changelog Base OSS section  : bifrost/core ${BASE_CORE}"
else
  info "changelog Base OSS section  : (not found)"
fi

if [ -n "$BASE_CORE" ] && [ "$DEPS_CORE" != "$BASE_CORE" ]; then
  CORE="${CORE_OVERRIDE:-$BASE_CORE}"
  echo "WARNING: the changelog contradicts itself: plugin-deps block says ${DEPS_CORE}, Base OSS section says ${BASE_CORE}." >&2
  echo "         Auto-selected ${CORE} (Base OSS section = what the deployed gateway is built with)." >&2
  echo "         If the built plugin fails to load, re-run with --core ${DEPS_CORE}." >&2
else
  CORE="${CORE_OVERRIDE:-$DEPS_CORE}"
fi
if [ -n "$CORE_OVERRIDE" ]; then
  info "using --core override: ${CORE}"
fi

MAKEFILE_PLUGIN_NAME="$(grep -E '^PLUGIN_NAME' "${PLUGIN_DIR}/Makefile" | head -1 | awk '{print $3}')"
[ -n "$MAKEFILE_PLUGIN_NAME" ] || die "could not parse PLUGIN_NAME from ${PLUGIN_DIR}/Makefile"

CORE_TAG="$(printf '%s' "$CORE" | tr -d 'v.')"
OUT="${OUT_NAME:-${MAKEFILE_PLUGIN_NAME}-core${CORE_TAG}}"
ARTIFACT="${PLUGIN_DIR}/build/${OUT}.so"

echo
info "plan"
echo "  plugin dir   : ${PLUGIN_DIR}"
echo "  bifrost/core : ${CORE}"
echo "  go version   : ${GO_VERSION}"
echo "  target       : linux/amd64, CGO_ENABLED=1, GOAMD64=v1, buildmode=plugin, trimpath, stripped"
echo "  artifact     : ${ARTIFACT}"

if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run — nothing modified"
  exit 0
fi

info "aligning deps in ${PLUGIN_DIR} (go mod edit/tidy/vendor)"
ORIGINAL_MODULE="$(grep -E '^module ' "${PLUGIN_DIR}/go.mod" | awk '{print $2}')"
BUILD_STAMP="$(date -u +%Y%m%d%H%M%S)"
VARIANT_MODULE="${ORIGINAL_MODULE}/${ENT_VERSION:-local}-core${CORE_TAG}-${BUILD_STAMP}"
(
  cd "${PLUGIN_DIR}"
  go mod edit -module "${VARIANT_MODULE}"
  go mod edit -require="github.com/maximhq/bifrost/core@${CORE}"
  go mod edit -go="${GO_VERSION}"
  go mod tidy
  go mod vendor
) || die "go mod operations failed"

sed -i '' -E "s|^(BIFROST_CORE[[:space:]]*:=).*$|\1 ${CORE}|" "${PLUGIN_DIR}/Makefile"
sed -i '' -E "s|^(GO_VERSION[[:space:]]*:=).*$|\1 ${GO_VERSION}|" "${PLUGIN_DIR}/Makefile"

command -v docker >/dev/null || die "docker not found (required for linux/amd64 build)"
info "building linux/amd64 plugin via Docker (golang:${GO_VERSION})"
info "module identity: ${VARIANT_MODULE} (unique per build — always loadable alongside any plugin already loaded)"
mkdir -p "${PLUGIN_DIR}/build"
docker run --rm \
  --platform linux/amd64 \
  -v "${PLUGIN_DIR}":/plugin \
  -w /plugin \
  "golang:${GO_VERSION}" \
  sh -c "GOOS=linux GOARCH=amd64 CGO_ENABLED=1 GOAMD64=v1 \
    go build -trimpath -buildmode=plugin -mod=vendor \
    -o build/${OUT}.so . && strip build/${OUT}.so" \
  || die "docker build failed"

(
  cd "${PLUGIN_DIR}"
  go mod edit -module "${ORIGINAL_MODULE}"
  go mod tidy
  go mod vendor
) || die "failed to restore canonical module in ${PLUGIN_DIR}/go.mod"

info "verifying embedded versions"
ACTUAL_CORE="$(go version -m "$ARTIFACT" | grep -E 'dep[[:space:]]+github\.com/maximhq/bifrost/core' | head -1 | awk '{print $3}')"
BUILT_GO="$(go version -m "$ARTIFACT" | head -1 | awk '{print $2}')"
ACTUAL_PATH="$(go version -m "$ARTIFACT" | grep -E '^	path' | awk '{print $2}')"
[ "$ACTUAL_CORE" = "$CORE" ] || die "embedded core ${ACTUAL_CORE} != expected ${CORE}"
[ "$ACTUAL_PATH" = "$VARIANT_MODULE" ] || die "embedded module path '${ACTUAL_PATH}' != expected '${VARIANT_MODULE}'"
echo "  built with   : ${BUILT_GO}"
echo "  bifrost/core : ${ACTUAL_CORE}"
echo "  module path  : ${ACTUAL_PATH}"

if [ -n "$REF" ]; then
  [ -f "$REF" ] || die "reference .so not found: ${REF}"
  info "diffing dep sets against reference: ${REF}"
  if diff <(go version -m "$REF" | grep -E '^	dep' | sort) \
           <(go version -m "$ARTIFACT" | grep -E '^	dep' | sort); then
    echo "  dep sets IDENTICAL to reference — same host ABI, will load alongside it"
  else
    echo "  ^^ dep sets differ from the reference (expected after an upgrade)." >&2
    echo "  Reference = plugin known to load on the CURRENT gateway:" >&2
    echo "  only deploy the new .so after the gateway itself is upgraded." >&2
  fi
fi

echo
info "done: ${ARTIFACT}"
echo "     embedded bifrost/core ${ACTUAL_CORE}, built with ${BUILT_GO}"
