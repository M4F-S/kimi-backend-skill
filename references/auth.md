# Authentication & Authorization Reference

A production-ready guide to auth patterns, protocols, and secure implementation for backend systems. Covers authentication methods, authorization models, session management, and code-level security controls.

---

## Table of Contents

- [Auth Methods Comparison](#auth-methods-comparison)
- [JWT Best Practices](#jwt-best-practices)
- [OAuth 2.1 + OIDC](#oauth-21--oidc)
- [RBAC (Role-Based Access Control)](#rbac-role-based-access-control)
- [ABAC (Attribute-Based Access Control)](#abac-attribute-based-access-control)
- [Scope-Based Access Control](#scope-based-access-control)
- [BOLA Prevention (Broken Object Level Authorization)](#bola-prevention-broken-object-level-authorization)
- [Session Management](#session-management)
- [Password Security](#password-security)
- [MFA / 2FA](#mfa--2fa)
- [Code Snippets](#code-snippets)

---

## Auth Methods Comparison

| Method | Security Level | Best For | Key Characteristics |
|--------|-------------|----------|-------------------|
| **API Keys** | Low | Server-to-server, internal services, simple integrations | Static secret, easy to implement, no user context. Rotate regularly. Use header or query param (header preferred). |
| **JWT Bearer** | Medium–High | User-facing APIs, stateless auth, microservices | Self-contained claims, short-lived, signed. No server-side session store needed. Scales well horizontally. |
| **OAuth 2.1 + OIDC** | High | Third-party apps, SSO, social login, delegated access | Standardized flows, PKCE for public clients, scope-based access, identity layer via OIDC. External IdP support. |
| **mTLS** | Very High | Internal service-to-service, zero-trust, high-sensitivity environments | Certificate-based mutual auth. No bearer tokens. Strong identity tied to X.509 certs. Adds TLS overhead. |

### Choosing an Auth Method

```
Internal microservice → API Keys or mTLS
User API (mobile/web) → JWT Bearer or OAuth 2.1 + OIDC
Third-party integration → OAuth 2.1 + OIDC
Admin/internal tools → API Keys or JWT with strict claims
High-security finance/health → mTLS + OAuth 2.1 + OIDC
```

---

## JWT Best Practices

JSON Web Tokens are widely used for stateless authentication. Poor implementation leads to security vulnerabilities.

### 1. Short-Lived Access Tokens

Access tokens should expire quickly. Set `exp` to 5–15 minutes.

```json
{
  "sub": "user-123",
  "iss": "https://api.example.com",
  "aud": "https://api.example.com",
  "iat": 1704067200,
  "exp": 1704068100,
  "scope": "read:profile write:posts"
}
```

### 2. Asymmetric Signing (RS256 / ES256)

Use asymmetric algorithms so the verification key (public) can be distributed without exposing the signing key (private).

- **RS256**: RSA + SHA-256. Mature, widely supported.
- **ES256**: ECDSA + SHA-256. Smaller signatures, faster verification.
- **Never use**: `none`, `HS256` with a shared secret in distributed systems (secret rotation is hard), `RS384`/`RS512` without clear need.

### 3. Validate Claims Rigorously

Every token verification must check:

| Claim | Validation |
|-------|-----------|
| `iss` (issuer) | Must match expected issuer (e.g., `https://api.example.com`) |
| `aud` (audience) | Must match your service identifier |
| `exp` (expiration) | Must be in the future; reject expired tokens |
| `sub` (subject) | Must be a valid, non-empty user/service identifier |
| `iat` (issued at) | Optional: reject tokens issued too far in the future (clock skew) |
| `jti` (JWT ID) | Optional: used for blacklisting / one-time tokens |
| `scope` | Optional: used for scope-based access control |

### 4. Never Store JWTs in localStorage

| Storage | Risk | Recommendation |
|---------|------|---------------|
| `localStorage` | XSS attack → token stolen | **Never use** for JWTs |
| `sessionStorage` | XSS attack → token stolen for session duration | Avoid for sensitive tokens |
| `HttpOnly` cookie | XSS cannot read via JS; CSRF risk remains | **Preferred** with `Secure` + `SameSite=Strict` |
| `HttpOnly` + `Secure` + `SameSite=Strict` | Strongest client-side protection | Use for web apps |

Cookie attributes:
```
Set-Cookie: access_token=eyJhbG...; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=900
```

### 5. Refresh Token Rotation with Single-Use Tokens

When a refresh token is used to get a new access token, issue a **new** refresh token and invalidate the old one. This prevents replay attacks if a refresh token is stolen.

```
[Client] --refresh_token--> [Server] → verify, invalidate old, issue new pair
```

Store refresh tokens server-side (in a database or Redis) with metadata: user ID, issued at, device fingerprint, IP.

### 6. JWT Blacklisting for Logout

Since JWTs are stateless, you cannot "revoke" them directly. Solutions:

1. **Short-lived tokens** (5–15 min) — token is only valid briefly after logout.
2. **Blacklist / blocklist** — store `jti` + `exp` in a denylist (Redis) and check on every request. Evict when `exp` is reached.
3. **Versioned tokens** — include a `token_version` claim. On logout, increment user's version in DB. Reject tokens with outdated version.

Blacklist check (Redis pattern):
```
SET blacklist:jti:{token_jti} 1 EX {seconds_until_exp}
```

---

## OAuth 2.1 + OIDC

OAuth 2.1 is the latest authorization framework. OIDC (OpenID Connect) is an identity layer on top of OAuth 2.0.

### Authorization Code Flow with PKCE

PKCE (Proof Key for Code Exchange) is **required** for all clients, including confidential ones. Prevents authorization code interception attacks.

**Flow Steps:**

```
1. Client generates code_verifier (random string, 43-128 chars)
2. Client computes code_challenge = BASE64URL(SHA256(code_verifier))
3. Client redirects user to /authorize with code_challenge and method=S256
4. User authenticates and consents
5. IdP redirects back with authorization code
6. Client exchanges code for tokens at /token, sending code_verifier
7. IdP verifies code_challenge against code_verifier
```

### State Parameter for CSRF Protection

Always include a `state` parameter in the authorization request. It must be:
- Cryptographically random (≥ 128 bits)
- Stored in the user's session (server-side or cookie)
- Verified on the callback redirect

```
Redirect: /authorize?client_id=xxx&response_type=code&redirect_uri=xxx&state=random_csrf_token&scope=openid profile&code_challenge=xxx&code_challenge_method=S256

Callback: /callback?code=abc&state=random_csrf_token
→ Verify state matches session value
```

### Scope Definitions

Define granular, consistent scopes. Prefix by resource type.

| Scope | Access |
|-------|--------|
| `openid` | OIDC: request ID token |
| `profile` | OIDC: name, picture, etc. |
| `email` | OIDC: email and verified status |
| `read:profile` | Read user profile data |
| `write:profile` | Update user profile data |
| `read:posts` | Read posts |
| `write:posts` | Create/update posts |
| `admin:users` | Full user administration |
| `admin:system` | System-level operations |

### Token Introspection

Use OAuth 2.0 Token Introspection (RFC 7662) to validate opaque tokens at the authorization server:

```
POST /introspect
Authorization: Basic {client_credentials}
Content-Type: application/x-www-form-urlencoded

token={access_token}
```

Response:
```json
{
  "active": true,
  "sub": "user-123",
  "scope": "read:profile write:posts",
  "client_id": "my-app",
  "exp": 1704068100
}
```

### Token Revocation

Implement OAuth 2.0 Token Revocation (RFC 7009) to allow clients to revoke tokens:

```
POST /revoke
Authorization: Basic {client_credentials}
Content-Type: application/x-www-form-urlencoded

token={token_to_revoke}&token_type_hint=refresh_token
```

---

## RBAC (Role-Based Access Control)

RBAC assigns permissions to roles, and roles to users. Simple, effective, widely adopted.

### Role Hierarchy

```
SuperAdmin
  └── Admin
        └── Moderator
              └── User
                    └── Guest
```

Higher roles inherit permissions from lower roles.

### Permission Checks at Route Level

Apply RBAC at the middleware layer, not in route handlers.

```
Request → Authentication (who are you?) → RBAC Middleware (what can you do?) → Route Handler
```

### Role Assignment and Management

Store roles in your database:

```sql
CREATE TABLE roles (
  id SERIAL PRIMARY KEY,
  name VARCHAR(50) UNIQUE NOT NULL, -- 'admin', 'user', 'moderator'
  permissions TEXT[] NOT NULL         -- ['read:posts', 'write:posts', 'delete:posts']
);

CREATE TABLE user_roles (
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  role_id INT REFERENCES roles(id) ON DELETE CASCADE,
  assigned_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (user_id, role_id)
);
```

### RBAC Best Practices

- Define roles based on job functions, not individual users.
- Follow the principle of least privilege — assign the minimum necessary role.
- Avoid hardcoding role checks; use a permission-based lookup table.
- Log all role assignment changes for audit trails.
- Allow roles to be checked at the middleware or decorator level, not inside business logic.

---

## ABAC (Attribute-Based Access Control)

ABAC evaluates policies based on attributes of the user, resource, action, and environment. More flexible than RBAC but more complex to implement.

### Context-Aware Decisions

Example: A user can only edit a document if:
- They are the **owner** of the document (user attribute + resource attribute)
- The document is **not locked** (resource attribute)
- The request is during **business hours** (environment attribute)
- The user is **not suspended** (user attribute)

### Policy Engines

| Engine | Language | Best For |
|--------|----------|----------|
| **Casbin** | Go (multi-language bindings) | Embedded policy engine, supports RBAC, ABAC, RESTful |
| **Open Policy Agent (OPA)** | Rego | Cloud-native, Kubernetes, service mesh, centralized policy |

### Casbin Example Model

```ini
[request_definition]
r = sub, obj, act

[policy_definition]
p = sub, obj, act

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = r.sub.Age >= 18 && r.obj.Owner == r.sub.Name && r.act == 'read'
```

### Resource-Level Permissions

Unlike RBAC (which is coarse-grained), ABAC can evaluate permissions per resource:

```python
# ABAC decision: Can user-123 edit post-456?
allow if:
  user.id == post.owner_id
  and user.is_active == true
  and post.is_locked == false
  and time.hour between 9 and 18
```

### Time/IP-Based Rules

```python
# Example: Restrict admin access to office hours and office IP
environment = {
    "time": datetime.now(),
    "ip": request.client_ip,
    "user_agent": request.headers.get("User-Agent")
}

policy = {
    "allow": (
        user.role == "admin" and
        environment["time"].hour in range(9, 18) and
        ipaddress.ip_address(environment["ip"]) in OFFICE_SUBNET
    )
}
```

### When to Use ABAC vs RBAC

| Use RBAC When | Use ABAC When |
|--------------|--------------|
| Clear job roles | Complex, dynamic access rules |
| Small number of roles | Need resource-level permissions |
| Simple permission structure | Context matters (time, location, device) |
| Fast implementation needed | Multi-tenant, data-intensive apps |

---

## Scope-Based Access Control

Scopes are permissions granted by the user or system to a client. Most common in OAuth 2.0 but applicable to any token-based system.

### OAuth Scopes

```
Scope is a space-delimited string in the token:
"read:profile write:posts admin:users"
```

### Endpoint-Level Scope Enforcement

Protect endpoints by requiring specific scopes:

```
GET /api/users → requires scope: read:users or admin:users
POST /api/posts → requires scope: write:posts or admin:posts
DELETE /api/users/{id} → requires scope: admin:users
```

### Third-Party App Permissions

When third-party apps request access, present the user with a clear consent screen:

```
App "MyCalendar" wants to access:
  ✓ Read your profile
  ✓ Read your calendar events
  ✗ Write to your calendar (unchecked by default)
  ✗ Delete your account (not requested)
```

Store granted scopes per app-user pair:

```sql
CREATE TABLE oauth_grants (
  client_id VARCHAR(255) NOT NULL,
  user_id UUID NOT NULL,
  scope TEXT[] NOT NULL,
  granted_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ,
  PRIMARY KEY (client_id, user_id)
);
```

---

## BOLA Prevention (Broken Object Level Authorization)

BOLA is the **#1 API security risk** (OWASP API Top 10 2023). It occurs when an API allows access to resources by ID without verifying the user owns that resource.

### The Vulnerable Pattern

```javascript
// ============================================
// ❌ VULNERABLE — Any authenticated user can access any resource
// ============================================
// GET /api/invoices/:id
app.get('/api/invoices/:id', authenticate, async (req, res) => {
  const invoice = await db.invoices.findById(req.params.id);
  // NO ownership check!
  res.json(invoice);
});
```

```python
# ============================================
# ❌ VULNERABLE — Same issue in Python/Flask
# ============================================
@app.route('/api/documents/<int:doc_id>')
@require_auth
def get_document(doc_id):
    doc = Document.query.get(doc_id)
    # Missing: check if current_user.id == doc.owner_id
    return jsonify(doc.to_dict())
```

### The Secure Pattern

```javascript
// ============================================
// ✅ SECURE — Verify ownership on every access
// ============================================
app.get('/api/invoices/:id', authenticate, async (req, res) => {
  const userId = req.user.sub; // from JWT after authentication
  
  const invoice = await db.invoices.findOne({
    id: req.params.id,
    owner_id: userId  // CRITICAL: enforce ownership
  });
  
  if (!invoice) {
    // Return 404 (not 403) to avoid leaking existence of other users' resources
    return res.status(404).json({ error: 'Invoice not found' });
  }
  
  res.json(invoice);
});
```

```python
# ============================================
# ✅ SECURE — Python/Flask with ownership check
# ============================================
@app.route('/api/documents/<int:doc_id>')
@require_auth
def get_document(doc_id):
    doc = Document.query.filter_by(
        id=doc_id,
        owner_id=current_user.id  # Enforce ownership
    ).first()
    
    if not doc:
        abort(404)  # Don't reveal the document exists
    
    return jsonify(doc.to_dict())
```

### BOLA Prevention Pattern for All Resource Types

Apply this pattern to **every** endpoint that accesses a resource by ID:

```javascript
// Generic ownership verification middleware (Node.js/Express)
function requireOwnership({ model, ownerField = 'user_id' }) {
  return async (req, res, next) => {
    const resourceId = req.params.id;
    const userId = req.user.sub;
    
    const resource = await model.findOne({
      id: resourceId,
      [ownerField]: userId
    });
    
    if (!resource) {
      return res.status(404).json({ error: 'Resource not found' });
    }
    
    req.resource = resource; // Attach to request for downstream use
    next();
  };
}

// Usage:
app.get('/api/orders/:id', authenticate, requireOwnership({ model: db.orders }), async (req, res) => {
  res.json(req.resource);
});
```

### BOLA Prevention Checklist

- [ ] Every resource endpoint includes the owner/user ID in the query
- [ ] No resource is returned based solely on the ID parameter
- [ ] Return 404 (not 403) for unauthorized access to prevent resource enumeration
- [ ] Apply the same check to `GET`, `PUT`, `PATCH`, `DELETE`, and nested resources
- [ ] Consider using a centralized policy/authorization service (e.g., OPA) for complex apps
- [ ] Audit all routes for this vulnerability during code review

---

## Session Management

### Stateless (JWT) vs Stateful (Session Store + Cookie)

| Aspect | Stateless JWT | Stateful Session Store + Cookie |
|--------|-------------|--------------------------------|
| **Server-side storage** | None | Session data in Redis/DB |
| **Scalability** | Excellent (no shared state) | Good (requires shared session store) |
| **Revocation** | Difficult (need blacklist) | Easy (delete from store) |
| **Payload size** | Token carries all claims | Minimal cookie (session ID only) |
| **Security** | Good (short-lived, signed) | Strong (server controls session) |
| **Use case** | APIs, mobile, SPAs | Web apps, server-rendered apps |

### Session Fixation Prevention

Regenerate session ID after authentication (login) to prevent session fixation attacks:

```javascript
// After successful login, regenerate session ID
req.session.regenerate((err) => {
  if (err) return next(err);
  req.session.userId = user.id;
  req.session.save((err) => {
    if (err) return next(err);
    res.redirect('/dashboard');
  });
});
```

```python
# Flask: session is automatically managed, but ensure you use a secure session store
from flask import session
from flask.sessions import SecureCookieSessionInterface

# After login, clear and set new session data
session.clear()
session['user_id'] = user.id
session.permanent = True  # Enable session timeout
```

### Session Timeout

```javascript
// Redis TTL-based session expiry
const SESSION_TTL = 30 * 60; // 30 minutes in seconds

await redis.setex(`session:${sessionId}`, SESSION_TTL, JSON.stringify(sessionData));
```

```python
# Python with Redis
redis_client.setex(f"session:{session_id}", 1800, json.dumps(session_data))  # 30 min
```

Implement idle timeout and absolute timeout:
- **Idle timeout**: Expire after X minutes of inactivity (30 min typical).
- **Absolute timeout**: Expire after X hours regardless of activity (8–24 hours typical).

### Concurrent Session Limits

Restrict the number of active sessions per user:

```javascript
// Store user sessions in a Redis set
const userSessionsKey = `user_sessions:${userId}`;
await redis.sadd(userSessionsKey, sessionId);
await redis.expire(userSessionsKey, 24 * 60 * 60);

// Limit to 3 concurrent sessions
const sessionCount = await redis.scard(userSessionsKey);
if (sessionCount > 3) {
  const oldest = await redis.spop(userSessionsKey, sessionCount - 3);
  for (const oldSessionId of oldest) {
    await redis.del(`session:${oldSessionId}`);
  }
}
```

### Device Fingerprinting

Store device metadata to detect suspicious sessions:

```javascript
const fingerprint = {
  userAgent: req.headers['user-agent'],
  ip: req.ip,
  // Optionally hash a subset of UA + IP (avoid full PII)
};

const sessionData = {
  userId: user.id,
  fingerprint,
  createdAt: Date.now()
};
```

Warn or block when a session's fingerprint changes significantly.

---

## Password Security

### Hashing Algorithms

| Algorithm | Recommendation | Notes |
|-----------|---------------|-------|
| **bcrypt** | Acceptable (cost factor 12+) | Battle-tested, widely available. Default choice for most systems. |
| **Argon2id** | **Preferred** for new systems | Memory-hard, resistant to GPU/ASIC attacks. Winner of Password Hashing Competition. |
| **scrypt** | Acceptable | Memory-hard, good for crypto but Argon2id is preferred. |
| **PBKDF2** | Legacy only | Still required by some compliance (NIST), but not preferred. |
| **MD5 / SHA-1 / SHA-256** | **Never** | Not designed for password hashing. Fast = brute-forceable. |

### bcrypt Configuration

Use cost factor 12 or higher. Higher = slower but more secure.

```javascript
const bcrypt = require('bcrypt');
const SALT_ROUNDS = 12; // ~250ms per hash on modern hardware

const hashPassword = async (password) => {
  return bcrypt.hash(password, SALT_ROUNDS);
};

const verifyPassword = async (password, hash) => {
  return bcrypt.compare(password, hash);
};
```

### Argon2id Configuration

```javascript
const argon2 = require('argon2');

const hashPassword = async (password) => {
  return argon2.hash(password, {
    type: argon2.argon2id,
    memoryCost: 65536,    // 64 MB
    timeCost: 3,           // 3 iterations
    parallelism: 4         // 4 parallel threads
  });
};
```

```python
import argon2

ph = argon2.PasswordHasher(
    memory_cost=65536,  # 64 MB
    time_cost=3,        # 3 iterations
    parallelism=4,      # 4 threads
    hash_len=32,
    salt_len=16
)

hash = ph.hash(password)
ph.verify(hash, password)
```

### Password Strength Requirements

Enforce a reasonable password policy without being overly restrictive:

- Minimum 12 characters (16+ for admin accounts)
- Check against common passwords (top 10,000 list)
- Check against breached passwords (HaveIBeenPwned API)
- No maximum length that prevents passphrases (allow 128+ chars)
- Allow all Unicode characters (don't restrict special characters)
- Provide a strength meter (zxcvbn library)

### Breach Detection (HaveIBeenPwned API)

Use the k-Anonymity API to check if a password has been breached without sending the full password:

```javascript
const crypto = require('crypto');
const axios = require('axios');

async function isPasswordBreached(password) {
  const sha1 = crypto.createHash('sha1').update(password).digest('hex').toUpperCase();
  const prefix = sha1.substring(0, 5);
  const suffix = sha1.substring(5);
  
  const response = await axios.get(`https://api.pwnedpasswords.com/range/${prefix}`);
  const breachedSuffixes = response.data.split('\n').map(line => line.split(':')[0]);
  
  return breachedSuffixes.includes(suffix);
}
```

### Rate Limiting on Login Attempts

Prevent brute-force and credential stuffing attacks:

```javascript
const rateLimit = require('express-rate-limit');

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 5, // 5 attempts per window
  message: { error: 'Too many login attempts. Try again later.' },
  standardHeaders: true,
  legacyHeaders: false,
  // Key by IP + username to prevent distributed attacks on same account
  keyGenerator: (req) => `${req.ip}:${req.body.username}`
});

app.post('/api/login', loginLimiter, async (req, res) => { ... });
```

---

## MFA / 2FA

### TOTP Implementation (Time-based One-Time Password)

TOTP is the standard for app-based 2FA (Google Authenticator, Authy, etc.).

**Enrollment Flow:**

```
1. User requests to enable 2FA
2. Server generates a secret (base32-encoded)
3. Server shows QR code containing: otpauth://totp/{issuer}:{user}?secret={secret}&issuer={issuer}
4. User scans QR code with authenticator app
5. User enters a TOTP code to verify setup
6. Server verifies code and enables 2FA for the user
7. Server shows backup codes (single-use)
```

**Verification:**

```javascript
const speakeasy = require('speakeasy');

// Verify a TOTP code
const verified = speakeasy.totp.verify({
  secret: user.totpSecret,  // base32 encoded
  encoding: 'base32',
  token: req.body.code,      // 6-digit code from user
  window: 1                  // Allow 1 step before/after for clock skew
});
```

```python
import pyotp

totp = pyotp.TOTP(user.totp_secret)
if totp.verify(code, valid_window=1):
    # Code is valid
```

### Backup Codes

Generate 8–10 single-use backup codes during 2FA enrollment:

```javascript
const crypto = require('crypto');

function generateBackupCodes(count = 10) {
  const codes = [];
  for (let i = 0; i < count; i++) {
    // 8 characters, alphanumeric, uppercase
    codes.push(crypto.randomBytes(4).toString('hex').toUpperCase());
  }
  return codes;
}

// Store hashed versions in DB, show plain text once
```

### WebAuthn / FIDO2 Basics

WebAuthn enables passwordless or second-factor authentication using hardware keys, biometrics, or platform authenticators.

**Key Concepts:**
- **Relying Party (RP)**: Your web application (identified by `rp.id`).
- **Authenticator**: The device generating credentials (YubiKey, Touch ID, etc.).
- **Credential**: A public key credential bound to a user and an authenticator.
- **Registration**: Create a new credential.
- **Authentication**: Use an existing credential to authenticate.

**Registration Flow:**
```
1. Server generates challenge (random bytes, 32+ bytes)
2. Client calls navigator.credentials.create() with challenge, rp, user info
3. Authenticator generates key pair, returns public key credential
4. Server stores public key credential ID + public key for user
```

**Authentication Flow:**
```
1. Server generates challenge
2. Client calls navigator.credentials.get() with challenge and allowed credentials
3. Authenticator signs the challenge
4. Server verifies signature with stored public key
```

Use libraries like `simplewebauthn` (Node.js) or `py_webauthn` (Python) to handle the cryptographic details.

### MFA Enrollment Flow (Complete)

```
[User] → POST /api/mfa/enroll
[Server] → Generate TOTP secret, store in DB (not yet enabled)
[Server] → Return QR code URI
[User] → Scan QR code, enter code from authenticator app
[User] → POST /api/mfa/verify { code: "123456" }
[Server] → Verify TOTP code against stored secret
[Server] → Enable 2FA, generate and return backup codes
[User] → Store backup codes securely
```

---

## Code Snippets

### 1. JWT Generation + Verification (Node.js with `jsonwebtoken`)

```typescript
import jwt from 'jsonwebtoken';
import { readFileSync } from 'fs';

// Load keys (in production, use a key management service or secure vault)
const privateKey = readFileSync('./keys/private.pem');
const publicKey = readFileSync('./keys/public.pem');

const JWT_CONFIG = {
  issuer: 'https://api.example.com',
  audience: 'https://api.example.com',
  accessTokenExpiry: '15m',
  refreshTokenExpiry: '7d',
  algorithm: 'RS256' as const
};

interface TokenPayload {
  sub: string;      // user ID
  scope: string;    // space-delimited scopes
  jti?: string;     // optional: for blacklisting
}

export function generateAccessToken(payload: TokenPayload): string {
  return jwt.sign(payload, privateKey, {
    algorithm: JWT_CONFIG.algorithm,
    issuer: JWT_CONFIG.issuer,
    audience: JWT_CONFIG.audience,
    expiresIn: JWT_CONFIG.accessTokenExpiry,
    jwtid: payload.jti || crypto.randomUUID()
  });
}

export function generateRefreshToken(userId: string): string {
  return jwt.sign({ sub: userId, type: 'refresh' }, privateKey, {
    algorithm: JWT_CONFIG.algorithm,
    issuer: JWT_CONFIG.issuer,
    audience: JWT_CONFIG.audience,
    expiresIn: JWT_CONFIG.refreshTokenExpiry,
    jwtid: crypto.randomUUID()
  });
}

export function verifyAccessToken(token: string): TokenPayload {
  return jwt.verify(token, publicKey, {
    algorithms: [JWT_CONFIG.algorithm],
    issuer: JWT_CONFIG.issuer,
    audience: JWT_CONFIG.audience,
    complete: false
  }) as TokenPayload;
}
```

### 2. JWT Middleware (Express + TypeScript)

```typescript
import { Request, Response, NextFunction } from 'express';
import { verifyAccessToken } from './jwt';

// Extend Express Request type
declare global {
  namespace Express {
    interface Request {
      user?: { sub: string; scope: string; jti: string };
    }
  }
}

export function authenticate(req: Request, res: Response, next: NextFunction): void {
  const authHeader = req.headers.authorization;
  
  if (!authHeader?.startsWith('Bearer ')) {
    res.status(401).json({ error: 'Missing or invalid authorization header' });
    return;
  }
  
  const token = authHeader.substring(7);
  
  try {
    const payload = verifyAccessToken(token);
    req.user = payload;
    next();
  } catch (err) {
    if (err instanceof jwt.TokenExpiredError) {
      res.status(401).json({ error: 'Token expired', code: 'TOKEN_EXPIRED' });
    } else if (err instanceof jwt.JsonWebTokenError) {
      res.status(401).json({ error: 'Invalid token' });
    } else {
      res.status(500).json({ error: 'Token verification failed' });
    }
  }
}

// Optional: JWT blacklist check middleware
export function checkBlacklist(redis: RedisClient) {
  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    if (!req.user?.jti) return next();
    
    const isBlacklisted = await redis.exists(`blacklist:${req.user.jti}`);
    if (isBlacklisted) {
      res.status(401).json({ error: 'Token revoked' });
      return;
    }
    next();
  };
}
```

### 3. OAuth 2.1 Authorization Code Flow (Node.js)

```typescript
import crypto from 'crypto';
import { Request, Response } from 'express';

// PKCE: Generate code verifier and challenge
function generatePKCE() {
  const codeVerifier = crypto.randomBytes(32).toString('base64url');
  const codeChallenge = crypto
    .createHash('sha256')
    .update(codeVerifier)
    .digest('base64url');
  
  return { codeVerifier, codeChallenge, codeChallengeMethod: 'S256' };
}

// Step 1: Build authorization URL (client-side or server-side)
function buildAuthorizationUrl(): { url: string; state: string; codeVerifier: string } {
  const { codeVerifier, codeChallenge } = generatePKCE();
  const state = crypto.randomBytes(32).toString('hex');
  
  const params = new URLSearchParams({
    client_id: process.env.OAUTH_CLIENT_ID!,
    response_type: 'code',
    redirect_uri: 'https://app.example.com/callback',
    scope: 'openid profile email',
    state,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256'
  });
  
  return {
    url: `https://idp.example.com/oauth/authorize?${params.toString()}`,
    state,
    codeVerifier
  };
}

// Step 2: Exchange authorization code for tokens
async function exchangeCodeForTokens(code: string, codeVerifier: string): Promise<TokenResponse> {
  const response = await fetch('https://idp.example.com/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: process.env.OAUTH_CLIENT_ID!,
      client_secret: process.env.OAUTH_CLIENT_SECRET!,
      code,
      redirect_uri: 'https://app.example.com/callback',
      code_verifier: codeVerifier
    })
  });
  
  if (!response.ok) {
    throw new Error(`Token exchange failed: ${response.status}`);
  }
  
  return response.json() as Promise<TokenResponse>;
}

// Step 3: Handle callback (server route)
app.get('/callback', async (req: Request, res: Response) => {
  const { code, state } = req.query as { code: string; state: string };
  
  // Verify state parameter
  const storedState = req.session?.oauthState;
  if (!storedState || storedState !== state) {
    return res.status(400).json({ error: 'Invalid state parameter' });
  }
  
  // Clear stored state (single-use)
  delete req.session.oauthState;
  
  const codeVerifier = req.session.codeVerifier;
  if (!codeVerifier) {
    return res.status(400).json({ error: 'PKCE verifier not found' });
  }
  delete req.session.codeVerifier;
  
  try {
    const tokens = await exchangeCodeForTokens(code, codeVerifier);
    // Store tokens securely (HttpOnly cookie or server-side session)
    res.cookie('access_token', tokens.access_token, { httpOnly: true, secure: true, sameSite: 'strict', maxAge: 900000 });
    res.redirect('/dashboard');
  } catch (err) {
    res.status(400).json({ error: 'Authentication failed' });
  }
});
```

### 4. RBAC Middleware (Express + TypeScript)

```typescript
import { Request, Response, NextFunction } from 'express';

// Role definitions with permissions
const ROLE_PERMISSIONS: Record<string, string[]> = {
  guest: ['read:public'],
  user: ['read:public', 'read:profile', 'write:posts'],
  moderator: ['read:public', 'read:profile', 'write:posts', 'delete:posts', 'moderate:content'],
  admin: ['read:public', 'read:profile', 'write:posts', 'delete:posts', 'moderate:content', 'admin:users', 'admin:system']
};

// Fetch user roles from DB (mocked here)
async function getUserRoles(userId: string): Promise<string[]> {
  // const result = await db.query('SELECT role FROM user_roles WHERE user_id = $1', [userId]);
  // return result.rows.map(r => r.role);
  return ['user']; // Mock
}

function hasPermission(userRoles: string[], requiredPermission: string): boolean {
  const allPermissions = userRoles.flatMap(role => ROLE_PERMISSIONS[role] || []);
  const uniquePermissions = [...new Set(allPermissions)];
  return uniquePermissions.includes(requiredPermission) || uniquePermissions.includes('admin:system');
}

export function requirePermission(permission: string) {
  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    if (!req.user) {
      res.status(401).json({ error: 'Authentication required' });
      return;
    }
    
    const roles = await getUserRoles(req.user.sub);
    
    if (!hasPermission(roles, permission)) {
      res.status(403).json({ error: 'Insufficient permissions' });
      return;
    }
    
    next();
  };
}

// Usage:
// app.get('/api/admin/users', authenticate, requirePermission('admin:users'), getUsersHandler);
// app.delete('/api/posts/:id', authenticate, requirePermission('delete:posts'), deletePostHandler);
```

### 5. BOLA Prevention Pattern (Node.js + TypeScript)

```typescript
import { Request, Response, NextFunction } from 'express';

/**
 * Generic resource ownership middleware.
 * Prevents BOLA by enforcing that the authenticated user owns the resource.
 */
interface OwnableModel {
  findByIdAndOwner(id: string, ownerId: string): Promise<any | null>;
}

export function requireOwnership(
  model: OwnableModel,
  options: { paramName?: string; ownerField?: string } = {}
) {
  const { paramName = 'id' } = options;
  
  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    if (!req.user) {
      res.status(401).json({ error: 'Authentication required' });
      return;
    }
    
    const resourceId = req.params[paramName];
    const userId = req.user.sub;
    
    const resource = await model.findByIdAndOwner(resourceId, userId);
    
    if (!resource) {
      // Return 404 to prevent resource enumeration
      res.status(404).json({ error: 'Resource not found' });
      return;
    }
    
    // Attach resource to request for downstream handlers
    (req as any).resource = resource;
    next();
  };
}

// Example model implementation
class InvoiceModel {
  async findByIdAndOwner(id: string, ownerId: string) {
    return db.invoices.findOne({ id, owner_id: ownerId });
  }
}

// Usage:
// app.get('/api/invoices/:id', authenticate, requireOwnership(new InvoiceModel()), getInvoiceHandler);
// app.put('/api/invoices/:id', authenticate, requireOwnership(new InvoiceModel()), updateInvoiceHandler);
// app.delete('/api/invoices/:id', authenticate, requireOwnership(new InvoiceModel()), deleteInvoiceHandler);
```

### 6. Refresh Token Rotation (Node.js + Redis)

```typescript
import { Redis } from 'ioredis';
import { generateAccessToken, generateRefreshToken } from './jwt';

const redis = new Redis();

interface RefreshTokenData {
  userId: string;
  deviceFingerprint: string;
  createdAt: number;
}

export async function createTokenPair(userId: string, deviceFingerprint: string) {
  const accessToken = generateAccessToken({ sub: userId, scope: 'read:profile write:posts' });
  const refreshToken = generateRefreshToken(userId);
  
  const refreshData: RefreshTokenData = {
    userId,
    deviceFingerprint,
    createdAt: Date.now()
  };
  
  // Store refresh token metadata (TTL = 7 days)
  await redis.setex(`refresh:${refreshToken}`, 7 * 24 * 60 * 60, JSON.stringify(refreshData));
  
  return { accessToken, refreshToken };
}

export async function rotateRefreshToken(oldRefreshToken: string, deviceFingerprint: string) {
  const stored = await redis.get(`refresh:${oldRefreshToken}`);
  
  if (!stored) {
    throw new Error('Invalid or expired refresh token');
  }
  
  const data: RefreshTokenData = JSON.parse(stored);
  
  // Optional: verify device fingerprint
  if (data.deviceFingerprint !== deviceFingerprint) {
    // Log potential token theft
    console.warn('Refresh token used from different device', { userId: data.userId });
    // Optionally revoke all tokens for this user
  }
  
  // Invalidate old refresh token (single-use)
  await redis.del(`refresh:${oldRefreshToken}`);
  
  // Generate new token pair
  return createTokenPair(data.userId, deviceFingerprint);
}

// Express route for token refresh
app.post('/api/auth/refresh', async (req, res) => {
  const { refreshToken } = req.body;
  const deviceFingerprint = req.headers['x-device-fingerprint'] as string || 'unknown';
  
  try {
    const tokens = await rotateRefreshToken(refreshToken, deviceFingerprint);
    res.json(tokens);
  } catch (err) {
    res.status(401).json({ error: 'Invalid refresh token' });
  }
});
```

### 7. Password Hashing with bcrypt (Node.js + TypeScript)

```typescript
import bcrypt from 'bcrypt';

const SALT_ROUNDS = 12; // ~250ms per hash on modern hardware
const MAX_PASSWORD_LENGTH = 128;

export class PasswordService {
  /**
   * Hash a password using bcrypt
   */
  static async hash(password: string): Promise<string> {
    // Prevent DoS via extremely long passwords
    if (password.length > MAX_PASSWORD_LENGTH) {
      throw new Error('Password too long');
    }
    
    return bcrypt.hash(password, SALT_ROUNDS);
  }
  
  /**
   * Verify a password against a stored hash
   */
  static async verify(password: string, hash: string): Promise<boolean> {
    if (password.length > MAX_PASSWORD_LENGTH) {
      return false; // Prevent timing attacks on length
    }
    
    return bcrypt.compare(password, hash);
  }
  
  /**
   * Check password strength (basic rules)
   */
  static checkStrength(password: string): { valid: boolean; errors: string[] } {
    const errors: string[] = [];
    
    if (password.length < 12) {
      errors.push('Password must be at least 12 characters');
    }
    if (!/[A-Z]/.test(password)) {
      errors.push('Password must contain an uppercase letter');
    }
    if (!/[a-z]/.test(password)) {
      errors.push('Password must contain a lowercase letter');
    }
    if (!/[0-9]/.test(password)) {
      errors.push('Password must contain a number');
    }
    if (!/[^A-Za-z0-9]/.test(password)) {
      errors.push('Password must contain a special character');
    }
    
    return { valid: errors.length === 0, errors };
  }
  
  /**
   * Check if password is in breached database using HIBP k-Anonymity API
   */
  static async isBreached(password: string): Promise<boolean> {
    const crypto = await import('crypto');
    const sha1 = crypto.createHash('sha1').update(password).digest('hex').toUpperCase();
    const prefix = sha1.substring(0, 5);
    const suffix = sha1.substring(5);
    
    const response = await fetch(`https://api.pwnedpasswords.com/range/${prefix}`);
    if (!response.ok) throw new Error('HIBP API error');
    
    const text = await response.text();
    const breachedSuffixes = text.split('\n').map(line => line.split(':')[0]);
    
    return breachedSuffixes.includes(suffix);
  }
}

// Usage in registration:
app.post('/api/register', async (req, res) => {
  const { password } = req.body;
  
  const strength = PasswordService.checkStrength(password);
  if (!strength.valid) {
    return res.status(400).json({ error: 'Weak password', details: strength.errors });
  }
  
  const isBreached = await PasswordService.isBreached(password);
  if (isBreached) {
    return res.status(400).json({ error: 'Password has been found in a data breach' });
  }
  
  const passwordHash = await PasswordService.hash(password);
  // Store passwordHash in database
});
```

### 8. Session Store with Redis (Node.js + Express + TypeScript)

```typescript
import express from 'express';
import session from 'express-session';
import RedisStore from 'connect-redis';
import { createClient } from 'redis';

const redisClient = createClient({ url: process.env.REDIS_URL });
redisClient.connect().catch(console.error);

const app = express();

// Configure session store with Redis
app.use(session({
  store: new RedisStore({
    client: redisClient as any,
    prefix: 'session:',
    ttl: 30 * 60 // 30 minutes (seconds)
  }),
  secret: process.env.SESSION_SECRET!, // 32+ random characters
  name: 'sessionId', // Don't use default 'connect.sid' (information leakage)
  resave: false, // Don't save session if unmodified
  saveUninitialized: false, // Don't create session until something is stored
  cookie: {
    httpOnly: true,      // Prevent XSS access
    secure: true,         // HTTPS only
    sameSite: 'strict',   // CSRF protection
    maxAge: 30 * 60 * 1000, // 30 minutes (milliseconds)
    domain: '.example.com' // Optional: share across subdomains
  },
  genid: (req) => {
    // Generate cryptographically secure session IDs
    return require('crypto').randomBytes(32).toString('hex');
  }
}));

// Session fixation prevention: regenerate ID after login
app.post('/api/login', async (req, res, next) => {
  const { username, password } = req.body;
  
  const user = await authenticateUser(username, password);
  if (!user) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  
  // Prevent session fixation by regenerating session ID
  req.session.regenerate((err) => {
    if (err) return next(err);
    
    // Store minimal user data in session
    req.session.userId = user.id;
    req.session.loginAt = Date.now();
    req.session.ip = req.ip;
    req.session.userAgent = req.headers['user-agent'];
    
    req.session.save((err) => {
      if (err) return next(err);
      res.json({ success: true });
    });
  });
});

// Logout: destroy session and clear cookie
app.post('/api/logout', (req, res) => {
  req.session.destroy((err) => {
    if (err) {
      return res.status(500).json({ error: 'Logout failed' });
    }
    res.clearCookie('sessionId');
    res.json({ success: true });
  });
});

// Session validation middleware
export function validateSession(req: express.Request, res: express.Response, next: express.NextFunction) {
  if (!req.session.userId) {
    return res.status(401).json({ error: 'Session expired or invalid' });
  }
  
  // Optional: check IP and user agent for session hijacking
  if (req.session.ip && req.session.ip !== req.ip) {
    console.warn('Session IP mismatch', { sessionIp: req.session.ip, currentIp: req.ip });
    // Optional: force re-authentication or just log
  }
  
  next();
}
```

---

## Quick Reference: Security Checklist

| Area | Check |
|------|-------|
| **Auth Method** | Match method to sensitivity level |
| **JWT** | Short-lived (5-15 min), RS256/ES256, validate claims, no localStorage |
| **OAuth** | PKCE required, state parameter verified, proper scope enforcement |
| **RBAC** | Role-based middleware, permission checks before handlers |
| **ABAC** | Context-aware policies for fine-grained access |
| **BOLA** | Verify ownership on every resource access; return 404 on denial |
| **Session** | Regenerate ID on login, idle + absolute timeout, Redis store |
| **Password** | bcrypt 12+ or Argon2id, breach detection, strength validation |
| **MFA** | TOTP with backup codes, consider WebAuthn/FIDO2 |
| **Rate Limit** | Login endpoints limited, keyed by IP + username |

---

*Last updated: 2024. Align with OWASP API Security Top 10 and current OAuth 2.1 / JWT best practices.*
