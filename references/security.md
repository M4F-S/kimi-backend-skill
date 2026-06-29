# Security Reference

Complete security hardening guide for production backend APIs. Covers OWASP API Top 10 mapped to fixes, input validation, SQL injection prevention, rate limiting, security headers, CORS, secrets management, dependency scanning, file upload safety, XSS/CSRF protection, and security logging.

**Related files:**
- See `auth.md` for JWT/OAuth, RBAC/ABAC, BOLA prevention, session management, and refresh token rotation
- See `apis.md` for API design, error handling, and OpenAPI patterns
- See `devops.md` for Docker hardening, CI/CD security, and secrets in Kubernetes

---

## Table of Contents

1. [OWASP API Security Top 10 (2025)](#owasp-api-security-top-10-2025)
2. [Input Validation](#input-validation)
3. [SQL Injection Prevention](#sql-injection-prevention)
4. [Tiered Rate Limiting](#tiered-rate-limiting)
5. [Security Headers](#security-headers)
6. [CORS Configuration](#cors-configuration)
7. [Secrets Management](#secrets-management)
8. [Dependency Scanning](#dependency-scanning)
9. [File Upload Security](#file-upload-security)
10. [XSS & CSRF Protection](#xss--csrf-protection)
11. [Security Logging & Error Handling](#security-logging--error-handling)
12. [Quick Security Checklist](#quick-security-checklist)

---

## OWASP API Security Top 10 (2025)

| Rank | Risk | Description | Fix | Reference |
|------|------|-------------|-----|-----------|
| API1 | Broken Object Level Authorization (BOLA) | Attacker accesses/modifies another user's data by changing IDs | Verify resource ownership on every access; never trust IDs from URL/body | See `auth.md` — BOLA prevention patterns |
| API2 | Broken Authentication | Weak tokens, no expiry, brute-forceable login, missing MFA | Short-lived JWT (RS256/ES256), refresh rotation, rate-limited login, MFA | See `auth.md` — JWT & OAuth hardening |
| API3 | Broken Object Property Level Authorization | Attacker modifies fields they shouldn't (e.g., `isAdmin: true`) | Strict schema validation, explicit allowlists, DTO projection, reject unknown fields | [Input Validation](#input-validation) |
| API4 | Unrestricted Resource Consumption | No pagination, massive queries, unbounded uploads, CPU/memory exhaustion | Pagination defaults, query cost limits, request size limits, timeout guards, connection pooling | [Rate Limiting](#tiered-rate-limiting) |
| API5 | Broken Function Level Authorization | User calls admin endpoints or privileged operations | RBAC/ABAC at route/middleware level; deny by default; explicit permission checks | See `auth.md` — RBAC & ABAC patterns |
| API6 | Unrestricted Access to Sensitive Business Flows | Automated abuse of business logic (e.g., mass signups, coupon abuse, scraping) | Business flow rate limits, anomaly detection, CAPTCHA, step-up auth, device fingerprinting | [Rate Limiting](#tiered-rate-limiting) |
| API7 | Server-Side Request Forgery (SSRF) | Attacker tricks server into making requests to internal services | URL validation, allowlist domains, block private IP ranges, disable redirects | [SSRF Prevention](#ssrf-prevention) |
| API8 | Security Misconfiguration | Default credentials, exposed admin panels, verbose errors, missing patches | Automated hardening, config validation, remove defaults, dependency scanning, least privilege | [Security Headers](#security-headers), [Dependency Scanning](#dependency-scanning) |
| API9 | Improper Inventory Management | Shadow APIs, deprecated versions, undocumented endpoints, no retirement | API catalog, versioning strategy, sunset policies, automated discovery, OpenAPI docs | See `apis.md` — versioning & deprecation |
| API10 | Unsafe Consumption of APIs | Trusting third-party APIs without validation; supply chain attacks | Validate all external responses, circuit breakers, timeouts, certificate pinning | [Unsafe API Consumption](#unsafe-api-consumption) |

---

## Input Validation

**Rule:** Never trust client input. Validate at the API boundary, reject unknown fields, and use strict schemas.

### TypeScript — Zod (Strict Mode)

```typescript
import { z } from 'zod';

// ❌ BAD: loose schema, allows unknown fields
const UserSchemaLoose = z.object({
  email: z.string(),
  age: z.number(),
});

// ✅ GOOD: strict schema with transforms, constraints, and custom validators
const UserSchemaStrict = z.object({
  email: z.string().email().toLowerCase().trim().max(254),
  name: z.string().min(1).max(100).trim(),
  age: z.number().int().min(0).max(150).optional(),
  role: z.enum(['user', 'admin', 'editor']).default('user'),
  isActive: z.boolean().default(true),
  metadata: z.record(z.string()).max(10).optional(),
}).strict(); // rejects unknown keys

// Nested object validation
const AddressSchema = z.object({
  street: z.string().min(1).max(200),
  city: z.string().min(1).max(100),
  zipCode: z.string().regex(/^\d{5}(-\d{4})?$/),
  country: z.string().length(2).toUpperCase(), // ISO-3166-1 alpha-2
}).strict();

const UserWithAddressSchema = z.object({
  user: UserSchemaStrict,
  address: AddressSchema.optional(),
}).strict();

// Array validation with constraints
const TagSchema = z.string().min(1).max(30).trim();
const CreatePostSchema = z.object({
  title: z.string().min(1).max(200),
  body: z.string().min(1).max(10000),
  tags: z.array(TagSchema).max(10).default([]),
  publishedAt: z.coerce.date().optional(),
}).strict();

// Custom validator — strong password
const StrongPasswordSchema = z.string().min(12).max(128).refine(
  (val) => /[A-Z]/.test(val) && /[a-z]/.test(val) && /[0-9]/.test(val) && /[^A-Za-z0-9]/.test(val),
  { message: 'Password must contain uppercase, lowercase, digit, and special character' }
);

// Usage in Express/NestJS
app.post('/users', (req, res) => {
  const result = UserSchemaStrict.safeParse(req.body);
  if (!result.success) {
    return res.status(400).json({
      error: 'Validation failed',
      code: 'INVALID_INPUT',
      details: result.error.flatten().fieldErrors,
    });
  }
  const user = result.data; // fully typed & validated
  // ... proceed to create user
});
```

### Python — Pydantic (Strict Mode)

```python
from pydantic import BaseModel, Field, EmailStr, validator, ConfigDict
from typing import Optional, Literal
from datetime import datetime
from enum import Enum

# ❌ BAD: no constraints, allows coercion
class UserLoose(BaseModel):
    email: str
    age: int

# ✅ GOOD: strict schema with constraints, custom validators, and frozen config
class UserRole(str, Enum):
    USER = "user"
    ADMIN = "admin"
    EDITOR = "editor"

class Address(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    
    street: str = Field(..., min_length=1, max_length=200)
    city: str = Field(..., min_length=1, max_length=100)
    zip_code: str = Field(..., pattern=r"^\d{5}(-\d{4})?$")
    country: str = Field(..., min_length=2, max_length=2, pattern=r"^[A-Z]{2}$")

class UserStrict(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    
    email: EmailStr
    name: str = Field(..., min_length=1, max_length=100)
    age: Optional[int] = Field(None, ge=0, le=150)
    role: UserRole = UserRole.USER
    is_active: bool = True
    metadata: Optional[dict[str, str]] = Field(None, max_length=10)
    address: Optional[Address] = None
    
    @validator("name")
    @classmethod
    def name_must_not_be_only_whitespace(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("Name cannot be only whitespace")
        return v.strip()

class CreatePost(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    
    title: str = Field(..., min_length=1, max_length=200)
    body: str = Field(..., min_length=1, max_length=10000)
    tags: list[str] = Field(default_factory=list, max_length=10)
    published_at: Optional[datetime] = None
    
    @validator("tags", each_item=True)
    @classmethod
    def tags_must_be_valid(cls, v: str) -> str:
        v = v.strip()
        if not v or len(v) > 30:
            raise ValueError("Each tag must be 1-30 characters")
        return v

# Usage in FastAPI
from fastapi import FastAPI, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

app = FastAPI()

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request, exc):
    return JSONResponse(
        status_code=400,
        content={
            "error": "Validation failed",
            "code": "INVALID_INPUT",
            "details": exc.errors(),
        },
    )

@app.post("/users")
async def create_user(user: UserStrict):
    # user is fully validated and typed
    return {"id": create_user_in_db(user)}
```

### Validation Middleware Pattern (NestJS)

```typescript
import { PipeTransform, Injectable, BadRequestException } from '@nestjs/common';
import { ZodSchema } from 'zod';

@Injectable()
export class ZodValidationPipe implements PipeTransform {
  constructor(private schema: ZodSchema) {}
  transform(value: unknown) {
    const result = this.schema.safeParse(value);
    if (!result.success) {
      throw new BadRequestException({
        error: 'Validation failed',
        code: 'INVALID_INPUT',
        details: result.error.flatten().fieldErrors,
      });
    }
    return result.data;
  }
}

// Controller usage
@Post('users')
@UsePipes(new ZodValidationPipe(UserSchemaStrict))
createUser(@Body() user: z.infer<typeof UserSchemaStrict>) {
  return this.usersService.create(user);
}
```

---

## SQL Injection Prevention

**Rule:** Never concatenate user input into SQL. Use parameterized queries, ORM methods, or query builders.

### BAD vs GOOD: Raw SQL

```typescript
// ❌ BAD: String concatenation — vulnerable to SQL injection
app.get('/users', async (req, res) => {
  const { search } = req.query;
  const query = `SELECT * FROM users WHERE name = '${search}'`; // DANGEROUS
  const users = await db.query(query);
  res.json(users);
});

// ✅ GOOD: Parameterized query
app.get('/users', async (req, res) => {
  const { search } = req.query;
  const query = 'SELECT * FROM users WHERE name = $1';
  const users = await db.query(query, [search]); // safe: treated as literal
  res.json(users);
});
```

```python
# ❌ BAD: String formatting — vulnerable to SQL injection
def get_user_by_email_bad(email: str):
    cursor.execute(f"SELECT * FROM users WHERE email = '{email}'")
    return cursor.fetchone()

# ✅ GOOD: Parameterized query (psycopg2 / asyncpg)
def get_user_by_email_good(email: str):
    cursor.execute("SELECT * FROM users WHERE email = %s", (email,))
    return cursor.fetchone()

# ✅ GOOD: SQLAlchemy ORM — always parameterized
from sqlalchemy.orm import Session
def get_user_by_email_orm(db: Session, email: str):
    return db.query(User).filter(User.email == email).first()
```

### ORM `where` Safety

```typescript
// ❌ BAD: Prisma raw query with template literal
const users = await prisma.$queryRaw`
  SELECT * FROM users WHERE id = ${userId}
`;

// ✅ GOOD: Prisma tagged template IS safe (it auto-parameterizes)
const users = await prisma.$queryRaw`
  SELECT * FROM users WHERE id = ${userId}
`;

// ❌ BAD: Prisma with string interpolation (DON'T do this)
const unsafe = await prisma.$queryRawUnsafe(
  `SELECT * FROM users WHERE id = ${userId}`
);

// ✅ GOOD: Prisma ORM methods — fully parameterized
const user = await prisma.user.findUnique({ where: { id: userId } });
const users = await prisma.user.findMany({
  where: { email: { contains: searchTerm } },
});
```

```python
# ❌ BAD: SQLAlchemy text() without parameters
from sqlalchemy import text
def search_users_bad(search: str):
    return db.execute(text(f"SELECT * FROM users WHERE name LIKE '%{search}%'"))

# ✅ GOOD: SQLAlchemy text() with bind parameters
from sqlalchemy import text
def search_users_good(search: str):
    return db.execute(
        text("SELECT * FROM users WHERE name LIKE :pattern"),
        {"pattern": f"%{search}%"}
    )

# ✅ GOOD: SQLAlchemy ORM query builder
from sqlalchemy.orm import Session
def search_users_orm(db: Session, search: str):
    return db.query(User).filter(User.name.ilike(f"%{search}%")).all()
```

### NoSQL Injection (MongoDB)

```javascript
// ❌ BAD: Passing user input directly into MongoDB query
app.post('/login', async (req, res) => {
  const { email, password } = req.body;
  const user = await db.collection('users').findOne({ email, password }); // INJECTION RISK
});

// ✅ GOOD: Validate input first, then query with known-safe types
app.post('/login', async (req, res) => {
  const { email, password } = LoginSchema.parse(req.body); // validated as strings
  const user = await db.collection('users').findOne({
    email: { $eq: email }, // explicit equality operator
  });
  const valid = await bcrypt.compare(password, user?.passwordHash || '');
});

// ❌ BAD: Allowing object injection in query
const query = { ...req.body.filter }; // attacker can inject {$ne: null}

// ✅ GOOD: Explicit allowlist of query operators
const ALLOWED_OPERATORS = ['$eq', '$in', '$gt', '$lt', '$gte', '$lte'];
function sanitizeFilter(filter) {
  if (typeof filter !== 'object' || filter === null) return {};
  const result = {};
  for (const [key, value] of Object.entries(filter)) {
    if (key.startsWith('$') && !ALLOWED_OPERATORS.includes(key)) continue;
    result[key] = typeof value === 'object' ? sanitizeFilter(value) : value;
  }
  return result;
}
```

---

## Tiered Rate Limiting

Apply different rate limits per endpoint sensitivity. Use Redis for distributed rate limiting across multiple server instances.

### Redis Sliding Window Rate Limiter (TypeScript)

```typescript
import { Redis } from 'ioredis';
import { Request, Response, NextFunction } from 'express';

interface RateLimitConfig {
  windowMs: number;
  maxRequests: number;
  keyPrefix: string;
}

const redis = new Redis({ host: process.env.REDIS_HOST, port: 6379 });

// Tiered limits
const TIER_CONFIGS: Record<string, RateLimitConfig> = {
  login: { windowMs: 15 * 60 * 1000, maxRequests: 5, keyPrefix: 'ratelimit:login' },
  passwordReset: { windowMs: 60 * 60 * 1000, maxRequests: 3, keyPrefix: 'ratelimit:password-reset' },
  publicRead: { windowMs: 60 * 1000, maxRequests: 100, keyPrefix: 'ratelimit:read' },
  write: { windowMs: 60 * 1000, maxRequests: 30, keyPrefix: 'ratelimit:write' },
  admin: { windowMs: 60 * 1000, maxRequests: 10, keyPrefix: 'ratelimit:admin' },
};

async function checkRateLimit(
  config: RateLimitConfig,
  identifier: string
): Promise<{ allowed: boolean; remaining: number; resetTime: number }> {
  const key = `${config.keyPrefix}:${identifier}`;
  const now = Date.now();
  const windowStart = now - config.windowMs;
  
  // Sliding window: remove entries older than window, count remaining
  const pipeline = redis.pipeline();
  pipeline.zremrangebyscore(key, 0, windowStart);
  pipeline.zcard(key);
  pipeline.zadd(key, now, `${now}-${Math.random()}`);
  pipeline.pexpire(key, config.windowMs);
  const [, currentCount] = await pipeline.exec();
  
  const count = (currentCount?.[1] as number) ?? 0;
  const allowed = count < config.maxRequests;
  const remaining = Math.max(0, config.maxRequests - count - (allowed ? 1 : 0));
  const resetTime = now + config.windowMs;
  
  if (!allowed) {
    // Remove the entry we just added
    await redis.zremrangebyscore(key, now, now);
  }
  
  return { allowed, remaining, resetTime };
}

function rateLimitMiddleware(tier: string) {
  const config = TIER_CONFIGS[tier];
  if (!config) throw new Error(`Unknown rate limit tier: ${tier}`);
  
  return async (req: Request, res: Response, next: NextFunction) => {
    const identifier = req.ip || 'unknown'; // use userId for authenticated routes
    const { allowed, remaining, resetTime } = await checkRateLimit(config, identifier);
    
    res.setHeader('X-RateLimit-Limit', String(config.maxRequests));
    res.setHeader('X-RateLimit-Remaining', String(remaining));
    res.setHeader('X-RateLimit-Reset', String(Math.ceil(resetTime / 1000)));
    
    if (!allowed) {
      const retryAfter = Math.ceil(config.windowMs / 1000);
      res.setHeader('Retry-After', String(retryAfter));
      return res.status(429).json({
        error: 'Too many requests',
        code: 'RATE_LIMITED',
        retryAfter,
      });
    }
    next();
  };
}

// Express usage
app.post('/auth/login', rateLimitMiddleware('login'), loginHandler);
app.post('/auth/reset-password', rateLimitMiddleware('passwordReset'), resetHandler);
app.get('/api/*', rateLimitMiddleware('publicRead'), readHandler);
app.post('/api/*', rateLimitMiddleware('write'), writeHandler);
app.use('/admin/*', rateLimitMiddleware('admin'), adminHandler);
```

### Python Redis Rate Limiter (FastAPI)

```python
import redis
import time
from fastapi import Request, HTTPException
from fastapi.responses import JSONResponse
from functools import wraps

redis_client = redis.Redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379"))

TIER_CONFIGS = {
    "login": {"window_ms": 15 * 60 * 1000, "max_requests": 5, "prefix": "ratelimit:login"},
    "password_reset": {"window_ms": 60 * 60 * 1000, "max_requests": 3, "prefix": "ratelimit:password-reset"},
    "public_read": {"window_ms": 60 * 1000, "max_requests": 100, "prefix": "ratelimit:read"},
    "write": {"window_ms": 60 * 1000, "max_requests": 30, "prefix": "ratelimit:write"},
}

async def check_rate_limit(config: dict, identifier: str) -> dict:
    key = f"{config['prefix']}:{identifier}"
    now = int(time.time() * 1000)
    window_start = now - config["window_ms"]
    
    pipe = redis_client.pipeline()
    pipe.zremrangebyscore(key, 0, window_start)
    pipe.zcard(key)
    pipe.zadd(key, {f"{now}-{random.random()}": now})
    pipe.pexpire(key, config["window_ms"])
    _, current_count, _, _ = pipe.execute()
    
    count = current_count or 0
    allowed = count < config["max_requests"]
    remaining = max(0, config["max_requests"] - count - (1 if allowed else 0))
    reset_time = now + config["window_ms"]
    
    if not allowed:
        redis_client.zremrangebyscore(key, now, now)
    
    return {"allowed": allowed, "remaining": remaining, "reset_time": reset_time}

def rate_limit(tier: str):
    config = TIER_CONFIGS.get(tier)
    if not config:
        raise ValueError(f"Unknown rate limit tier: {tier}")
    
    def decorator(func):
        @wraps(func)
        async def wrapper(request: Request, *args, **kwargs):
            identifier = request.client.host if request.client else "unknown"
            result = await check_rate_limit(config, identifier)
            
            headers = {
                "X-RateLimit-Limit": str(config["max_requests"]),
                "X-RateLimit-Remaining": str(result["remaining"]),
                "X-RateLimit-Reset": str(result["reset_time"] // 1000),
            }
            
            if not result["allowed"]:
                retry_after = config["window_ms"] // 1000
                headers["Retry-After"] = str(retry_after)
                raise HTTPException(
                    status_code=429,
                    detail={"error": "Too many requests", "code": "RATE_LIMITED", "retryAfter": retry_after},
                    headers=headers,
                )
            
            response = await func(request, *args, **kwargs)
            if isinstance(response, JSONResponse):
                response.headers.update(headers)
            return response
        return wrapper
    return decorator

# FastAPI usage
@app.post("/auth/login")
@rate_limit("login")
async def login(request: Request, credentials: LoginRequest):
    ...
```

### Rate Limit Headers Reference

| Header | Description |
|--------|-------------|
| `X-RateLimit-Limit` | Maximum requests allowed per window |
| `X-RateLimit-Remaining` | Requests remaining in current window |
| `X-RateLimit-Reset` | Unix timestamp when the window resets |
| `Retry-After` | Seconds to wait before retrying (sent with 429) |

---

## Security Headers

Implement a security headers middleware equivalent to `helmet.js` for Express/NestJS. These headers mitigate XSS, clickjacking, MIME sniffing, and downgrade attacks.

### Express/NestJS Security Headers Middleware

```typescript
import { Request, Response, NextFunction } from 'express';

function securityHeadersMiddleware(req: Request, res: Response, next: NextFunction) {
  // HSTS — force HTTPS for 2 years, include subdomains, preload
  res.setHeader('Strict-Transport-Security', 'max-age=63072000; includeSubDomains; preload');
  
  // Prevent MIME type sniffing
  res.setHeader('X-Content-Type-Options', 'nosniff');
  
  // Prevent clickjacking
  res.setHeader('X-Frame-Options', 'DENY');
  
  // XSS protection (legacy; CSP is primary defense)
  res.setHeader('X-XSS-Protection', '0'); // disabled in favor of CSP
  
  // Content Security Policy — restrict sources
  const csp = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'", // allow inline styles if needed
    "img-src 'self' data: https:",
    "font-src 'self'",
    "connect-src 'self'",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ].join('; ');
  res.setHeader('Content-Security-Policy', csp);
  
  // Referrer Policy — limit referrer leakage
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  
  // Permissions Policy — disable unused browser features
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=()');
  
  // Cache control for sensitive responses
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.setHeader('Pragma', 'no-cache');
  
  next();
}

// NestJS: apply globally
app.use(securityHeadersMiddleware);
```

### FastAPI Security Headers Middleware

```python
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        
        response.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains; preload"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["X-XSS-Protection"] = "0"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: https:; font-src 'self'; connect-src 'self'; "
            "frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
        )
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=()"
        response.headers["Cache-Control"] = "no-store, max-age=0"
        response.headers["Pragma"] = "no-cache"
        
        return response

# FastAPI usage
app.add_middleware(SecurityHeadersMiddleware)
```

### Header Quick Reference

| Header | Purpose | Recommended Value |
|--------|---------|-------------------|
| `Strict-Transport-Security` | Enforce HTTPS | `max-age=63072000; includeSubDomains; preload` |
| `X-Content-Type-Options` | Prevent MIME sniffing | `nosniff` |
| `X-Frame-Options` | Prevent clickjacking | `DENY` |
| `Content-Security-Policy` | Restrict resource loading | `default-src 'self'; script-src 'self'; ...` |
| `Referrer-Policy` | Limit referrer data | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | Disable browser features | `camera=(), microphone=(), geolocation=()` |
| `Cache-Control` | Prevent sensitive caching | `no-store, max-age=0` |

---

## CORS Configuration

**Rule:** Never use `*` in production when credentials (cookies, auth headers) are involved. Always use an explicit allowlist.

### Express CORS — Explicit Allowlist

```typescript
import cors from 'cors';

const ALLOWED_ORIGINS = [
  'https://app.example.com',
  'https://admin.example.com',
  'https://localhost:3000', // dev only
];

const corsOptions: cors.CorsOptions = {
  origin: (origin, callback) => {
    // Allow requests with no origin (mobile apps, curl, server-to-server)
    if (!origin || ALLOWED_ORIGINS.includes(origin)) {
      callback(null, true);
    } else {
      callback(new Error('CORS policy: origin not allowed'));
    }
  },
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Request-ID'],
  credentials: true, // allow cookies/auth headers
  maxAge: 86400, // cache preflight for 24 hours
  preflightContinue: false,
  optionsSuccessStatus: 204,
};

app.use(cors(corsOptions));
```

### FastAPI CORS — Explicit Allowlist

```python
from fastapi.middleware.cors import CORSMiddleware

ALLOWED_ORIGINS = [
    "https://app.example.com",
    "https://admin.example.com",
    "https://localhost:3000",  # dev only
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
    allow_headers=["Content-Type", "Authorization", "X-Request-ID"],
    max_age=86400,
)
```

### Dynamic CORS for Multi-Tenant Apps

```typescript
// Store tenant origins in database/cache
const corsOptions: cors.CorsOptions = {
  origin: async (origin, callback) => {
    if (!origin) return callback(null, true);
    
    const tenant = await getTenantByOrigin(origin); // DB/cache lookup
    if (tenant && tenant.verified) {
      callback(null, true);
    } else {
      callback(new Error('CORS: origin not registered for this tenant'));
    }
  },
  credentials: true,
};
```

### CORS Preflight Handling

Browsers send an `OPTIONS` preflight request before cross-origin requests with custom headers or non-GET/POST methods. Ensure your server responds correctly:

```
OPTIONS /api/users HTTP/1.1
Origin: https://app.example.com
Access-Control-Request-Method: PUT
Access-Control-Request-Headers: Content-Type, Authorization

HTTP/1.1 204 No Content
Access-Control-Allow-Origin: https://app.example.com
Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE
Access-Control-Allow-Headers: Content-Type, Authorization, X-Request-ID
Access-Control-Allow-Credentials: true
Access-Control-Max-Age: 86400
```

---

## Secrets Management

### Environment Variables (.env)

**Rules:**
- `.env` files are for local development only — never commit them
- `.env.example` should be committed with dummy values as documentation
- Production secrets must live in a vault or secret manager, never in environment variables on the host
- Validate all required secrets at application startup — fail fast if missing

```bash
# .env.example (committed to repo)
DATABASE_URL=postgresql://user:pass@localhost:5432/db
REDIS_URL=redis://localhost:6379
JWT_PRIVATE_KEY_PATH=/path/to/key.pem
STRIPE_SECRET_KEY=sk_test_xxx
SENDGRID_API_KEY=SG.xxx
```

```bash
# .gitignore
.env
.env.local
.env.production
*.pem
*.key
```

### Runtime Config Validation

```typescript
// config.ts — validate at startup, fail fast
import { z } from 'zod';

const EnvSchema = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  DATABASE_URL: z.string().startsWith('postgresql://'),
  REDIS_URL: z.string().startsWith('redis://'),
  JWT_PRIVATE_KEY: z.string().min(1), // or JWT_PRIVATE_KEY_PATH
  JWT_PUBLIC_KEY: z.string().min(1),
  STRIPE_SECRET_KEY: z.string().startsWith('sk_'),
  SENDGRID_API_KEY: z.string().startsWith('SG.'),
  PORT: z.string().transform(Number).default('3000'),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
}).strict();

export const config = EnvSchema.parse(process.env); // throws if invalid
```

```python
# config.py — Pydantic Settings
from pydantic import Field, validator
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    model_config = {"env_file": ".env", "extra": "forbid"}
    
    database_url: str = Field(..., pattern=r"^postgresql://")
    redis_url: str = Field(..., pattern=r"^redis://")
    jwt_private_key: str = Field(..., min_length=1)
    jwt_public_key: str = Field(..., min_length=1)
    stripe_secret_key: str = Field(..., pattern=r"^sk_")
    sendgrid_api_key: str = Field(..., pattern=r"^SG\.")
    port: int = Field(default=8000)
    log_level: str = Field(default="info")
    
    @validator("jwt_private_key")
    @classmethod
    def check_key_not_dummy(cls, v):
        if "dummy" in v.lower() or "test" in v.lower():
            raise ValueError("JWT private key cannot be a dummy/test key in production")
        return v

settings = Settings()
```

### Production Secrets: Vault & Cloud Managers

| Tool | Use Case | Pattern |
|------|----------|---------|
| **HashiCorp Vault** | Enterprise, multi-env, dynamic secrets | App authenticates with Vault, retrieves short-lived DB credentials |
| **AWS Secrets Manager** | AWS-native apps | IAM role grants access; rotate secrets automatically |
| **Doppler** | SaaS, team-friendly, multi-env | Install CLI, `doppler secrets` injects at runtime; no `.env` files |
| **Kubernetes External Secrets Operator** | K8s clusters | Syncs secrets from AWS/GCP/Azure vaults into K8s secrets |

**Kubernetes External Secrets Operator (example):**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: app-secrets
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: prod/app/database-url
    - secretKey: JWT_PRIVATE_KEY
      remoteRef:
        key: prod/app/jwt-private-key
```

---

## Dependency Scanning

Scan dependencies for known vulnerabilities (CVEs) and license issues in CI/CD.

### Tools Comparison

| Tool | Type | Integration | Best For |
|------|------|-------------|----------|
| **Trivy** | CLI, Container scanner | CI/CD, pre-commit | Container images, filesystem, IaC |
| **Snyk** | SaaS + CLI | CI/CD, IDE, PR checks | Continuous monitoring, dependency tree |
| **npm audit** | Built-in | CLI, CI/CD | Quick Node.js checks |
| **Dependabot** | GitHub-native | PRs, alerts | Automated patch/minor updates |
| **pip-audit** | Python CLI | CI/CD | Python package vulnerability checks |

### CI/CD Integration (GitHub Actions)

```yaml
# .github/workflows/security.yml
name: Security Scan
on: [push, pull_request]

jobs:
  dependency-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      # Node.js — npm audit
      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm ci
      - run: npm audit --audit-level=high
        # Fails on high/critical vulnerabilities
      
      # Trivy — filesystem scan
      - name: Run Trivy vulnerability scanner
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: 'fs'
          scan-ref: '.'
          format: 'sarif'
          output: 'trivy-results.sarif'
      
      # Snyk — monitor continuously
      - name: Snyk test
        uses: snyk/actions/node@master
        env:
          SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
        with:
          args: --severity-threshold=high
      
      # Python — pip-audit
      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: pip install pip-audit
      - run: pip-audit --requirement=requirements.txt --desc

  container-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build image
        run: docker build -t app:${{ github.sha }} .
      - name: Trivy image scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: 'app:${{ github.sha }}'
          format: 'sarif'
          output: 'trivy-image-results.sarif'
```

### Dependabot Configuration

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 10
    labels:
      - "dependencies"
      - "security"
    # Auto-merge patch updates for non-critical deps
    # (requires additional GitHub Action for auto-merge)
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "monthly"
```

---

## File Upload Security

**Rules:**
1. Validate MIME type from file content (magic bytes), not just extension
2. Enforce size limits before processing
3. Scan for malware (ClamAV)
4. Store outside web root; use UUID filenames
5. Prevent path traversal in filenames
6. Serve via signed URLs, not direct file access

### BAD vs GOOD: File Upload

```typescript
// ❌ BAD: Trusting extension, no size limit, storing with original name
app.post('/upload', upload.single('file'), (req, res) => {
  const filename = req.file.originalname; // "../../../etc/passwd"
  fs.writeFileSync(`./uploads/${filename}`, req.file.buffer); // PATH TRAVERSAL
  res.json({ url: `/uploads/${filename}` }); // direct access
});

// ✅ GOOD: MIME validation, size limit, UUID storage, path traversal prevention, virus scan
import { v4 as uuidv4 } from 'uuid';
import path from 'path';
import fileType from 'file-type'; // magic bytes check

const ALLOWED_MIME_TYPES = [
  'image/jpeg', 'image/png', 'image/webp', 'application/pdf',
];
const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB

app.post('/upload', upload.single('file'), async (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: 'No file provided' });
  }
  
  // Size check
  if (req.file.size > MAX_FILE_SIZE) {
    return res.status(413).json({ error: 'File too large', maxSize: MAX_FILE_SIZE });
  }
  
  // MIME type validation via magic bytes (not extension)
  const type = await fileType.fromBuffer(req.file.buffer);
  if (!type || !ALLOWED_MIME_TYPES.includes(type.mime)) {
    return res.status(400).json({ error: 'Invalid file type' });
  }
  
  // Path traversal prevention: strip original name, generate UUID
  const ext = path.extname(req.file.originalname).toLowerCase();
  const safeExt = ['.jpg', '.jpeg', '.png', '.webp', '.pdf'].includes(ext) ? ext : '.bin';
  const filename = `${uuidv4()}${safeExt}`;
  const uploadPath = path.resolve('/var/uploads', filename); // absolute path outside web root
  
  // Ensure path is inside allowed directory
  if (!uploadPath.startsWith('/var/uploads/')) {
    return res.status(400).json({ error: 'Invalid path' });
  }
  
  // Optional: virus scan with ClamAV
  const clamscan = await new NodeClam().init({ clamdscan: { host: 'localhost', port: 3310 } });
  const { isInfected } = await clamscan.scanBuffer(req.file.buffer);
  if (isInfected) {
    return res.status(400).json({ error: 'File contains malware' });
  }
  
  await fs.promises.writeFile(uploadPath, req.file.buffer);
  
  // Return signed URL, not direct path
  const signedUrl = await generateSignedUrl(filename, { expiresIn: 3600 });
  res.json({ id: filename, url: signedUrl });
});
```

### Python File Upload (FastAPI)

```python
import uuid
import magic
from pathlib import Path
from fastapi import UploadFile, File, HTTPException
from fastapi.responses import JSONResponse
import clamd

ALLOWED_MIME_TYPES = {"image/jpeg", "image/png", "image/webp", "application/pdf"}
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10MB
UPLOAD_DIR = Path("/var/uploads")

def validate_upload(file: UploadFile) -> None:
    # Size check
    file.file.seek(0, 2)
    size = file.file.tell()
    file.file.seek(0)
    if size > MAX_FILE_SIZE:
        raise HTTPException(413, f"File too large. Max size: {MAX_FILE_SIZE}")
    
    # MIME type from magic bytes
    content = file.file.read(2048)
    file.file.seek(0)
    mime = magic.from_buffer(content, mime=True)
    if mime not in ALLOWED_MIME_TYPES:
        raise HTTPException(400, f"Invalid file type: {mime}")
    
    # Virus scan
    cd = clamd.ClamdUnixSocket()
    result = cd.scan_stream(file.file.read())
    file.file.seek(0)
    if result and result.get("stream") and result["stream"][0] == "FOUND":
        raise HTTPException(400, "File contains malware")

@app.post("/upload")
async def upload_file(file: UploadFile = File(...)):
    validate_upload(file)
    
    ext = Path(file.filename).suffix.lower() if file.filename else ".bin"
    safe_ext = ext if ext in {".jpg", ".jpeg", ".png", ".webp", ".pdf"} else ".bin"
    filename = f"{uuid.uuid4()}{safe_ext}"
    upload_path = UPLOAD_DIR / filename
    
    # Ensure path is inside upload directory
    try:
        upload_path.relative_to(UPLOAD_DIR)
    except ValueError:
        raise HTTPException(400, "Invalid path")
    
    with open(upload_path, "wb") as f:
        f.write(await file.read())
    
    signed_url = generate_signed_url(filename, expires_in=3600)
    return JSONResponse({"id": filename, "url": signed_url})
```

### Signed URL for Downloads

```typescript
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

const s3 = new S3Client({ region: 'us-east-1' });

async function generateSignedUrl(key: string, options: { expiresIn: number }): Promise<string> {
  const command = new GetObjectCommand({
    Bucket: process.env.S3_BUCKET!,
    Key: key,
  });
  return getSignedUrl(s3, command, { expiresIn: options.expiresIn });
}
```

---

## XSS & CSRF Protection

### XSS Prevention

| Layer | Defense | Implementation |
|-------|---------|----------------|
| Output encoding | Escape all user-generated content before rendering | Use framework auto-escaping (React, Vue) or libraries like `he` |
| Content Security Policy | Block inline scripts and restrict sources | `script-src 'self'` |
| Input validation | Reject suspicious patterns | Zod/Pydantic strict schemas |
| HttpOnly cookies | Prevent cookie theft via JS | `Set-Cookie: session=...; HttpOnly` |

```typescript
// ❌ BAD: Rendering raw user input
app.get('/profile', (req, res) => {
  res.send(`<h1>Hello, ${req.query.name}</h1>`); // XSS if name = <script>alert(1)</script>
});

// ✅ GOOD: Framework auto-escaping or explicit encoding
import { escape } from 'he';
app.get('/profile', (req, res) => {
  res.json({ name: req.query.name }); // JSON is safe
  // Or if rendering HTML: res.render('profile', { name: escape(req.query.name) });
});
```

### CSRF Protection for Stateful Sessions

```typescript
// ❌ BAD: No CSRF protection on state-changing routes
app.post('/transfer', (req, res) => {
  const { to, amount } = req.body;
  transferFunds(req.session.userId, to, amount); // CSRF if attacker tricks user into POST
});

// ✅ GOOD: CSRF token pattern + SameSite cookies
import csrf from 'csurf';

// 1. SameSite cookie (primary defense)
app.use(session({
  cookie: {
    httpOnly: true,
    secure: true,       // HTTPS only
    sameSite: 'strict', // or 'lax' if you need cross-site GET
    maxAge: 3600000,
  },
}));

// 2. CSRF token middleware (secondary defense)
const csrfProtection = csrf({ cookie: { httpOnly: true, secure: true, sameSite: 'strict' } });
app.get('/csrf-token', csrfProtection, (req, res) => {
  res.json({ csrfToken: req.csrfToken() });
});
app.post('/transfer', csrfProtection, (req, res) => {
  // req.body must include _csrf or X-CSRF-Token header
  transferFunds(req.session.userId, req.body.to, req.body.amount);
});
```

### Double Submit Cookie Pattern (Stateless CSRF)

For stateless JWT APIs, CSRF is less of an issue (no session cookie). But if using cookies for auth:

```typescript
// Generate a random CSRF token, store hash in cookie, send plain in header
app.use((req, res, next) => {
  const csrfToken = crypto.randomBytes(32).toString('hex');
  res.cookie('csrf_token', crypto.createHash('sha256').update(csrfToken).digest('hex'), {
    httpOnly: true, secure: true, sameSite: 'strict',
  });
  res.setHeader('X-CSRF-Token', csrfToken);
  next();
});

// Validate: header token must hash to cookie value
app.use((req, res, next) => {
  if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) {
    const headerToken = req.headers['x-csrf-token'];
    const cookieHash = req.cookies['csrf_token'];
    const expectedHash = crypto.createHash('sha256').update(headerToken).digest('hex');
    if (!headerToken || cookieHash !== expectedHash) {
      return res.status(403).json({ error: 'Invalid CSRF token' });
    }
  }
  next();
});
```

---

## SSRF Prevention

Server-Side Request Forgery (API7) occurs when an attacker can make the server send requests to internal services or external systems.

```typescript
// ❌ BAD: Unrestricted URL fetching
app.post('/webhook/verify', async (req, res) => {
  const { url } = req.body;
  const response = await fetch(url); // attacker can send url=http://169.254.169.254/
  res.json({ status: response.status });
});

// ✅ GOOD: URL validation, allowlist, block private IPs, disable redirects
import { URL } from 'url';
import ipaddr from 'ipaddr.js';

const ALLOWED_DOMAINS = ['api.stripe.com', 'api.sendgrid.com', 'hooks.slack.com'];

function isPrivateIP(ip: string): boolean {
  try {
    const addr = ipaddr.parse(ip);
    return addr.range() !== 'unicast'; // private, loopback, link-local, etc.
  } catch {
    return false;
  }
}

async function safeFetch(url: string, options?: RequestInit): Promise<Response> {
  const parsed = new URL(url);
  
  // Block non-HTTP protocols
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    throw new Error('Only HTTP/HTTPS allowed');
  }
  
  // Allowlist domain
  if (!ALLOWED_DOMAINS.includes(parsed.hostname)) {
    throw new Error('Domain not in allowlist');
  }
  
  // Resolve DNS and block private IPs (prevent DNS rebinding)
  const addresses = await dns.promises.resolve4(parsed.hostname);
  for (const ip of addresses) {
    if (isPrivateIP(ip)) {
      throw new Error('Private IP addresses are blocked');
    }
  }
  
  // Fetch with redirect disabled
  return fetch(url, { ...options, redirect: 'manual' });
}
```

---

## Unsafe API Consumption

When calling third-party APIs, validate responses and protect against supply chain attacks.

```typescript
// ❌ BAD: Blindly trusting external API response
const stripeEvent = await fetch('https://api.stripe.com/v1/events/evt_123');
const data = await stripeEvent.json();
processPayment(data); // what if Stripe is compromised or response is malformed?

// ✅ GOOD: Validate response schema, use circuit breaker, timeout
import { z } from 'zod';

const StripeEventSchema = z.object({
  id: z.string().startsWith('evt_'),
  type: z.string(),
  data: z.object({
    object: z.record(z.any()),
  }),
  created: z.number(),
}).strict();

async function callExternalAPI<T>(
  url: string,
  schema: z.ZodSchema<T>,
  options: { timeout: number; retries: number } = { timeout: 10000, retries: 3 }
): Promise<T> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeout);
  
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: { 'Accept': 'application/json' },
    });
    clearTimeout(timeout);
    
    if (!response.ok) {
      throw new Error(`External API error: ${response.status}`);
    }
    
    const data = await response.json();
    return schema.parse(data); // strict validation
  } catch (error) {
    clearTimeout(timeout);
    throw error;
  }
}

// Usage
const event = await callExternalAPI('https://api.stripe.com/v1/events/evt_123', StripeEventSchema);
```

---

## Security Logging & Error Handling

### Structured Logging (Redact Secrets)

```typescript
import pino from 'pino';

const SENSITIVE_FIELDS = ['password', 'token', 'secret', 'authorization', 'cookie', 'apiKey'];

const logger = pino({
  level: config.LOG_LEVEL,
  redact: {
    paths: SENSITIVE_FIELDS.map(f => `req.headers.${f}`).concat(
      SENSITIVE_FIELDS.map(f => `*.${f}`),
      ['req.headers.cookie', 'req.headers.authorization']
    ),
    censor: '[REDACTED]',
  },
  serializers: {
    err: pino.stdSerializers.err,
    req: (req) => ({
      id: req.id,
      method: req.method,
      url: req.url,
      headers: req.headers,
      remoteAddress: req.remoteAddress,
    }),
  },
});

// Log security events
logger.warn({ event: 'suspicious_login', ip, userId, reason: 'too_many_attempts' });
logger.error({ event: 'auth_failure', ip, path: req.url, error: 'invalid_token' });
```

### Error Response (Never Expose Internals)

```typescript
// ❌ BAD: Exposing internal details
app.use((err, req, res, next) => {
  res.status(500).json({ error: err.message, stack: err.stack }); // NEVER
});

// ✅ GOOD: Generic error to client, detailed log to server
app.use((err, req, res, next) => {
  const requestId = req.id || 'unknown';
  const isDev = config.NODE_ENV === 'development';
  
  logger.error({ err, requestId, path: req.url, method: req.method });
  
  if (err.code === 'INVALID_INPUT') {
    return res.status(400).json({ error: err.message, code: err.code, details: err.details });
  }
  if (err.code === 'RATE_LIMITED') {
    return res.status(429).json({ error: err.message, code: err.code, retryAfter: err.retryAfter });
  }
  if (err.code === 'UNAUTHORIZED') {
    return res.status(401).json({ error: 'Unauthorized', code: err.code });
  }
  
  // Generic 500 — never expose stack or DB details
  res.status(500).json({
    error: 'Internal server error',
    code: 'INTERNAL_ERROR',
    requestId, // for support correlation
    ...(isDev && { details: err.message }), // only in dev
  });
});
```

---

## Quick Security Checklist

Before shipping any backend:

- [ ] Input validation — Zod/Pydantic strict schemas, reject unknown fields
- [ ] Parameterized queries — ORM or prepared statements; never string concatenation
- [ ] Authentication — see `auth.md` for JWT, OAuth, refresh rotation
- [ ] Authorization — see `auth.md` for BOLA prevention, RBAC, ABAC
- [ ] Rate limiting — tiered limits (login, read, write, admin) via Redis
- [ ] HTTPS — TLS 1.3, HSTS with preload
- [ ] Security headers — CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy
- [ ] CORS — explicit allowlist, never `*` with credentials
- [ ] Secrets — env validation at startup; vault in production
- [ ] File uploads — MIME validation, size limits, virus scan, UUID storage, signed URLs
- [ ] XSS/CSRF — CSP, output encoding, SameSite cookies, CSRF tokens for stateful sessions
- [ ] SSRF — URL allowlist, block private IPs, disable redirects
- [ ] Error handling — generic messages to client, detailed logs to server
- [ ] Logging — structured, redact secrets, log security events
- [ ] Dependencies — Trivy/Snyk/Dependabot in CI/CD
- [ ] Container — non-root user, read-only filesystem, minimal base image

---

## Code Snippet Index

| Snippet | Description | Lines |
|---------|-------------|-------|
| Zod Strict Validation | Strict schema with custom validators, nested objects, arrays | TypeScript |
| Pydantic Strict Model | ConfigDict strict mode, custom validators, email validation | Python |
| Parameterized SQL Query | BAD vs GOOD comparison for raw SQL and ORM | TypeScript/Python |
| Tiered Redis Rate Limiter | Sliding window with Redis, headers, multiple tiers | TypeScript/Python |
| Security Headers Middleware | HSTS, CSP, Permissions-Policy, Referrer-Policy | TypeScript/Python |
| CORS Config | Explicit allowlist, credentials, preflight | TypeScript/Python |
| File Upload Validation | MIME type check, size limits, virus scan, UUID storage | TypeScript/Python |
| Dependency Scan CI/CD | npm audit, Trivy, Snyk, pip-audit in GitHub Actions | YAML |

---

*Last updated: 2025-06-28*
