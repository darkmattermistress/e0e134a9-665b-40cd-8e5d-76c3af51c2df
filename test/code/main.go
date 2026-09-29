// build: 20260925
// variant: user-prompt injection (policy sent as user role instead of system role)
package main

import (
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

func Init(_ any) error { return nil }
func GetName() string  { return "secure-policy-plugin-user" }
func Cleanup() error   { return nil }

func PreRequestHook(_ *schemas.BifrostContext, _ *schemas.BifrostRequest) error {
	return nil
}

func PreLLMHook(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) (*schemas.BifrostRequest, *schemas.LLMPluginShortCircuit, error) {
	switch {
	case req.ChatRequest != nil:
		injectChat(&req.ChatRequest.Input)
		ctx.Log(schemas.LogLevelInfo, "secure policy injected into chat request as user prompt")
	case req.ResponsesRequest != nil:
		injectResponses(&req.ResponsesRequest.Input)
		ctx.Log(schemas.LogLevelInfo, "secure policy injected into responses request as user prompt")
	}
	return req, nil, nil
}

func PostLLMHook(_ *schemas.BifrostContext, resp *schemas.BifrostResponse, bifrostErr *schemas.BifrostError) (*schemas.BifrostResponse, *schemas.BifrostError, error) {
	return resp, bifrostErr, nil
}

func injectChat(input *[]schemas.ChatMessage) {
	for i := range *input {
		if (*input)[i].Role == schemas.ChatMessageRoleUser {
			prependChatContent(&(*input)[i])
			return
		}
	}
	msg := schemas.ChatMessage{
		Role:    schemas.ChatMessageRoleUser,
		Content: &schemas.ChatMessageContent{ContentStr: ptr(policy)},
	}
	*input = append([]schemas.ChatMessage{msg}, *input...)
}

func prependChatContent(msg *schemas.ChatMessage) {
	if msg.Content == nil {
		msg.Content = &schemas.ChatMessageContent{ContentStr: ptr(policy)}
		return
	}
	if msg.Content.ContentStr != nil {
		merged := policy + "\n\n" + *msg.Content.ContentStr
		msg.Content.ContentStr = &merged
		return
	}
	msg.Content.ContentBlocks = append(
		[]schemas.ChatContentBlock{{Type: schemas.ChatContentBlockTypeText, Text: ptr(policy)}},
		msg.Content.ContentBlocks...,
	)
}

func injectResponses(input *[]schemas.ResponsesMessage) {
	for i := range *input {
		if (*input)[i].Role != nil && *(*input)[i].Role == schemas.ResponsesInputMessageRoleUser {
			prependResponsesContent(&(*input)[i])
			return
		}
	}
	msgType := schemas.ResponsesMessageTypeMessage
	role := schemas.ResponsesInputMessageRoleUser
	msg := schemas.ResponsesMessage{
		Type:    &msgType,
		Role:    &role,
		Content: &schemas.ResponsesMessageContent{ContentStr: ptr(policy)},
	}
	*input = append([]schemas.ResponsesMessage{msg}, *input...)
}

func prependResponsesContent(msg *schemas.ResponsesMessage) {
	if msg.Content == nil {
		msg.Content = &schemas.ResponsesMessageContent{ContentStr: ptr(policy)}
		return
	}
	if msg.Content.ContentStr != nil {
		merged := policy + "\n\n" + *msg.Content.ContentStr
		msg.Content.ContentStr = &merged
		return
	}
	msg.Content.ContentBlocks = append(
		[]schemas.ResponsesMessageContentBlock{{Type: schemas.ResponsesInputMessageContentBlockTypeText, Text: ptr(policy)}},
		msg.Content.ContentBlocks...,
	)
}

func ptr(s string) *string { return &s }
