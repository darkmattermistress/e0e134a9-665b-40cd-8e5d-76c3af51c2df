# secure-policy-plugin-anthfix — v1.1 (anth-fix variant)

Bifrost plugin that injects a mandatory secure-coding policy into every LLM request
passing through the gateway, and logs whether the policy was injected.

## What changed from previous version (bifrost-11-aug)

| Property | Old | New |
|---|---|---|
| bifrost/core | v1.7.10 | v1.10.4 |
| Target Bifrost release | Enterprise v1.5.10 | Enterprise v2.2.3 |
| PostLLMHook | no-op | no-op (required interface stub, does nothing) |
| Go version | 1.26.5 | 1.27.0 |
| GOOS | linux | linux (unchanged) |
| GOARCH | amd64 | amd64 (unchanged) |
| CGO_ENABLED | 1 | 1 (unchanged) |
| GOAMD64 | v1 | v1 (unchanged) |
| buildmode | plugin | plugin (unchanged) |
| trimpath | true | true (unchanged) |

## Build specification

Matches Bifrost Enterprise v2.2.3 deployed binary exactly:

```
Go version  : go1.27.0
GOOS        : linux
GOARCH      : amd64
GOAMD64     : v1
CGO_ENABLED : 1
buildmode   : plugin
trimpath    : true
bifrost/core: v1.10.4
```

## Plugin behaviour

### PreRequestHook (primary injection — committed phase)
Injects the secure-coding policy (OWASP Top 10 / CWE Top 25) into the request before any
provider attempt. Mutations made here are committed and observed by every fallback attempt.

- Chat shape: inserts a **new leading system message at input[0]** — never prepends into an
  existing system message, which may sit mid-conversation and get demoted to an inlined
  `<system-reminder>` user turn (advisory, ignorable by Claude) on the Anthropic outbound
  conversion instead of the top-level `system` param.
- Responses shape: if the input already contains a system/developer-role message, inserts a
  new leading system message (guaranteed hoist to the top-level `system` param, policy first).
  Otherwise, if `params.instructions` is set, prepends the policy there (the Responses-native
  system channel — also avoids the core behaviour where a hoisted system message silently
  drops the client's `instructions` entirely). Otherwise inserts a leading system message.

### PreLLMHook (per-attempt re-verify)
Runs once per provider attempt. Re-applies the injection **idempotently** (marker-based, so
never double-injects) — covers any layer that rebuilds the attempt request — and logs
presence at provider-call time:

Logs: `secure policy (anthfix) injected into chat request` / `secure policy (anthfix) injected into responses request` / `secure policy (anthfix) present at provider call: true|false`

### PostLLMHook
No-op — required by the plugin interface, kept as an empty stub. No response logging.

Plugin name: `secure-policy-plugin-anthfix` (loadable alongside `secure-policy-plugin` for A/B).

## How to build

### CI (preferred)

Run the **Build Secure Policy Plugin** workflow (Actions tab → *Run workflow*), passing the
target Bifrost version (e.g. `ent-v2.2.3`) and — when the changelog's plugin-deps block and
Base OSS section disagree — the `core_version` that matches the deployed gateway. The workflow
aligns deps, builds linux/amd64, verifies the embedded versions, and commits the artifact to
the repo `build/` folder as `secure-policy-plugin-ent-<version>-core<tag>.so`.

### Local (macOS requires Docker)

```bash
# 1. Download and vendor all dependencies (once)
make setup

# 2. Build the plugin
make build-docker
# Output: build/secure-policy-plugin-anthfix.so

# 3. Verify embedded bifrost/core version matches
make verify
```

Or use the repo root `rebuild-plugin.sh --version <ent-version> [--core <vX.Y.Z>]`, which
fetches the release deps and handles the version pinning automatically.

## Deploying to Bifrost

Upload `build/secure-policy-plugin-anthfix.so` through the Bifrost admin UI, or reference it
in config:

```json
{
  "plugins": [
    {
      "enabled": true,
      "name": "secure-policy-plugin-anthfix",
      "path": "/path/to/secure-policy-plugin-anthfix.so",
      "version": 1,
      "config": {}
    }
  ]
}
```
