---
name: kimi-backend
description: Expert backend engineering skill for designing, building, and deploying robust web application backends — from simple CRUD APIs and e-commerce stores to complex SaaS platforms, social media, AI platforms, CRM/ERP systems, and management dashboards. Use when Kimi needs to design a database schema, build REST/GraphQL APIs, implement authentication (JWT, OAuth, RBAC), integrate payments (Stripe), set up real-time systems (WebSocket, SSE), configure message queues, implement caching (Redis), deploy with Docker/CI-CD, write API tests, handle webhooks, design event-driven architectures, or build any server-side system. Triggers on keywords: backend, API, server, database, auth, authentication, JWT, OAuth, REST API, GraphQL, microservices, monolith, PostgreSQL, Prisma, ORM, Redis, caching, Stripe, payment, webhook, real-time, WebSocket, SSE, Socket.io, message queue, Kafka, RabbitMQ, BullMQ, Docker, Kubernetes, CI/CD, deployment, serverless, Cloudflare Workers, NestJS, FastAPI, Express, Hono, testing, API security, rate limiting, CORS, input validation, SQL injection, OWASP, full-stack.
---

# kimi-backend — Expert Backend Engineering

Design and build production-grade web application backends. Covers architecture decisions, database design, API development, authentication, security, integrations, real-time systems, DevOps, and testing.

## Core Philosophy

1. **Security by default.** Every API starts with input validation, auth, and rate limiting.
2. **Monolith first.** Modular monolith is the default; microservices only when team size demands it.
3. **PostgreSQL + Redis as foundation.** Start relational, add NoSQL/vector when data shape demands it.
4. **Type-safe everywhere.** Schema validation, type-safe ORMs, and typed API contracts prevent runtime bugs.
5. **Queue all side effects.** Email, notifications, file processing, and search indexing happen asynchronously.
6. **Observability is not optional.** Structured logging, metrics, and health checks from day one.

## Architecture Decision Tree

```
What is the project type?
├── Simple CRUD / Web Store / Blog
│   └── Modular Monolith + PostgreSQL + Redis + FastAPI or NestJS
├── SaaS Platform / Management System
│   └── Modular Monolith + PostgreSQL + Redis + NestJS + BullMQ
├── Social Media / Real-time Collaboration
│   └── Modular Monolith + PostgreSQL + Redis Pub/Sub + Socket.io + NestJS
├── AI Platform / ML API
│   └── Modular Monolith + PostgreSQL + pgvector + FastAPI + Redis
├── High-throughput Microservices
│   └── Microservices + Go + PostgreSQL + Kafka + gRPC
└── Edge / Serverless / JAMstack
    └── Hono + Cloudflare Workers + D1 + R2
```

### Team Size → Architecture

| Team Size | Architecture | When to Extract Services |
|-----------|-------------|------------------------|
| 1–5 | Monolith | Never — velocity over scale |
| 5–15 | Modular Monolith | Independent scaling needs emerge |
| 15–40 | Modular Monolith with async services | Different teams own different modules |
| 40+ | Microservices (with event bus) | Clear service boundaries, polyglot needs |

### Performance → Language

| Throughput Need | Language/Framework | Use Case |
|-----------------|-------------------|----------|
| Standard (1–10k RPS) | TypeScript/NestJS or Python/FastAPI | Most SaaS, AI platforms |
| High (10k–50k RPS) | Go/Gin or Node.js/Fastify | High-traffic APIs, real-time |
| Extreme (50k+ RPS) | Rust/Axum or Go | Low-latency trading, infrastructure |
| Edge/Serverless | TypeScript/Hono | Cloudflare Workers, Deno Deploy |

## Stack Selection by Project Type

| Project Type | Recommended Stack |
|-------------|-------------------|
| AI Agent API | FastAPI + PostgreSQL + Redis + Docker |
| SaaS Platform | NestJS + PostgreSQL + Prisma + Redis + BullMQ |
| E-commerce | NestJS + PostgreSQL + Prisma + Redis + Stripe + BullMQ |
| Social Media | NestJS + PostgreSQL + Redis Pub/Sub + Socket.io + BullMQ |
| Real-time Collaboration | Node.js + Socket.io + Redis + PostgreSQL |
| High-performance Microservices | Go + PostgreSQL + Kafka + gRPC |
| Edge / Serverless | Hono + Cloudflare Workers + D1 + R2 |
| Enterprise / CMS | Django + PostgreSQL + Celery + Elasticsearch |

## 8-Step Backend Design Workflow

### Step 1: Define Data Model
- Identify entities, relationships, and access patterns
- Choose PostgreSQL as default; use MongoDB only for unstructured data
- Design schema with normalized tables + JSONB for flexibility
- Add indexes for query paths before they become bottlenecks
- See **databases.md** for schema design patterns, ORM selection, and migration strategies

### Step 2: Design API Contract
- Define resource-oriented REST endpoints or GraphQL schema
- Document with OpenAPI/Swagger or GraphQL SDL
- Choose pagination: cursor-based for large datasets, offset for small
- See **apis.md** for REST conventions, GraphQL decisions, pagination, and versioning

### Step 3: Implement Authentication
- Use JWT for stateless APIs; OAuth 2.1 + OIDC for third-party/SSO
- Short-lived access tokens (5–15 min) + refresh token rotation
- Store refresh tokens in HttpOnly, Secure, SameSite=Strict cookies
- Implement RBAC at route level; ABAC for complex rules
- See **auth.md** for JWT, OAuth, RBAC, session patterns, and BOLA prevention

### Step 4: Build Core API Routes
- Validate all input with Zod (TypeScript) or Pydantic (Python)
- Use parameterized queries or ORM — never string concatenation
- Return consistent error shapes: `{ error: string, code: string, details?: any }`
- Add request ID logging and correlation IDs for tracing
- See **apis.md** for route patterns and error handling

### Step 5: Add Caching
- Implement cache-aside pattern with Redis for read-heavy workloads
- Cache at API response level and database query level
- Invalidate on write; use pattern invalidation for list caches
- See **databases.md** for caching patterns and cache stampede prevention

### Step 6: Integrate External Services
- Queue all side effects: email, notifications, file processing, search indexing
- Use Stripe for payments with idempotency keys and webhook verification
- Use S3 or R2 for file storage; Cloudflare R2 for zero-egress media delivery
- See **integrations.md** for payments, email, storage, and search integration patterns

### Step 7: Add Real-Time (if needed)
- Use SSE for server→client events (notifications, AI streaming, live logs)
- Use WebSocket only for bidirectional (chat, gaming, collaborative editing)
- Scale WebSocket with Redis Pub/Sub adapter for cross-server routing
- See **realtime.md** for WebSocket scaling, SSE, and presence patterns

### Step 8: Deploy & Monitor
- Containerize with multi-stage Docker; never use `latest` tag
- Use Docker Compose for local; GitOps (ArgoCD) for production Kubernetes
- CI/CD: test → build → scan → push → deploy with GitHub Actions
- Observability: Pino structured logging + Prometheus metrics + health checks
- See **devops.md** for Docker, CI/CD, and monitoring setup

## Security Baseline Checklist

Every backend must implement these before shipping:

- [ ] **Input validation** — Zod/Pydantic with strict schemas, reject unknown fields
- [ ] **Parameterized queries** — ORM or prepared statements; never string concatenation
- [ ] **Authentication** — JWT (RS256/ES256) with short expiry; refresh token rotation
- [ ] **Authorization** — BOLA prevention: verify ownership on every resource access
- [ ] **Rate limiting** — Tiered: login (5/15min), read (100/1min), write (30/1min)
- [ ] **HTTPS everywhere** — TLS 1.3 minimum; HSTS headers
- [ ] **Security headers** — HSTS, X-Content-Type-Options, X-Frame-Options, CSP
- [ ] **CORS** — Explicit allowlist, never `*` in production with credentials
- [ ] **Secrets management** — Environment variables locally; vault (HashiCorp, Doppler) in production
- [ ] **Logging** — Structured logs with redaction of auth tokens, passwords, PII
- [ ] **Error handling** — Never expose stack traces or DB details to clients
- [ ] **Dependency scanning** — Trivy, Snyk, or Dependabot in CI/CD pipeline

See **security.md** for OWASP API Top 10 mapped to fixes, implementation details, and code examples.

## Testing Strategy

| Layer | Purpose | Tools | Coverage Target |
|-------|---------|-------|-----------------|
| Unit | Isolate business logic | Vitest/Jest, pytest | 80%+ |
| Integration | API + DB together | Supertest, pytest + testcontainers | All routes |
| Security | OWASP checks | OWASP ZAP, automated checklist | All endpoints |
| E2E | Full user flow | Playwright, Cypress | Critical paths |

See **testing.md** for testing patterns, mocking strategies, and test database setup.

## Quick Reference by Task

| Task | Go To | Key Pattern |
|------|-------|-------------|
| Choose database | databases.md | PostgreSQL default; MongoDB for unstructured only |
| Design API | apis.md | Resource URLs, cursor pagination, consistent errors |
| Build auth | auth.md | JWT RS256 + refresh rotation + RBAC |
| Secure API | security.md | Input validation + BOLA + rate limiting + HTTPS |
| Add payments | integrations.md | Stripe PaymentIntent + webhook idempotency |
| Add real-time | realtime.md | SSE first; WebSocket only for bidirectional |
| Deploy | devops.md | Docker multi-stage + GitOps + Prometheus |
| Test | testing.md | Unit → Integration → E2E pyramid |

## Boilerplate Scripts

Run these to scaffold new projects:

```bash
# NestJS + PostgreSQL + Prisma + Redis + Docker
bash scripts/init-nestjs-api.sh my-project

# FastAPI + PostgreSQL + SQLAlchemy + Alembic + Docker
bash scripts/init-fastapi-api.sh my-project

# Hono + Cloudflare Workers + D1 + R2
bash scripts/init-hono-edge.sh my-project

# Security checklist (run against any API)
bash scripts/security-checklist.sh http://localhost:3000
```

## Reference File Index

Load these files as needed — never all at once:

- **references/architecture.md** — Monolith, microservices, modular monolith, serverless; decision framework; migration path
- **references/databases.md** — PostgreSQL vs MongoDB, ORM comparison (Prisma, Drizzle, SQLAlchemy), migrations, connection pooling, read replicas, caching patterns, query optimization
- **references/apis.md** — RESTful best practices, GraphQL vs REST vs gRPC, tRPC, WebSocket vs SSE, pagination (cursor + offset), versioning, error handling, OpenAPI
- **references/auth.md** — JWT best practices (RS256, short-lived), OAuth 2.1 + OIDC, RBAC, ABAC, scope-based access, session management, BOLA prevention, refresh token rotation
- **references/security.md** — OWASP API Top 10 mapped to fixes, input validation (Zod/Pydantic), SQL injection prevention, tiered rate limiting, security headers, CORS, secrets management, dependency scanning
- **references/integrations.md** — Stripe payments (PaymentIntent + webhooks), email queues (Resend, SendGrid), file storage (S3/R2), search (PostgreSQL full-text, Elasticsearch, Algolia), notification patterns
- **references/realtime.md** — WebSocket scaling with Redis adapter, SSE for streaming, Socket.io patterns, presence with TTL, disconnection handling, message ordering
- **references/devops.md** — Docker multi-stage builds, Docker Compose, CI/CD pipelines (GitHub Actions), GitOps with ArgoCD, monitoring (Prometheus + Grafana), structured logging (Pino), OpenTelemetry, alerting
- **references/testing.md** — Testing pyramid, unit testing (Vitest, pytest), API integration testing (Supertest, testcontainers), mocking strategies (MSW, nock), contract testing, E2E testing

## Tech Stack Cheat Sheet

```
Language:     TypeScript (NestJS/Fastify/Hono) or Python (FastAPI)
Database:     PostgreSQL (default) + Redis (caching + sessions + queues)
ORM:          Prisma (TS) or SQLAlchemy (Python)
Auth:         JWT (RS256) + bcrypt + OAuth 2.1 (for SSO)
Validation:   Zod (TS) or Pydantic (Python)
Queue:        BullMQ (TS) or Celery (Python) + Redis
Payments:     Stripe (PaymentIntent + webhooks)
Email:        Resend or SendGrid (queued via BullMQ/Celery)
Storage:      Cloudflare R2 (media) or AWS S3 (enterprise)
Search:       PostgreSQL full-text → pgvector → Elasticsearch
Real-time:    SSE (default) → Socket.io (bidirectional)
Container:    Docker + Docker Compose (local) / Kubernetes + GitOps (prod)
CI/CD:        GitHub Actions → Trivy scan → deploy
Monitoring:   Pino (logs) + Prometheus (metrics) + Grafana (dashboards)
```
