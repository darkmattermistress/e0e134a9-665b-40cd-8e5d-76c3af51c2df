# secure-policy-plugin — v1.0

Bifrost plugin that injects a mandatory secure-coding policy into every LLM request
passing through the gateway, and logs whether the policy was injected.

## What changed from previous version (bifrost-11-aug)

| Property | Old | New |
|---|---|---|
| bifrost/core | v1.7.10 | v1.10.3 |
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
bifrost/core: v1.10.3
```

## Plugin behaviour

### PreLLMHook
Injects the secure-coding policy (OWASP Top 10 / CWE Top 25) as a system prompt
into every outbound LLM request before it reaches the provider. If a system message
already exists, the policy is prepended to it. Handles both Chat and Responses API shapes.

Logs: `secure policy injected into chat request` / `secure policy injected into responses request`

### PostLLMHook
No-op — required by the plugin interface, kept as an empty stub. No response logging.

## How to build

> Must be built on a Linux/amd64 host (or via Docker) — CGO_ENABLED=1 requires
> a native C toolchain for the target platform. Cross-compiling from macOS will fail.

```bash
# 1. Download and vendor all dependencies (once)
make setup

# 2. Build the plugin
make build
# Output: build/secure-policy-plugin-user.so

# 3. Verify embedded bifrost/core version matches
make verify
```

## Deploying to Bifrost

Upload `build/secure-policy-plugin-user.so` through the Bifrost admin UI, or reference it
in config:

```json
{
  "plugins": [
    {
      "enabled": true,
      "name": "secure-policy-plugin",
      "path": "/path/to/secure-policy-plugin-user.so",
      "version": 1,
      "config": {}
    }
  ]
}
```
