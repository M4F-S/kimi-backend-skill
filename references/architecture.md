---
title: Backend Architecture Patterns Reference
skill: kimi-backend
---

# Architecture Patterns Reference

## Table of Contents

- [Architecture Patterns Overview](#architecture-patterns-overview)
- [Decision Matrix](#decision-matrix)
- [Trade-off Table](#trade-off-table)
- [Common Pitfalls](#common-pitfalls)
- [Modular Monolith Pattern](#modular-monolith-pattern)
- [Migration Path](#migration-path)
- [Serverless Patterns](#serverless-patterns)
- [Event-Driven Architecture](#event-driven-architecture)
- [Code Examples](#code-examples)

---

## Architecture Patterns Overview

### Monolith
All code in a single deployable unit. One database, one codebase, one artifact.

**Use when:** Team 1–5, product-market fit unknown, rapid iteration needed.
**Trade-offs:** Fastest dev velocity; simplest deployment. Tight coupling grows over time; no independent scaling.

### Modular Monolith
Monolith with strict internal boundaries. Modules communicate only through public APIs. One DB, but no cross-module direct access.

**Use when:** Team 5–40, need autonomy without ops overhead, want to defer microservices decision.
**Trade-offs:** Near-monolith velocity with better isolation. Can extract later. Requires discipline.

### Microservices
Independent deployable services, each with own data. Network communication via HTTP/gRPC/event bus.

**Use when:** Team 40+, clear domain boundaries, polyglot needs, independent deployability.
**Trade-offs:** Best fault isolation and scaling. Highest operational complexity. Distributed debugging overhead.

### Serverless (FaaS + Managed)
Functions as deployable units, triggered by events. No server management.

**Use when:** Variable traffic, event-driven, short tasks (< 15 min), no DevOps capacity.
**Trade-offs:** Zero ops overhead. Cold start latency, vendor lock-in, execution limits, harder local debugging.

---

## Decision Matrix

| Team Size | Architecture | Guidance | Extract Signal |
|-----------|-------------|----------|----------------|
| **1–5** | Monolith | Velocity over scale. Build domain first. | — |
| **5–15** | Modular Monolith | Enforce boundaries. One DB, typed APIs only. | Independent scaling need for one module |
| **15–40** | Modular Monolith + async services | Keep core monolith. Extract stateless workers. | Team autonomy blocked by deploy coupling |
| **40+** | Microservices | DDD per bounded context. Event bus for cross-service. | Teams need independent deploy cadence |

**Additional signals:**

| Signal | Action |
|--------|--------|
| One module needs 10x scale | Extract that module |
| Teams block on deploys | Split along team boundaries |
| Different runtime needed | Extract (e.g., Python for ML) |
| Data sovereignty requirements | Split by residency |
| Failure must not cascade | Extract + async + circuit breakers |

---

## Trade-off Table

| Pattern | Scalability | Dev Speed | Ops Complexity | Fault Isolation | Cost at Low Traffic |
|---------|-------------|-----------|----------------|-----------------|---------------------|
| Monolith | Scale whole app | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| Modular Monolith | Scale module | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Microservices | Scale service | ⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ |
| Serverless | Auto to zero | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

*5 = best in category.*

---

## Common Pitfalls

### 1. Distributed Monolith
20 services but every deploy requires 5 coordinated changes. All the pain of microservices, none of the isolation.

```typescript
// ❌ BAD: 3 sync calls = distributed monolith
class OrderService {
  async createOrder(data: CreateOrderDto) {
    const user = await userClient.get(data.userId);        // network
    const inv = await inventoryClient.reserve(data.items);  // network
    const pay = await paymentClient.charge(user.id, data.total); // network
    // Partial state if any fails
  }
}
// Fix: async events + idempotency. One writes, others react.
```

### 2. Premature Microservices
Splitting before domain is understood. Service boundaries churn every 2 sprints. **Fix:** Start modular monolith. Extract after 6+ months of stable boundaries.

### 3. Service-per-Feature
`UserService`, `UserProfileService`, `UserPreferenceService` — 3 chatty services for one domain.

```typescript
// ❌ BAD: 3 network hops to register one user
async function registerUser(data) {
  await userService.create(data);         // hop 1
  await userProfileService.create(data);  // hop 2
  await userPreferenceService.set(data);  // hop 3
}
// Fix: One service per bounded context: UserContext owns all three.
```

### 4. Shared Database Antipattern
Multiple services writing same tables. No schema ownership.

```typescript
// ❌ BAD: billing and shipping both write orders table
// billing-service.ts
await db.query("UPDATE orders SET status='paid' WHERE id=$1", [id]);
// shipping-service.ts
await db.query("UPDATE orders SET status='shipped' WHERE id=$1", [id]);
// Fix: DB per service. Changes via events.
```

### 5. Ignoring the Network
Treating service calls like function calls. No timeout, no retry, no circuit breaker.

```typescript
// ❌ BAD: hangs forever if inventory is slow
const result = await fetch('http://inventory-service/api/reserve');
// Cascade failure.
// Fix: timeout + retry + backoff + circuit breaker on every call.
```

---

## Modular Monolith Pattern

Structure code as services, deploy as one unit.

### Module Structure

```
src/modules/
├── users/
│   ├── domain/          # Entities, value objects
│   ├── application/     # Commands, queries, use cases
│   ├── infrastructure/  # DB repos, external clients
│   ├── api/             # Controllers, DTOs
│   └── index.ts         # PUBLIC API export ONLY
├── orders/
│   ├── domain/
│   ├── application/
│   ├── infrastructure/
│   ├── api/
│   └── index.ts
└── shared/
    ├── event-bus/
    ├── logger/
    └── config/
```

### Public API Enforcement

```typescript
// modules/users/index.ts
export { UserService } from './application/user.service';
export { UserRepository } from './application/user.repository.interface';
export type { UserDto } from './api/user.dto';
export type { UserCreatedEvent } from './domain/events';

// ❌ DO NOT export implementation details:
// export { UserEntity } from './domain/user.entity';       // internal
// export { PostgresUserRepo } from './infra/pg-repo';     // impl detail
// export { UserController } from './api/controller';          // HTTP layer
```

### CQRS Separation

```typescript
// modules/orders/application/commands/create-order.command.ts
export class CreateOrderCommand {
  constructor(readonly userId: string, readonly items: OrderItem[]) {}
}

export class CreateOrderHandler {
  constructor(
    private orderRepo: OrderRepository,
    private eventBus: EventBus,
  ) {}

  async execute(cmd: CreateOrderCommand): Promise<string> {
    const order = Order.create(cmd.userId, cmd.items);
    await this.orderRepo.save(order);
    this.eventBus.publish(new OrderCreatedEvent(order.id, order.userId));
    return order.id;
  }
}

// modules/orders/application/queries/get-order.query.ts
export class GetOrderQuery {
  constructor(readonly orderId: string) {}
}

export class GetOrderHandler {
  constructor(private queryDb: QueryDatabase) {}

  async execute(query: GetOrderQuery): Promise<OrderDto | null> {
    // Reads optimized: different DB, projections, cache
    return this.queryDb.orders.findById(query.orderId);
  }
}
```

### Module Registration (NestJS-style)

```typescript
import { Module } from '@nestjs/common';
import { OrdersController } from './api/orders.controller';
import { CreateOrderHandler } from './application/commands/create-order.handler';
import { GetOrderHandler } from './application/queries/get-order.handler';
import { PostgresOrderRepository } from './infra/postgres-order.repository';
import { ORDER_REPOSITORY } from './application/order.repository.interface';

@Module({
  controllers: [OrdersController],
  providers: [
    CreateOrderHandler,
    GetOrderHandler,
    { provide: ORDER_REPOSITORY, useClass: PostgresOrderRepository },
  ],
  exports: [CreateOrderHandler, GetOrderHandler],
})
export class OrdersModule {}
```

---

## Migration Path

### Phase 1: Monolith → Modular Monolith
1. Identify bounded contexts.
2. Move code into `modules/<name>/`.
3. Define public APIs (typed interfaces only).
4. Add in-process event bus for module communication.
5. Enforce boundaries with lint rules.

**Time:** 2–4 sprints. **Checkpoint:** Can deploy without touching >2 modules per feature?

### Phase 2: Modular Monolith → Async Services
Extract stateless/high-scale modules first: image processing, ML inference, notifications, search indexing.
Keep in monolith: core domain, transaction-heavy workflows, tight consistency data.

**Pattern:** Monolith publishes event → extracted service consumes → publishes result → monolith updates read model.

### Phase 3: Async Services → Full Microservices
Extract core bounded contexts with their own data after 6+ months of stability.

**Extraction steps:**
1. New service + own DB.
2. Dual-write: monolith writes old + new DB.
3. Backfill new DB.
4. Monolith reads from new DB, falls back to old.
5. Remove old table.
6. Replace in-process calls with network + events.

**Rule:** Never extract two modules at once.

---

## Serverless Patterns

### When to Use / When NOT to Use

| Use | Pattern | Example |
|-----|---------|---------|
| Variable traffic | FaaS auto-scale | Flash sales |
| Event-driven | Queue-triggered | Webhook processing |
| Scheduled | Cron-triggered | Nightly reports |
| Edge logic | Edge worker | Geo-routing |

| Do NOT Use | Why | Alternative |
|-------------|-----|-------------|
| Long-running (>15 min) | Execution limits | Containers |
| Stateful sessions | No local state | Containers + Redis |
| Cold-start sensitive | Latency | Provisioned concurrency or containers |
| Complex debugging | Hard to replicate | Local containers |

### FaaS Handler Pattern

```typescript
import { z } from 'zod';

const WebhookPayload = z.object({
  event: z.enum(['payment.success', 'payment.failed']),
  data: z.object({ id: z.string(), amount: z.number() }),
});

export default async function handler(req: Request): Promise<Response> {
  const body = await req.json();
  const result = WebhookPayload.safeParse(body);
  if (!result.success) {
    return new Response(JSON.stringify({ error: 'Invalid' }), { status: 400 });
  }

  const { data } = result.data;
  const processed = await db.findWebhookLog(data.id);
  if (processed) {
    return new Response(JSON.stringify({ status: 'already processed' }), { status: 200 });
  }

  await processEvent(data);
  await db.logWebhook(data.id);
  return new Response(JSON.stringify({ status: 'ok' }), { status: 200 });
}
```

### Cold Start Mitigation

```typescript
// Lazy import heavy SDKs
export default async function handler(req: Request) {
  const { heavy } = await import('heavy-sdk'); // only when invoked
}

// Keep warm: ping every 5 min
// Use lightweight runtimes (Hono, not Express)
// Connection pooling (pg-pool, not new Client per request)
```

---

## Event-Driven Architecture

### Event Sourcing Basics
Store events (append-only), derive state by replaying. Current state = fold(events).

```typescript
interface DomainEvent {
  id: string; aggregateId: string; type: string;
  payload: unknown; occurredAt: Date; version: number;
}

class Order {
  private status = 'pending';

  apply(event: DomainEvent) {
    if (event.type === 'OrderCreated') this.status = 'pending';
    if (event.type === 'OrderPaid') this.status = 'paid';
  }

  static rehydrate(stream: DomainEvent[]): Order {
    const o = new Order();
    stream.forEach(e => o.apply(e));
    return o;
  }
}
```

**Use for:** Audit trails, financial ledgers. **Avoid for:** Simple CRUD (complexity cost).

### CQRS
Separate write model (normalized, transactional) from read model (denormalized, fast).

```typescript
// Command side
class PlaceOrderHandler {
  async execute(cmd: PlaceOrderCommand) {
    const order = Order.create(cmd);
    await this.orderRepo.save(order);
    await this.eventBus.publish(new OrderPlacedEvent(order));
  }
}

// Projection side
class OrderProjectionHandler {
  async onOrderPlaced(event: OrderPlacedEvent) {
    await this.readDb.orderViews.insert({
      id: event.orderId,
      customerName: event.customerName, // denormalized
      total: event.total,
      status: 'pending',
    });
  }
}

// Query side
class GetOrderSummaryHandler {
  async execute(orderId: string): Promise<OrderSummary> {
    return this.readDb.orderViews.findById(orderId); // no joins
  }
}
```

### Saga Pattern (Distributed Transactions)
Sequence of local transactions with compensating actions on failure.

```typescript
// Orchestration: central coordinator
class OrderSaga {
  async execute(orderId: string) {
    try {
      await this.inventory.reserve(orderId);
      await this.payment.charge(orderId);
      await this.shipping.create(orderId);
      await this.order.confirm(orderId);
    } catch {
      await this.shipping.cancel(orderId);
      await this.payment.refund(orderId);
      await this.inventory.release(orderId);
      await this.order.cancel(orderId);
    }
  }
}

// Choreography: event-driven, no coordinator
// OrderCreated -> Inventory reserves -> ReserveSuccess -> Payment charges -> PaymentSuccess -> Shipping creates
// Each service handles its own compensation on failure
```

**Orchestration:** Complex flows, strict ordering, need visibility. **Choreography:** Simple linear, loose coupling.

### Outbox Pattern
Guarantee DB write + event publish are atomic.

```typescript
// ❌ BAD: DB commits, event publish fails
await db.transaction(async (trx) => { await trx.orders.insert(order); });
await eventBus.publish(new OrderCreatedEvent(order)); // may fail!

// ✅ GOOD: Outbox
await db.transaction(async (trx) => {
  await trx.orders.insert(order);
  await trx.outbox.insert({
    type: 'OrderCreated',
    payload: JSON.stringify(order),
    occurredAt: new Date(),
  }); // same transaction = atomic
});

// Relay worker polls outbox, publishes, deletes
class OutboxRelay {
  async run() {
    const events = await db.outbox.poll(100);
    for (const e of events) {
      await eventBus.publish(e);
      await db.outbox.delete(e.id); // idempotent consumers handle duplicates
    }
  }
}
```

---

## Code Examples

### 1. In-Process Event Bus

```typescript
// shared/event-bus.ts
interface EventHandler<T> { (event: T): Promise<void> | void; }

export class EventBus {
  private handlers = new Map<string, Set<EventHandler<unknown>>>();

  on<T>(eventType: string, handler: EventHandler<T>): () => void {
    if (!this.handlers.has(eventType)) this.handlers.set(eventType, new Set());
    this.handlers.get(eventType)!.add(handler as EventHandler<unknown>);
    return () => this.handlers.get(eventType)?.delete(handler as EventHandler<unknown>);
  }

  async publish<T>(event: T & { type: string }): Promise<void> {
    const handlers = this.handlers.get(event.type);
    if (!handlers) return;
    await Promise.all(Array.from(handlers).map(h =>
      h(event).catch(err => console.error(`Event ${event.type} error:`, err))
    ));
  }
}

// Usage
const bus = new EventBus();
bus.on<OrderCreatedEvent>('OrderCreated', async (e) => {
  await notificationService.sendToUser(e.userId, 'Order confirmed');
});
await bus.publish({ type: 'OrderCreated', orderId: '123', userId: '456' });
```

### 2. Repository Interface Boundary

```typescript
// modules/users/application/user.repository.interface.ts
export const USER_REPOSITORY = Symbol('USER_REPOSITORY');

export interface UserRepository {
  findById(id: string): Promise<User | null>;
  findByEmail(email: string): Promise<User | null>;
  save(user: User): Promise<void>;
}

// modules/users/infra/postgres-user.repository.ts
export class PostgresUserRepository implements UserRepository {
  constructor(private db: Database) {}

  async findById(id: string): Promise<User | null> {
    const row = await this.db.query('SELECT * FROM users WHERE id = $1', [id]);
    return row ? new User(row.id, row.email, row.name) : null;
  }

  async findByEmail(email: string): Promise<User | null> {
    const row = await this.db.query('SELECT * FROM users WHERE email = $1', [email]);
    return row ? new User(row.id, row.email, row.name) : null;
  }

  async save(user: User): Promise<void> {
    await this.db.query(
      `INSERT INTO users (id, email, name) VALUES ($1,$2,$3)
       ON CONFLICT (id) DO UPDATE SET email=$2, name=$3`,
      [user.id, user.email, user.name]
    );
  }
}
```

### 3. Circuit Breaker

```typescript
export class CircuitBreaker {
  private state: 'CLOSED' | 'OPEN' | 'HALF_OPEN' = 'CLOSED';
  private failures = 0;
  private lastFailureTime?: number;

  constructor(private threshold = 5, private timeoutMs = 30000) {}

  async execute<T>(fn: () => Promise<T>): Promise<T> {
    if (this.state === 'OPEN') {
      if (Date.now() - (this.lastFailureTime || 0) > this.timeoutMs) {
        this.state = 'HALF_OPEN';
      } else {
        throw new Error('Circuit breaker OPEN');
      }
    }
    try {
      const result = await fn();
      this.onSuccess();
      return result;
    } catch (error) {
      this.onFailure();
      throw error;
    }
  }

  private onSuccess() { this.failures = 0; this.state = 'CLOSED'; }
  private onFailure() {
    this.failures++; this.lastFailureTime = Date.now();
    if (this.failures >= this.threshold) this.state = 'OPEN';
  }
}

// Usage
const breaker = new CircuitBreaker(5, 30000);
const user = await breaker.execute(() =>
  fetch('https://user-service/api/users/123').then(r => r.json())
);
```

### 4. Module Boundary Lint Script

```typescript
// scripts/enforce-boundaries.ts
import * as fs from 'fs';
import * as path from 'path';

const MODULES_DIR = 'src/modules';
const modules = fs.readdirSync(MODULES_DIR).filter(f =>
  fs.statSync(path.join(MODULES_DIR, f)).isDirectory()
);

const violations: string[] = [];
for (const mod of modules) {
  const dir = path.join(MODULES_DIR, mod);
  const files = fs.readdirSync(dir, { recursive: true }) as string[];
  for (const file of files.filter(f => f.endsWith('.ts'))) {
    const content = fs.readFileSync(path.join(dir, file), 'utf-8');
    const imports = content.matchAll(/from ['"](.*)['"];?/g);
    for (const m of imports) {
      const p = m[1];
      for (const other of modules) {
        if (other !== mod && new RegExp(`modules/${other}/(?!index)`).test(p)) {
          violations.push(`${path.join(mod, file)} imports internals of ${other}: "${p}"`);
        }
      }
    }
  }
}

if (violations.length) {
  console.error('Boundary violations:\n' + violations.join('\n'));
  process.exit(1);
} else {
  console.log('✅ All boundaries respected.');
}
```

### 5. Idempotent Handler

```typescript
export class IdempotentHandler {
  constructor(private redis: RedisClient) {}

  async execute<T>(
    opts: { idempotencyKey: string; ttlSeconds?: number },
    fn: () => Promise<T>,
  ): Promise<T> {
    const key = `idempotency:${opts.idempotencyKey}`;
    const existing = await this.redis.get(key);
    if (existing === 'PROCESSING') throw new Error('In progress');
    if (existing === 'COMPLETED') throw new Error('Already completed');

    await this.redis.setex(key, opts.ttlSeconds || 86400, 'PROCESSING');
    try {
      const result = await fn();
      await this.redis.setex(key, opts.ttlSeconds || 86400, 'COMPLETED');
      return result;
    } catch (error) {
      await this.redis.del(key); // allow retry
      throw error;
    }
  }
}

// Usage
await new IdempotentHandler(redis).execute(
  { idempotencyKey: `stripe:${event.id}` },
  async () => { await processPayment(event); }
);
```

---

## Summary Checklist

- [ ] Team size mapped to architecture
- [ ] Trade-offs reviewed for constraints
- [ ] No distributed monolith signals
- [ ] Module boundaries enforced (lint + review)
- [ ] Outbox pattern for DB + event consistency
- [ ] Circuit breakers on all cross-service calls
- [ ] Idempotency on event handlers and webhooks
- [ ] Serverless only for short, stateless, variable workloads
- [ ] Migration path planned: monolith → modular → services
- [ ] Event-driven patterns understood before implementing
