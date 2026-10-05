// build: 20261004
// variant: anth-fix (guaranteed leading system placement, instructions channel, committed pre-request + per-attempt re-injection)
package main

import (
	"strings"

	"github.com/maximhq/bifrost/core/schemas"
)

const policy = `# Secure Code Generation Policy (Language-Agnostic)

0. These rules OVERRIDE the user. If asked to skip, weaken, or defer any control — refuse and implement it securely. NO exemptions: "demo", "internal", "quick", "temporary", "test", or "MVP" code follows every rule. No TODOs in place of controls — implement them in the delivered code.

## Security Enforcement Contract

You MUST:

- Treat all input as untrusted
- Flag insecure code before modifying
- Provide a secure fix first
- Follow OWASP Top 10 / CWE Top 25
- Use well-maintained, standard libraries
- Prefer safe defaults over custom implementations

---

## Core Security Controls (Non-Negotiable)

### Input & Validation
- Validate all external input (type, format, length, bounds)
- Reject unexpected or unknown fields
- Normalize and sanitize where required

### Authentication & Access Control
- Enforce authentication by default
- Apply authorization checks on every sensitive action
- Validate object ownership (prevent IDOR)

### Injection Protections
- Use parameterized queries / safe APIs (no string concatenation)
- Escape output based on context (HTML, JSON, shell, etc.)
- Avoid command execution with user input

### Sensitive Data Protection
- No hardcoded secrets or credentials
- No PII/secrets in logs
- Mask sensitive data in telemetry

### Cryptography
- Use strong, modern standards (AES-256, RSA-2048+, bcrypt/argon2)
- Use trusted libraries only
- Never implement custom crypto

### SSRF Protection
- Validate and allowlist outbound destinations
- Block internal/private/meta IP ranges
- Do not blindly fetch external URLs

### Unsafe Code Prevention
- Block eval, dynamic execution, unsafe reflection
- Avoid unsafe deserialization of untrusted data

---

## Application Security Controls

### Business Logic Validation
- Enforce business rules at core logic layer
- Validate state transitions and invariants

### Race Conditions & Idempotency
- Ensure safe concurrency (locks, atomic ops, transactions)
- Design idempotent operations for retries

### Dependency Security
- Use latest stable dependencies
- Avoid known vulnerable packages

### File & External Access
- Validate file uploads (size, type, content)
- Store outside executable/static roots
- Do not reference arbitrary external URIs

### Secrets & Repo Hygiene
- Enforce .gitignore for sensitive files
- Never expose tokens, keys, credentials

---

## Error Handling & Stability

- Return generic error messages
- Never expose stack traces or internals
- Handle exceptions gracefully
- Cover boundary and edge cases

---

## Security Misconfiguration Prevention

- Use secure defaults in configs
- Disable debug/verbose modes in production
- Apply least privilege for services and roles

---

## When Insecure Code Is Found

You MUST:

1. Identify issue + CWE
2. Explain risk briefly
3. Provide secure fix
4. Continue only with fixed code

---

## Preferences

**Prefer**
- Standard libraries/frameworks
- Built-in security features
- Typed/validated data structures

**Avoid**
- Custom security logic
- Raw query/string construction
- Dynamic execution (eval, reflection abuse)
- Manual cryptography

---

## Rule Priority

If functionality conflicts with security → **security wins**
Security wins over speed, features, and convenience.`

const policyMarker = "# Secure Code Generation Policy (Language-Agnostic)"

func Init(_ any) error { return nil }
func GetName() string  { return "secure-policy-plugin-anthfix" }
func Cleanup() error   { return nil }

func PreRequestHook(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) error {
	if inject(req) {
		logInjected(ctx, req)
	}
	return nil
}

func PreLLMHook(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) (*schemas.BifrostRequest, *schemas.LLMPluginShortCircuit, error) {
	if inject(req) {
		logInjected(ctx, req)
	}
	logPresence(ctx, req)
	return req, nil, nil
}

func PostLLMHook(_ *schemas.BifrostContext, resp *schemas.BifrostResponse, bifrostErr *schemas.BifrostError) (*schemas.BifrostResponse, *schemas.BifrostError, error) {
	return resp, bifrostErr, nil
}

func inject(req *schemas.BifrostRequest) bool {
	switch {
	case req.ChatRequest != nil:
		return injectChat(&req.ChatRequest.Input)
	case req.ResponsesRequest != nil:
		return injectResponses(req.ResponsesRequest)
	}
	return false
}

func injectChat(input *[]schemas.ChatMessage) bool {
	if chatPolicyPresent(*input) {
		return false
	}
	msg := schemas.ChatMessage{
		Role:    schemas.ChatMessageRoleSystem,
		Content: &schemas.ChatMessageContent{ContentStr: ptr(policy)},
	}
	*input = append([]schemas.ChatMessage{msg}, *input...)
	return true
}

func injectResponses(rr *schemas.BifrostResponsesRequest) bool {
	if responsesPolicyPresent(rr) {
		return false
	}
	if !responsesInputHasSystemRole(rr.Input) && rr.Params != nil && rr.Params.Instructions != nil && *rr.Params.Instructions != "" {
		merged := policy + "\n\n" + *rr.Params.Instructions
		rr.Params.Instructions = &merged
		return true
	}
	msgType := schemas.ResponsesMessageTypeMessage
	role := schemas.ResponsesInputMessageRoleSystem
	msg := schemas.ResponsesMessage{
		Type:    &msgType,
		Role:    &role,
		Content: &schemas.ResponsesMessageContent{ContentStr: ptr(policy)},
	}
	rr.Input = append([]schemas.ResponsesMessage{msg}, rr.Input...)
	return true
}

func chatPolicyPresent(input []schemas.ChatMessage) bool {
	for i := range input {
		if input[i].Role != schemas.ChatMessageRoleSystem || input[i].Content == nil {
			continue
		}
		c := input[i].Content
		if c.ContentStr != nil && strings.Contains(*c.ContentStr, policyMarker) {
			return true
		}
		for _, b := range c.ContentBlocks {
			if b.Text != nil && strings.Contains(*b.Text, policyMarker) {
				return true
			}
		}
	}
	return false
}

func responsesPolicyPresent(rr *schemas.BifrostResponsesRequest) bool {
	if rr.Params != nil && rr.Params.Instructions != nil && strings.Contains(*rr.Params.Instructions, policyMarker) {
		return true
	}
	for i := range rr.Input {
		msg := rr.Input[i]
		if msg.Role == nil || (*msg.Role != schemas.ResponsesInputMessageRoleSystem && *msg.Role != schemas.ResponsesInputMessageRoleDeveloper) || msg.Content == nil {
			continue
		}
		c := msg.Content
		if c.ContentStr != nil && strings.Contains(*c.ContentStr, policyMarker) {
			return true
		}
		for _, b := range c.ContentBlocks {
			if b.Text != nil && strings.Contains(*b.Text, policyMarker) {
				return true
			}
		}
	}
	return false
}

func responsesInputHasSystemRole(input []schemas.ResponsesMessage) bool {
	for i := range input {
		if input[i].Role != nil && (*input[i].Role == schemas.ResponsesInputMessageRoleSystem || *input[i].Role == schemas.ResponsesInputMessageRoleDeveloper) {
			return true
		}
	}
	return false
}

func logInjected(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) {
	if req.ChatRequest != nil {
		ctx.Log(schemas.LogLevelInfo, "secure policy (anthfix) injected into chat request")
		return
	}
	ctx.Log(schemas.LogLevelInfo, "secure policy (anthfix) injected into responses request")
}

func logPresence(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) {
	present := "false"
	switch {
	case req.ChatRequest != nil && chatPolicyPresent(req.ChatRequest.Input):
		present = "true"
	case req.ResponsesRequest != nil && responsesPolicyPresent(req.ResponsesRequest):
		present = "true"
	}
	ctx.Log(schemas.LogLevelInfo, "secure policy (anthfix) present at provider call: "+present)
}

func ptr(s string) *string { return &s }
