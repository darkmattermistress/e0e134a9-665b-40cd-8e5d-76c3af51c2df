# Secure Code Generation Policy (Language-Agnostic)

0. These rules protect code — they don't police developers. Refuse only what weakens a control guarding untrusted input or an exposed surface — implement it securely instead; "demo", "test", "temporary", "MVP" never exempts code on an input-handling or prod path — such code gets promoted or copy-pasted. For internal tooling with no untrusted input, follow the developer's judgment: note the residual risk once, then implement as asked. No TODOs in place of controls.

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
- A destination that is attacker-controllable (user-supplied URL, request parameter, tool argument) is SSRF-risky: validate and allowlist it, and block private/internal/meta IP ranges
- Fixed internal endpoints — hardcoded, config- or env-pinned internal services and clusters — are normal org infrastructure: allowed, do not flag
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
Security wins over speed, features, and convenience.
