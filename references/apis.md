# API Design Reference

A production-ready reference for designing, implementing, and documenting APIs. Covers REST, GraphQL, gRPC, tRPC, WebSocket, SSE, pagination, versioning, error handling, and OpenAPI.

---

## Table of Contents

1. [RESTful Best Practices](#1-restful-best-practices)
2. [GraphQL vs REST vs gRPC vs tRPC](#2-graphql-vs-rest-vs-grpc-vs-trpc)
3. [API Versioning](#3-api-versioning)
4. [Pagination](#4-pagination)
5. [Error Handling](#5-error-handling)
6. [WebSocket vs SSE vs Polling](#6-websocket-vs-sse-vs-polling)
7. [OpenAPI / Swagger](#7-openapi--swagger)
8. [Rate Limiting at API Gateway](#8-rate-limiting-at-api-gateway)
9. [API Design Examples](#9-api-design-examples)
10. [Code Snippets](#10-code-snippets)

---

## 1. RESTful Best Practices

### Resource-Oriented URLs

Use nouns (not verbs). Pluralize collections.

| Good | Bad |
|------|-----|
| `GET /users` | `GET /getUsers` |
| `POST /users` | `POST /createUser` |
| `PATCH /users/123` | `POST /updateUser/123` |

Nested resources: `GET /users/123/orders`, `POST /users/123/orders`.

### HTTP Method Semantics

| Method | Idempotent | Safe | Purpose |
|--------|------------|------|---------|
| GET | Yes | Yes | Read resource(s) |
| POST | No | No | Create / execute action |
| PUT | Yes | No | Full replacement |
| PATCH | No | No | Partial update |
| DELETE | Yes | No | Remove resource |

### Status Codes

| Code | Use When | Body |
|------|----------|------|
| 200 OK | Generic success | Resource or list |
| 201 Created | Created resource | Resource + `Location` header |
| 204 No Content | Successful DELETE | None |
| 400 Bad Request | Validation/syntax error | Error details |
| 401 Unauthorized | Missing/invalid auth | Error object |
| 403 Forbidden | Authenticated but not permitted | Error object |
| 404 Not Found | Resource does not exist | Error object |
| 409 Conflict | State conflict (duplicate, stale) | Error object |
| 422 Unprocessable Entity | Semantic validation errors | Per-field errors |
| 429 Too Many Requests | Rate limit exceeded | Error + `Retry-After` |
| 500 Internal Server Error | Unexpected failure | Generic error (no internals) |
| 503 Service Unavailable | Overload / maintenance | `Retry-After` header |

### HATEOAS & Idempotency

Include lightweight `links` in responses for discoverability. Full hypermedia is optional.

```json
{
  "id": 123,
  "links": [
    { "rel": "self", "href": "/v1/users/123" },
    { "rel": "orders", "href": "/v1/users/123/orders" }
  ]
}
```

GET / PUT / DELETE are idempotent by spec. For POST, use an `Idempotency-Key` header:

```
Idempotency-Key: <uuid>
```

Server caches the key → response mapping for 24h and returns the cached response for duplicates.

---

## 2. GraphQL vs REST vs gRPC vs tRPC

### Decision Matrix

| Use Case | REST | GraphQL | gRPC | tRPC |
|----------|------|---------|------|------|
| Public third-party API | ✅ Best | ✅ Good | ❌ Hard | ❌ Not suitable |
| Mobile app with variable fields | ⚠️ Okay | ✅ Best | ✅ Good | ❌ Not suitable |
| Microservice internal comms | ⚠️ Okay | ❌ Overkill | ✅ Best | ⚠️ Okay |
| Full-stack TypeScript (Next.js + Node) | ⚠️ Okay | ✅ Good | ❌ Overkill | ✅ Best |
| Real-time streaming | ❌ Polling only | ✅ Subscriptions | ✅ Streaming | ✅ Subscriptions |
| BFF (Backend for Frontend) | ⚠️ Many endpoints | ✅ Single endpoint | ❌ Complex | ✅ Type-safe |
| Legacy / polyglot environment | ✅ Best | ✅ Good | ✅ Good | ❌ TS only |
| Bandwidth-constrained (IoT) | ⚠️ Verbose | ⚠️ Verbose | ✅ Binary + HTTP/2 | ⚠️ Verbose |
| Rapid prototyping with strong types | ⚠️ Manual | ✅ Good codegen | ✅ Good codegen | ✅ Best (zero codegen) |
| File upload / multipart | ✅ Best | ⚠️ Mutations | ❌ Complex | ⚠️ Limited |

### When to Pick Each

- **REST**: Public APIs, HTTP caching, CDN-friendly, simple CRUD.
- **GraphQL**: Aggregate data sources, flexible client queries, reduce over-fetching, BFF.
- **gRPC**: High-performance microservices, polyglot backends, streaming, low latency.
- **tRPC**: Full-stack TypeScript monorepos, zero build-step type safety, rapid development.

### Caveats

| Protocol | Caveats |
|----------|---------|
| REST | Over-fetching, N+1 without care, versioning surface area |
| GraphQL | Query complexity attacks, harder caching, awkward file uploads |
| gRPC | Needs Envoy/GRPC-Web for browser, binary debugging is harder |
| tRPC | TypeScript-only, no public API gateway, ties frontend to backend stack |

---

## 3. API Versioning

### Strategies

| Strategy | Example | Pros | Cons | Verdict |
|----------|---------|------|------|---------|
| URI Path | `/v1/users` | Simple, cache-friendly | Pollutes URL | ✅ Recommended |
| Header | `Api-Version: 1` | Clean URLs | Hidden, cache issues | ⚠️ Acceptable |
| Query Param | `/users?version=1` | Easy to test | Pollutes query space | ❌ Avoid |
| Content Negotiation | `Accept: application/vnd.api.v1+json` | Pure REST | Overly complex | ❌ Avoid |

### Recommendation: URI Path

Use `/v1/` prefix. Only bump major versions for breaking changes. Add new fields freely in backward-compatible releases. Deprecate old versions with a `Sunset` header and migration guide.

---

## 4. Pagination

### Offset-Based (small datasets < 10k)

Best for admin UIs, jump-to-page, small tables.

```
GET /users?page=2&size=20
```

```json
{
  "data": [ /* 20 items */ ],
  "page": 2, "size": 20, "total": 147, "totalPages": 8
}
```

**Cons:** `OFFSET` degrades in SQL at scale; inconsistent results if data shifts during pagination.

### Cursor-Based (large datasets > 10k)

Best for infinite scroll, high-velocity feeds, event logs. Use a stable sortable column (e.g., `created_at` + `id` composite).

```
GET /users?cursor=eyJjIjoiMjAyNC0wMS0xNVQwOjAwOjAwWiIsImlkIjoxMjN9&limit=20
```

```json
{
  "data": [ /* 20 items */ ],
  "nextCursor": "eyJjIjoiMjAyNC0wMS0xNFQxNjowMDowMFoiLCJpZCI6NDU2fQ==",
  "hasMore": true
}
```

**Cursor encoding:** Base64(JSON) to prevent tampering and keep opaque to clients.

---

## 5. Error Handling

### Consistent Error Response Shape

```json
{
  "error": "Conflict",
  "code": "ORDER_ALREADY_SHIPPED",
  "details": { "orderId": "ORD-123", "status": "shipped" },
  "requestId": "req_abc123xyz"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `error` | Yes | Human-readable error name |
| `code` | Yes | Machine-readable stable code (e.g., `USER_NOT_FOUND`) |
| `details` | No | Structured context (validation errors, hints) |
| `requestId` | No | Correlation ID for log tracing |

### HTTP Status → Error Code Mapping

| Status | Example Codes |
|--------|---------------|
| 400 | `INVALID_JSON`, `VALIDATION_ERROR`, `MISSING_FIELD` |
| 401 | `UNAUTHORIZED`, `TOKEN_EXPIRED` |
| 403 | `FORBIDDEN`, `PLAN_LIMIT_REACHED` |
| 404 | `USER_NOT_FOUND`, `ORDER_NOT_FOUND` |
| 409 | `EMAIL_ALREADY_EXISTS`, `ORDER_ALREADY_SHIPPED` |
| 422 | `INVALID_STATE_TRANSITION`, `UNSUPPORTED_CURRENCY` |
| 429 | `RATE_LIMIT_EXCEEDED`, `QUOTA_EXHAUSTED` |
| 500 | `INTERNAL_ERROR`, `DATABASE_UNAVAILABLE` |

### Security Rules

- **Never** expose stack traces, SQL queries, file paths, or internal hostnames.
- Log full details server-side; send minimal, safe info to the client.
- Always include a `requestId` so support can correlate with logs.

---

## 6. WebSocket vs SSE vs Polling

### Comparison Table

| Feature | WebSocket | SSE | Polling |
|---------|-----------|-----|---------|
| Direction | Bidirectional | Server → Client | Client → Server |
| Protocol | ws:// / wss:// | HTTP (text/event-stream) | HTTP |
| Latency | Lowest | Low | High |
| Reconnection | Manual | Automatic (EventSource) | N/A |
| Browser support | Excellent | Good (no IE11) | Universal |
| Best for | Chat, games, collaboration | Live feeds, notifications | Legacy fallback |
| Scalability | Harder (stateful) | Easier | Easiest (stateless) |

### Decision Rule

- **SSE**: Server → Client push, dashboards, live notifications, logs.
- **WebSocket**: Bidirectional chat, multiplayer games, real-time collaboration, binary streaming.
- **Polling**: Fallback only when SSE/WebSocket are unavailable or for very low-frequency updates.

---

## 7. OpenAPI / Swagger

### Document-First Approach

1. Write the OpenAPI 3.1 spec first (YAML or JSON).
2. Validate with `swagger-editor` or `redocly` CLI.
3. Generate server stubs and client SDKs from the spec.
4. Keep the spec in version control; PRs include spec changes.

### Generating Client SDKs

```bash
# TypeScript client from OpenAPI spec
npx @openapitools/openapi-generator-cli generate \
  -i api.yaml -g typescript-axios -o ./clients/ts
```

### Code Generation from OpenAPI

```bash
# Express server stubs
npx @openapitools/openapi-generator-cli generate \
  -i api.yaml -g nodejs-express-server -o ./server
```

### Best Practices

- Keep specs DRY with `$ref` to shared schemas.
- Tag endpoints for logical grouping.
- Include `operationId` for every endpoint (used for SDK method names).
- Document error responses alongside 200/201.
- Add `examples` to schema properties for clarity.

---

## 8. Rate Limiting at API Gateway

### Headers

| Header | Purpose |
|--------|---------|
| `X-RateLimit-Limit` | Max requests per window |
| `X-RateLimit-Remaining` | Requests remaining in current window |
| `X-RateLimit-Reset` | Unix timestamp when limit resets |
| `Retry-After` | Seconds to wait before retry (429 or 503) |

### 429 Response Example

```http
HTTP/1.1 429 Too Many Requests
Content-Type: application/json
Retry-After: 60
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1704067200
{ "error": "Too Many Requests", "code": "RATE_LIMIT_EXCEEDED", "requestId": "req_abc123" }
```

### Algorithms

| Algorithm | Description | Best For |
|-----------|-------------|----------|
| **Token Bucket** | Tokens refill at fixed rate; burst allowed up to bucket capacity | APIs with occasional bursts (checkout, upload) |
| **Sliding Window** | Count requests in a rolling window; no burst allowance | Strict fair limits, billing meters |
| **Fixed Window** | Count per calendar window (e.g., minute). Simple but allows edge spikes | Internal analytics, low-sensitivity endpoints |

### Recommendation

- **Token bucket** for public APIs (bursts are natural user behavior).
- **Sliding window** for metered/billing APIs where strict fairness matters.
- Implement at the **API Gateway** (Kong, AWS API Gateway, Nginx, Envoy) rather than in every service.

---

## 9. API Design Examples

### Complete REST API: User/Orders System

```yaml
openapi: 3.1.0
info:
  title: Shop API
  version: 1.0.0
paths:
  /v1/users:
    get:
      operationId: listUsers
      tags: [Users]
      parameters:
        - name: cursor
          in: query
          schema: { type: string }
        - name: limit
          in: query
          schema: { type: integer, default: 20 }
        - name: role
          in: query
          schema: { type: string, enum: [admin, customer] }
      responses:
        200:
          description: Paginated list of users
          content:
            application/json:
              schema:
                type: object
                properties:
                  data: { type: array, items: { $ref: '#/components/schemas/User' } }
                  nextCursor: { type: string }
                  hasMore: { type: boolean }
    post:
      operationId: createUser
      tags: [Users]
      requestBody:
        content:
          application/json:
            schema: { $ref: '#/components/schemas/UserCreate' }
      responses:
        201:
          description: Created user
          content:
            application/json:
              schema: { $ref: '#/components/schemas/User' }
          headers:
            Location: { schema: { type: string } }
  /v1/users/{userId}:
    get:
      operationId: getUser
      tags: [Users]
      parameters:
        - name: userId
          in: path
          required: true
          schema: { type: string }
      responses:
        200:
          description: User found
          content:
            application/json:
              schema: { $ref: '#/components/schemas/User' }
        404:
          description: User not found
    patch:
      operationId: updateUser
      tags: [Users]
      parameters:
        - name: userId
          in: path
          required: true
          schema: { type: string }
      requestBody:
        content:
          application/json:
            schema: { $ref: '#/components/schemas/UserUpdate' }
      responses:
        200:
          description: Updated user
    delete:
      operationId: deleteUser
      tags: [Users]
      parameters:
        - name: userId
          in: path
          required: true
          schema: { type: string }
      responses:
        204:
          description: Deleted
  /v1/users/{userId}/orders:
    get:
      operationId: listUserOrders
      tags: [Orders]
      parameters:
        - name: userId
          in: path
          required: true
          schema: { type: string }
        - name: status
          in: query
          schema: { type: string, enum: [pending, paid, shipped, cancelled] }
        - name: sort
          in: query
          schema: { type: string, enum: [createdAt_asc, createdAt_desc, total_asc, total_desc] }
        - name: page
          in: query
          schema: { type: integer, default: 1 }
        - name: size
          in: query
          schema: { type: integer, default: 20 }
      responses:
        200:
          description: Paginated list of orders
          content:
            application/json:
              schema:
                type: object
                properties:
                  data: { type: array, items: { $ref: '#/components/schemas/Order' } }
                  page: { type: integer }
                  size: { type: integer }
                  total: { type: integer }
                  totalPages: { type: integer }
    post:
      operationId: createOrder
      tags: [Orders]
      parameters:
        - name: userId
          in: path
          required: true
          schema: { type: string }
      requestBody:
        content:
          application/json:
            schema: { $ref: '#/components/schemas/OrderCreate' }
      responses:
        201:
          description: Created order
          headers:
            Location: { schema: { type: string } }
components:
  schemas:
    User:
      type: object
      properties:
        id: { type: string }
        email: { type: string, format: email }
        name: { type: string }
        role: { type: string, enum: [admin, customer] }
        createdAt: { type: string, format: date-time }
    UserCreate:
      type: object
      required: [email, name]
      properties:
        email: { type: string, format: email }
        name: { type: string }
        role: { type: string, enum: [admin, customer], default: customer }
    UserUpdate:
      type: object
      properties:
        name: { type: string }
        role: { type: string, enum: [admin, customer] }
    Order:
      type: object
      properties:
        id: { type: string }
        userId: { type: string }
        status: { type: string, enum: [pending, paid, shipped, cancelled] }
        total: { type: number }
        items:
          type: array
          items:
            type: object
            properties:
              productId: { type: string }
              productName: { type: string }
              quantity: { type: integer }
              unitPrice: { type: number }
        createdAt: { type: string, format: date-time }
    OrderCreate:
      type: object
      required: [items]
      properties:
        items:
          type: array
          items:
            type: object
            properties:
              productId: { type: string }
              quantity: { type: integer, minimum: 1 }
```

---

## 10. Code Snippets

### 10.1 Cursor Pagination (TypeScript + PostgreSQL)

```typescript
import { Pool } from 'pg';
const pool = new Pool({ connectionString: process.env.DATABASE_URL });
interface CursorPayload { c: string; id: number; }
function encodeCursor(p: CursorPayload): string {
  return Buffer.from(JSON.stringify(p)).toString('base64url');
}
function decodeCursor(cursor: string): CursorPayload {
  return JSON.parse(Buffer.from(cursor, 'base64url').toString('utf-8'));
}
export async function listUsersCursor(
  limit: number,
  cursor?: string
): Promise<{ data: any[]; nextCursor: string | null; hasMore: boolean }> {
  const safeLimit = Math.min(Math.max(limit, 1), 100);
  const args: any[] = [safeLimit + 1];
  let whereClause = '';
  if (cursor) {
    const { c, id } = decodeCursor(cursor);
    args.push(c, id);
    whereClause = 'WHERE (created_at, id) < ($2, $3)';
  }
  const sql = `
    SELECT id, email, name, role, created_at
    FROM users
    ${whereClause}
    ORDER BY created_at DESC, id DESC
    LIMIT $1
  `;
  const rows = await pool.query(sql, args);
  const hasMore = rows.length > safeLimit;
  const data = hasMore ? rows.slice(0, -1) : rows;
  const nextCursor = hasMore && data.length > 0
    ? encodeCursor({ c: data[data.length - 1].created_at.toISOString(), id: data[data.length - 1].id })
    : null;
  return { data, nextCursor, hasMore };
}
```

### 10.2 Offset Pagination

```typescript
export interface OffsetPage<T> {
  data: T[]; page: number; size: number;
  total: number; totalPages: number;
}
export async function paginateOffset<T>(
  query: (offset: number, limit: number) => Promise<T[]>,
  countQuery: () => Promise<number>,
  page: number, size: number
): Promise<OffsetPage<T>> {
  const safePage = Math.max(page, 1);
  const safeSize = Math.min(Math.max(size, 1), 100);
  const offset = (safePage - 1) * safeSize;
  const [data, total] = await Promise.all([
    query(offset, safeSize), countQuery(),
  ]);
  return { data, page: safePage, size: safeSize, total, totalPages: Math.ceil(total / safeSize) };
}
// Usage:
// const result = await paginateOffset(
//   (offset, limit) => db.orders.findMany({ skip: offset, take: limit }),
//   () => db.orders.count(),
//   Number(req.query.page) || 1,
//   Number(req.query.size) || 20
// );
```

### 10.3 Error Middleware

```typescript
import { Request, Response, NextFunction } from 'express';
export class ApiError extends Error {
  constructor(
    public statusCode: number,
    public code: string,
    message: string,
    public details?: any
  ) {
    super(message);
    this.name = 'ApiError';
  }
}
export function errorHandler(
  err: Error, req: Request, res: Response, _next: NextFunction
) {
  const requestId = (req as any).requestId || 'unknown';
  if (err instanceof ApiError) {
    res.status(err.statusCode).json({
      error: err.message, code: err.code,
      details: err.details, requestId,
    });
    return;
  }
  console.error(`[${requestId}] Unexpected error:`, err);
  res.status(500).json({ error: 'Internal Server Error', code: 'INTERNAL_ERROR', requestId });
}
```

### 10.4 API Route Handler

```typescript
import { Router, Request, Response, NextFunction } from 'express';
import { ApiError } from '../middleware/errorHandler';
import { listUsersCursor } from '../models/user';
const router = Router();
router.get('/v1/users', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const limit = Number(req.query.limit) || 20;
    const cursor = typeof req.query.cursor === 'string' ? req.query.cursor : undefined;
    const result = await listUsersCursor(limit, cursor);
    res.json(result);
  } catch (err) { next(err); }
});
router.get('/v1/users/:userId', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const user = await db.users.findById(req.params.userId);
    if (!user) throw new ApiError(404, 'USER_NOT_FOUND', 'User not found');
    res.json(user);
  } catch (err) { next(err); }
});
router.post('/v1/users', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { email, name } = req.body;
    if (!email || !name) {
      throw new ApiError(400, 'VALIDATION_ERROR', 'Missing required fields', {
        fields: ['email', 'name'],
      });
    }
    const user = await db.users.create({ email, name });
    res.status(201).location(`/v1/users/${user.id}`).json(user);
  } catch (err) { next(err); }
});
export default router;
```

### 10.5 Rate Limit Headers

```typescript
import { Request, Response, NextFunction } from 'express';
interface RateLimitInfo { limit: number; remaining: number; resetAt: Date; }
export function rateLimitHeaders(getLimit: (req: Request) => Promise<RateLimitInfo>) {
  return async (req: Request, res: Response, next: NextFunction) => {
    const info = await getLimit(req);
    res.setHeader('X-RateLimit-Limit', String(info.limit));
    res.setHeader('X-RateLimit-Remaining', String(info.remaining));
    res.setHeader('X-RateLimit-Reset', String(Math.floor(info.resetAt.getTime() / 1000)));
    if (info.remaining < 0) {
      const retryAfter = Math.ceil((info.resetAt.getTime() - Date.now()) / 1000);
      res.setHeader('Retry-After', String(retryAfter));
      return res.status(429).json({
        error: 'Too Many Requests', code: 'RATE_LIMIT_EXCEEDED',
        requestId: (req as any).requestId,
      });
    }
    next();
  };
}
// Token bucket (in-memory; use Redis in production)
class TokenBucket {
  private tokens: number;
  private lastRefill: number;
  constructor(private capacity: number, private refillRatePerSec: number) {
    this.tokens = capacity;
    this.lastRefill = Date.now();
  }
  consume(): { allowed: boolean; remaining: number; resetAt: Date } {
    const now = Date.now();
    const elapsed = (now - this.lastRefill) / 1000;
    this.tokens = Math.min(this.capacity, this.tokens + elapsed * this.refillRatePerSec);
    this.lastRefill = now;
    const allowed = this.tokens >= 1;
    if (allowed) this.tokens -= 1;
    const resetIn = Math.ceil((1 - this.tokens) / this.refillRatePerSec);
    return { allowed, remaining: Math.floor(this.tokens), resetAt: new Date(now + resetIn * 1000) };
  }
}
```

### 10.6 SSE Endpoint

```typescript
import { Router, Request, Response } from 'express';
const router = Router();
router.get('/v1/events', (req: Request, res: Response) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();
  const sendEvent = (data: any) => res.write(`data: ${JSON.stringify(data)}\n\n`);
  const heartbeat = setInterval(() => res.write(': heartbeat\n\n'), 30000);
  const listener = (event: any) => sendEvent(event);
  globalEventEmitter.on('notification', listener);
  req.on('close', () => {
    clearInterval(heartbeat);
    globalEventEmitter.off('notification', listener);
  });
});
// Client: const es = new EventSource('/v1/events');
// es.onmessage = (e) => console.log(JSON.parse(e.data));
export default router;
```

### 10.7 WebSocket Handler

```typescript
import { WebSocketServer, WebSocket } from 'ws';
import { verifyToken } from '../auth/jwt';
interface AuthenticatedSocket extends WebSocket { userId?: string; isAlive?: boolean; }
export function createWSS(port: number) {
  const wss = new WebSocketServer({ port });
  wss.on('connection', (ws: AuthenticatedSocket, req) => {
    const token = new URL(req.url ?? '', 'http://localhost').searchParams.get('token');
    try {
      const payload = verifyToken(token || '');
      ws.userId = payload.sub;
      ws.isAlive = true;
    } catch { ws.close(1008, 'Invalid token'); return; }
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('message', (raw) => {
      try { handleMessage(ws, JSON.parse(raw.toString())); }
      catch { ws.send(JSON.stringify({ error: 'Invalid JSON' })); }
    });
  });
  const heartbeat = setInterval(() => {
    wss.clients.forEach((ws: AuthenticatedSocket) => {
      if (!ws.isAlive) { ws.terminate(); return; }
      ws.isAlive = false;
      ws.ping();
    });
  }, 30000);
  wss.on('close', () => clearInterval(heartbeat));
  return wss;
}
function handleMessage(ws: AuthenticatedSocket, message: any) {
  switch (message.type) {
    case 'ping': ws.send(JSON.stringify({ type: 'pong' })); break;
    case 'subscribe': /* add to room set */ break;
    default: ws.send(JSON.stringify({ error: 'Unknown message type' }));
  }
}
```

### 10.8 GraphQL Resolver Example

```typescript
import { GraphQLError } from 'graphql';
export const resolvers = {
  Query: {
    async user(_parent: any, args: { id: string }, ctx: { db: any; userId?: string }) {
      if (!ctx.userId) throw new GraphQLError('Unauthorized', { extensions: { code: 'UNAUTHORIZED' } });
      const user = await ctx.db.users.findById(args.id);
      if (!user) throw new GraphQLError('User not found', { extensions: { code: 'USER_NOT_FOUND' } });
      return user;
    },
    async users(_parent: any, args: { cursor?: string; limit?: number }, ctx: { db: any }) {
      const limit = Math.min(args.limit ?? 20, 100);
      const rows = await ctx.db.users.listCursor({ cursor: args.cursor, limit: limit + 1 });
      const hasMore = rows.length > limit;
      const data = hasMore ? rows.slice(0, -1) : rows;
      return {
        edges: data.map((u: any) => ({ node: u, cursor: encodeCursor(u) })),
        pageInfo: { hasNextPage: hasMore, endCursor: hasMore ? encodeCursor(data[data.length - 1]) : null },
      };
    },
  },
  Mutation: {
    async createUser(_parent: any, args: { input: { email: string; name: string } }, ctx: { db: any }) {
      const { email, name } = args.input;
      if (!email || !name) {
        throw new GraphQLError('Validation failed', {
          extensions: { code: 'VALIDATION_ERROR', details: { fields: ['email', 'name'] } },
        });
      }
      try { return await ctx.db.users.create({ email, name }); }
      catch (err: any) {
        if (err.code === '23505') throw new GraphQLError('Email already exists', { extensions: { code: 'CONFLICT' } });
        throw new GraphQLError('Internal error', { extensions: { code: 'INTERNAL_ERROR' } });
      }
    },
  },
};
function encodeCursor(user: any): string {
  return Buffer.from(JSON.stringify({ id: user.id, c: user.createdAt })).toString('base64url');
}
```