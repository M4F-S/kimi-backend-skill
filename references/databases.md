# Database Design & Operations Reference

> Production-ready patterns for data layers in web applications, APIs, and microservices.

## Table of Contents

1. [SQL vs NoSQL Decision Matrix](#1-sql-vs-nosql-decision-matrix)
2. [Schema Design Principles](#2-schema-design-principles)
3. [ORM Comparison](#3-orm-comparison)
4. [Connection Pooling](#4-connection-pooling)
5. [Migrations](#5-migrations)
6. [Read Replicas](#6-read-replicas)
7. [Caching Patterns](#7-caching-patterns)
8. [Query Optimization](#8-query-optimization)
9. [Database Design Examples](#9-database-design-examples)
10. [Code Snippets](#10-code-snippets)

---

## 1. SQL vs NoSQL Decision Matrix

| Factor | PostgreSQL | MongoDB |
|---|---|---|
| Data shape | Relational, structured, multi-table joins | Document-oriented, nested, flexible |
| Schema | Strict (DDL) | Flexible (schema-on-read) |
| Complex queries | Excellent (CTEs, window functions, JOINs) | Limited (aggregation pipeline) |
| Transactions | Full ACID (MVCC) | Multi-document ACID since 4.0 |
| Horizontal scaling | Read replicas, logical partitioning (Citus) | Native sharding |
| Full-text search | tsvector + GIN | Basic `$text` |
| Geospatial | PostGIS (industry standard) | Basic 2D indexes |
| JSON support | JSONB (indexed, queryable) | Native document format |

### When to Use PostgreSQL

- Relational data with complex queries, reports, analytics.
- Strong consistency (financial, inventory, healthcare).
- Need CTEs, window functions, row-level security.
- JSONB for *occasional* flexibility within a relational model.

### When to Use MongoDB

- Rapid prototyping with evolving schemas.
- Document-centric workloads (CMS, catalogs).
- True horizontal write scaling via sharding.
- Data naturally fits nested documents (orders with line items).

### JSONB in PostgreSQL

Use JSONB for selective flexibility: per-tenant settings, feature flags, heterogeneous metadata, product attributes by category.

```sql
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    base_price DECIMAL(10,2) NOT NULL,
    attributes JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_products_attrs ON products USING GIN (attributes);
SELECT * FROM products WHERE attributes @> '{"color": "red"}';
```

**Default rule:** Start with PostgreSQL. Move to MongoDB only when operational or query complexity proves it necessary.

---

## 2. Schema Design Principles

### Normalization

Apply 3NF as baseline: atomic values (1NF), no partial dependencies (2NF), no transitive dependencies (3NF). Normalize to need, not dogma.

### Foreign Keys

Always use foreign keys in transactional systems:

```sql
CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    total_amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);
```

### When to Denormalize

| Scenario | Approach |
|---|---|
| Read-heavy aggregates | Materialized views or computed columns |
| Hot-path reads | Redundant columns via triggers or application |
| Search indexing | Denormalized search tables (e.g., Elasticsearch) |
| Reporting | Star schema / data warehouse (not OLTP) |

Maintain denormalized data via: database triggers, application updates, or CDC (Debezium → event consumers).

### Indexing Strategy

| Index Type | Use Case |
|---|---|
| B-tree (default) | Equality, range, ordering |
| GIN | JSONB, full-text search, array containment |
| GiST | Geospatial, nearest-neighbor |
| BRIN | Very large, naturally ordered tables (time-series) |

```sql
-- Composite index
CREATE INDEX idx_orders_user_created ON orders(user_id, created_at DESC);

-- Partial index (only active records)
CREATE INDEX idx_active_users ON users(email) WHERE deleted_at IS NULL;

-- Covering index
CREATE INDEX idx_orders_covering ON orders(user_id, status, created_at) INCLUDE (total_amount);
```

**Rules:** Index `WHERE`, `JOIN`, `ORDER BY`, `GROUP BY`. Avoid low-cardinality indexes unless partial. More indexes slow writes — measure with `EXPLAIN ANALYZE`.

---

## 3. ORM Comparison

| ORM | Language | Philosophy | Best For | Trade-offs |
|---|---|---|---|---|
| **Prisma** | TS | Schema-first, declarative | Rapid API dev, Next.js, full-stack TS | Heavy runtime, migration limitations |
| **Drizzle** | TS | SQL-first, lightweight | Performance-critical, edge workers, SQL lovers | Smaller ecosystem, newer |
| **TypeORM** | TS | Decorator-driven, Active Record/Data Mapper | Enterprise TS, complex domains | Verbose, maintenance concerns |
| **SQLAlchemy** | Python | Data Mapper, expressive | Complex Python backends, data pipelines | Steeper learning curve |
| **Django ORM** | Python | Active Record, batteries-included | Django projects, admin, rapid prototyping | Tightly coupled to Django |

### 2025/2026 Updates

- **Prisma 7.0**: Rust rewrite, improved JSONB, native DB features via `db pull`.
- **Drizzle**: Multi-project schema management, edge runtime compatibility, expanded adapters.
- **TypeORM**: Community maintenance mode; prefer Prisma or Drizzle for new projects.
- **SQLAlchemy 2.0**: Unified syntax, `asyncio` support, improved type hints.

### Recommendation

| Context | Recommended ORM |
|---|---|
| New TypeScript API (2025+) | Drizzle or Prisma |
| Existing TypeORM | Migrate to Drizzle incrementally |
| Python FastAPI / Flask | SQLAlchemy 2.0 + Alembic |
| Python Django | Django ORM |
| Edge / serverless | Drizzle or raw SQL |

---

## 4. Connection Pooling

Database connections are expensive. Always connect through a pool.

### PgBouncer (PostgreSQL)

```ini
[databases]
mydb = host=postgres.internal port=5432 dbname=mydb

[pgbouncer]
listen_port = 6432
pool_mode = transaction        ; transaction-level pooling (recommended for ORMs)
max_client_conn = 10000
default_pool_size = 25
reserve_pool_size = 5
server_lifetime = 3600
```

**Pool modes:** Session (safest), Transaction (best for ORMs), Statement (risky, fastest).

### Prisma Accelerate

Managed connection pool for serverless. Use with Vercel, Lambda, Cloudflare Workers.

```typescript
import { PrismaClient } from '@prisma/client/edge'
import { withAccelerate } from '@prisma/extension-accelerate'

const prisma = new PrismaClient()
  .$extends(withAccelerate({ cacheStrategy: { ttl: 60 } }))
```

### Pool Sizing Formula

```
connections = ((core_count * 2) + effective_spindle_count) / pool_count
```

| Database vCPUs | Max Connections | App Pool Size | PgBouncer Pool Size |
|---|---|---|---|
| 2 | 200 | 10 | 50 |
| 4 | 500 | 15 | 100 |
| 8 | 1000 | 20 | 200 |
| 16+ | 2000+ | 30 | 400 |

**Rule of thumb:** `pool_size = (max_connections * 0.7) / app_instance_count`

### Connection Leak Prevention

1. Always close connections in `finally` blocks or context managers.
2. Set timeouts: `connect_timeout`, `idle_in_transaction_session_timeout`, `statement_timeout`.
3. Monitor: alert on `max_connections` usage > 80% and `idle_in_transaction` count.
4. ORM configs: Prisma `connection_limit`, SQLAlchemy `pool_size`/`max_overflow`/`pool_recycle`, Django `CONN_MAX_AGE`.

---

## 5. Migrations

### Migration Strategies

| Strategy | How | Pros | Cons | Best For |
|---|---|---|---|---|
| **Incremental** | Apply sequentially | Simple, trackable, reversible | Long migrations lock tables | Most applications |
| **Blue-Green** | Deploy to green DB, switch traffic | Zero downtime, safe rollback | Complex, dual-write period | High-availability systems |
| **Expand/Contract** | Add column, migrate data, remove old | Non-breaking changes | Multiple deploys | Large tables, critical paths |

### Migration Tools

| Tool | Language | Best For |
|---|---|---|
| Prisma Migrate | TS | Prisma users; review SQL before applying |
| Drizzle Kit | TS | Drizzle users; SQL-first, lightweight |
| Alembic | Python | SQLAlchemy users; auto-generates from models |
| Flyway | Any | SQL-based, versioned, multi-language teams |
| Atlas | Any (Go) | Schema-as-code; HCL/JSON/YAML definitions |

### Rollback Procedures

1. Test migrations on production-like data in staging.
2. Back up before migrating (snapshot or logical dump).
3. Migrations should be backward-compatible for at least one deploy cycle.
4. Write `down` migration for every `up`. For data migrations, write reversible scripts.
5. For failed migrations: use `ROLLBACK` in transaction (if DDL is transactional). For non-transactional DDL, use blue-green deployment.

### Data Migration Patterns

```sql
-- Step 1: Add nullable column (fast, no lock)
ALTER TABLE users ADD COLUMN display_name TEXT;

-- Step 2: Backfill in batches
UPDATE users SET display_name = split_part(email, '@', 1)
WHERE id BETWEEN 1 AND 10000 AND display_name IS NULL;
-- Repeat in batches. Use pg_sleep between batches.

-- Step 3: Add constraint after backfill
ALTER TABLE users ALTER COLUMN display_name SET NOT NULL;
```

For large tables, use background jobs or CDC (Debezium) to backfill. Use `SELECT ... FOR UPDATE SKIP LOCKED` for concurrent workers.

---

## 6. Read Replicas

### Routing Pattern

- **Writes** (`INSERT`, `UPDATE`, `DELETE`) → primary.
- **Reads** (`SELECT`) → replicas, with exceptions for critical reads.
- **Transaction blocks** with writes → route entirely to primary.

### Replication Lag Handling

Replication lag: typically 1–100ms, can spike under load.

| Strategy | Implementation |
|---|---|
| **Session stickiness** | Track last write timestamp; route reads to primary for N ms after write. |
| **Critical read routing** | Flag reads that must be fresh; route to primary. |
| **Lag threshold** | Monitor replication lag; if > threshold, route to primary. |

### Read-After-Write Consistency

User creates a resource, then reloads — doesn't see it. Solution: sticky reads.

```typescript
const user = await prisma.user.create({ data: { email } });
readRouter.stickyForUser(user.id, 5000); // next 5s reads go to primary
const freshUser = await prisma.user.findUnique({ where: { id: user.id } });
```

---

## 7. Caching Patterns

### Cache-Aside (Most Common)

```
1. Check cache
2. If miss → read DB, write cache
3. If hit → return cached
On write: invalidate cache (don't write to cache)
```

### Write-Through

Write to DB and cache simultaneously. Cache always consistent, but write latency increases.

### Write-Back

Write to cache only; async flush to DB. Fastest writes, but data loss risk if cache fails. Use for high-write, acceptable-loss scenarios (analytics, counters with backup).

### Cache Stampede Prevention

Stampede: cached value expires, many concurrent requests hit DB simultaneously.

| Strategy | How |
|---|---|
| **Lock-based** | First request acquires lock; others wait or serve stale data. |
| **Probabilistic early expiration** | Each request has small chance to recompute before TTL expires. |
| **External recompute** | Background worker refreshes cache; requests never trigger DB load. |
| **Per-key jitter** | Randomize TTL per key to spread expiration times. |

### Redis Cache-Aside Implementation

```python
import redis, json, time
redis_client = redis.Redis(host='localhost', port=6379, decode_responses=True)

def get_user(user_id: str):
    cache_key = f"user:{user_id}"
    cached = redis_client.get(cache_key)
    if cached:
        return json.loads(cached)

    lock_key = f"lock:{cache_key}"
    if redis_client.set(lock_key, "1", nx=True, ex=10):
        try:
            user = db.query_one("SELECT * FROM users WHERE id = %s", (user_id,))
            redis_client.setex(cache_key, 300, json.dumps(user))
            return user
        finally:
            redis_client.delete(lock_key)
    else:
        time.sleep(0.1)
        return get_user(user_id)  # retry

def invalidate_user(user_id: str):
    redis_client.delete(f"user:{user_id}")
```

**TTL rules:** Sessions = 24h; product catalogs = 5–15m; config/feature flags = 1–60m with pub/sub invalidation; aggregates = 1–5m.

---

## 8. Query Optimization

### EXPLAIN ANALYZE

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT u.id, u.email, o.total_amount
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE u.created_at > '2024-01-01'
ORDER BY o.created_at DESC
LIMIT 20;
```

**Key fields:** `Seq Scan` vs `Index Scan` — avoid sequential scans on large tables. `Buffers: shared read` — high numbers = disk I/O, consider indexing. `Rows Removed by Filter` — many filtered rows = missing index.

### Index Usage Check

```sql
-- Missing indexes (sequential scans on large tables)
SELECT schemaname, tablename, seq_scan, seq_tup_read,
       seq_tup_read / NULLIF(seq_scan, 0) AS avg_tup_read
FROM pg_stat_user_tables
WHERE seq_scan > 0 AND seq_tup_read > 10000
ORDER BY seq_tup_read DESC;

-- Unused indexes
SELECT schemaname, tablename, indexrelname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan < 50 AND indexrelname NOT LIKE 'pg_toast%'
ORDER BY idx_scan ASC;
```

### N+1 Prevention

**Problem:** Fetch N users, then for each user fetch orders = 1 + N queries.

**Solutions:** JOIN, IN clause, or DataLoader pattern.

```sql
-- Bad: N+1
for user in users:
    orders = db.query("SELECT * FROM orders WHERE user_id = %s", (user.id,))

-- Good: Batch with IN
user_ids = [u.id for u in users]
orders = db.query("SELECT * FROM orders WHERE user_id = ANY(%s)", (user_ids,))
# Group by user_id in application code
```

---

## 9. Database Design Examples

### SaaS Platform Schema

```sql
-- Organizations (tenants)
CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    plan TEXT NOT NULL CHECK (plan IN ('free', 'starter', 'pro', 'enterprise')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'cancelled')),
    settings JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_organizations_slug ON organizations(slug);
CREATE INDEX idx_organizations_status ON organizations(status) WHERE status = 'active';

-- Users
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    display_name TEXT,
    avatar_url TEXT,
    email_verified_at TIMESTAMPTZ,
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    deleted_at TIMESTAMPTZ
);
CREATE INDEX idx_users_email ON users(email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_deleted_at ON users(deleted_at) WHERE deleted_at IS NULL;

-- Organization Memberships
CREATE TABLE organization_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
    invited_by UUID REFERENCES users(id),
    joined_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE (organization_id, user_id)
);
CREATE INDEX idx_members_org ON organization_members(organization_id);
CREATE INDEX idx_members_user ON organization_members(user_id);
CREATE INDEX idx_members_role ON organization_members(organization_id, role) WHERE role IN ('owner', 'admin');

-- Subscriptions
CREATE TABLE subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL UNIQUE REFERENCES organizations(id) ON DELETE CASCADE,
    stripe_subscription_id TEXT UNIQUE,
    stripe_customer_id TEXT,
    status TEXT NOT NULL DEFAULT 'trialing' CHECK (status IN ('trialing', 'active', 'past_due', 'cancelled', 'paused')),
    current_period_start TIMESTAMPTZ,
    current_period_end TIMESTAMPTZ,
    cancel_at_period_end BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_subscriptions_org ON subscriptions(organization_id);
CREATE INDEX idx_subscriptions_stripe ON subscriptions(stripe_subscription_id);
CREATE INDEX idx_subscriptions_period_end ON subscriptions(current_period_end) WHERE status = 'active';

-- Audit Logs
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    actor_type TEXT NOT NULL DEFAULT 'user' CHECK (actor_type IN ('user', 'system', 'api')),
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    metadata JSONB NOT NULL DEFAULT '{}',
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_audit_org ON audit_logs(organization_id);
CREATE INDEX idx_audit_created ON audit_logs(organization_id, created_at DESC);
CREATE INDEX idx_audit_action ON audit_logs(organization_id, action, resource_type);
CREATE INDEX idx_audit_brin ON audit_logs USING BRIN (created_at);

-- Row-Level Security (per-tenant isolation)
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_logs_org_isolation ON audit_logs
    USING (organization_id = current_setting('app.current_org_id')::UUID);
```

### Schema Design Checklist

- [ ] Primary key on every table (prefer UUID v7 for time-sortable IDs).
- [ ] Foreign keys with `ON DELETE` rules.
- [ ] `created_at` and `updated_at` on all entities.
- [ ] `deleted_at` for soft delete with partial index.
- [ ] Indexes covering `WHERE`, `JOIN`, `ORDER BY`, `UNIQUE`.
- [ ] `CHECK` constraints for business rules.
- [ ] `NOT NULL` on required fields.
- [ ] JSONB only for truly schemaless sub-structures.
- [ ] RLS enabled for multi-tenant tables.
- [ ] Audit table captures all mutations.

---

## 10. Code Snippets

### Snippet 1: Prisma Schema (SaaS)

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model Organization {
  id        String   @id @default(uuid())
  name      String
  slug      String   @unique
  plan      String   @default("free")
  status    String   @default("active")
  settings  Json     @default("{}")
  createdAt DateTime @default(now()) @map("created_at")
  updatedAt DateTime @updatedAt @map("updated_at")

  members      OrganizationMember[]
  subscription Subscription?
  auditLogs    AuditLog[]

  @@map("organizations")
}

model User {
  id            String    @id @default(uuid())
  email         String    @unique
  passwordHash  String    @map("password_hash")
  displayName   String?   @map("display_name")
  emailVerified DateTime? @map("email_verified_at")
  lastLoginAt   DateTime? @map("last_login_at")
  createdAt     DateTime  @default(now()) @map("created_at")
  updatedAt     DateTime  @updatedAt @map("updated_at")
  deletedAt     DateTime? @map("deleted_at")

  memberships OrganizationMember[]
  auditLogs   AuditLog[] @relation("actor")

  @@map("users")
}

model OrganizationMember {
  id             String   @id @default(uuid())
  organizationId String   @map("organization_id")
  userId         String   @map("user_id")
  role           String   @default("member")
  joinedAt       DateTime @default(now()) @map("joined_at")

  organization Organization @relation(fields: [organizationId], references: [id], onDelete: Cascade)
  user         User         @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@unique([organizationId, userId])
  @@map("organization_members")
}

model Subscription {
  id                   String    @id @default(uuid())
  organizationId       String    @unique @map("organization_id")
  stripeSubscriptionId String?   @unique @map("stripe_subscription_id")
  status               String    @default("trialing")
  currentPeriodEnd     DateTime? @map("current_period_end")

  organization Organization @relation(fields: [organizationId], references: [id], onDelete: Cascade)

  @@map("subscriptions")
}

model AuditLog {
  id             String   @id @default(uuid())
  organizationId String   @map("organization_id")
  actorId        String?  @map("actor_id")
  action         String
  resourceType   String   @map("resource_type")
  resourceId     String?  @map("resource_id")
  metadata       Json     @default("{}")
  createdAt      DateTime @default(now()) @map("created_at")

  organization Organization @relation(fields: [organizationId], references: [id], onDelete: Cascade)
  actor        User?        @relation("actor", fields: [actorId], references: [id], onDelete: SetNull)

  @@index([organizationId, createdAt])
  @@map("audit_logs")
}
```

### Snippet 2: SQLAlchemy Models (Python)

```python
from sqlalchemy import Column, String, DateTime, ForeignKey, UniqueConstraint, JSON, Text, Index, text
from sqlalchemy.orm import declarative_base, relationship
from sqlalchemy.dialects.postgresql import UUID
from datetime import datetime
import uuid

Base = declarative_base()

class Organization(Base):
    __tablename__ = "organizations"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(Text, nullable=False)
    slug = Column(Text, nullable=False, unique=True)
    plan = Column(Text, nullable=False, default="free")
    status = Column(Text, nullable=False, default="active")
    settings = Column(JSON, nullable=False, default=dict)
    created_at = Column(DateTime(timezone=True), default=datetime.utcnow)
    updated_at = Column(DateTime(timezone=True), default=datetime.utcnow, onupdate=datetime.utcnow)
    members = relationship("OrganizationMember", back_populates="organization")
    subscription = relationship("Subscription", uselist=False, back_populates="organization")

    __table_args__ = (
        Index("idx_organizations_status", "status", postgresql_where=text("status = 'active'")),
    )

class User(Base):
    __tablename__ = "users"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email = Column(Text, nullable=False, unique=True)
    password_hash = Column(Text, nullable=False)
    display_name = Column(Text)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=datetime.utcnow)
    updated_at = Column(DateTime(timezone=True), default=datetime.utcnow, onupdate=datetime.utcnow)
    memberships = relationship("OrganizationMember", back_populates="user")

    __table_args__ = (Index("idx_users_email", "email", postgresql_where=text("deleted_at IS NULL")),)

class OrganizationMember(Base):
    __tablename__ = "organization_members"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    role = Column(Text, nullable=False, default="member")
    joined_at = Column(DateTime(timezone=True), default=datetime.utcnow)
    organization = relationship("Organization", back_populates="members")
    user = relationship("User", back_populates="memberships")

    __table_args__ = (
        UniqueConstraint("organization_id", "user_id"),
        Index("idx_members_org", "organization_id"),
        Index("idx_members_user", "user_id"),
    )

class Subscription(Base):
    __tablename__ = "subscriptions"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, unique=True)
    stripe_subscription_id = Column(Text, unique=True)
    status = Column(Text, nullable=False, default="trialing")
    current_period_end = Column(DateTime(timezone=True))
    organization = relationship("Organization", back_populates="subscription")

    __table_args__ = (
        Index("idx_subscriptions_period_end", "current_period_end", postgresql_where=text("status = 'active'")),
    )
```

### Snippet 3: Alembic Migration

```python
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = '001'
down_revision = None

def upgrade():
    op.create_table(
        'organizations',
        sa.Column('id', postgresql.UUID(as_uuid=True), server_default=sa.text('gen_random_uuid()'), nullable=False),
        sa.Column('name', sa.Text(), nullable=False),
        sa.Column('slug', sa.Text(), nullable=False, unique=True),
        sa.Column('plan', sa.Text(), nullable=False, server_default='free'),
        sa.Column('status', sa.Text(), nullable=False, server_default='active'),
        sa.Column('settings', postgresql.JSONB(), nullable=False, server_default='{}'),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
        sa.PrimaryKeyConstraint('id')
    )
    op.create_index('idx_organizations_status', 'organizations', ['status'], postgresql_where=sa.text("status = 'active'"))

    op.create_table(
        'users',
        sa.Column('id', postgresql.UUID(as_uuid=True), server_default=sa.text('gen_random_uuid()'), nullable=False),
        sa.Column('email', sa.Text(), nullable=False, unique=True),
        sa.Column('password_hash', sa.Text(), nullable=False),
        sa.Column('display_name', sa.Text(), nullable=True),
        sa.Column('deleted_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
        sa.PrimaryKeyConstraint('id')
    )
    op.create_index('idx_users_email', 'users', ['email'], postgresql_where=sa.text('deleted_at IS NULL'))

    op.create_table(
        'organization_members',
        sa.Column('id', postgresql.UUID(as_uuid=True), server_default=sa.text('gen_random_uuid()'), nullable=False),
        sa.Column('organization_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('organizations.id', ondelete='CASCADE'), nullable=False),
        sa.Column('user_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False),
        sa.Column('role', sa.Text(), nullable=False, server_default='member'),
        sa.Column('joined_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('organization_id', 'user_id')
    )
    op.create_index('idx_members_org', 'organization_members', ['organization_id'])
    op.create_index('idx_members_user', 'organization_members', ['user_id'])

def downgrade():
    op.drop_table('organization_members')
    op.drop_table('users')
    op.drop_table('organizations')
```

### Snippet 4: Cache-Aside (Python + Redis)

```python
import redis, json, time
from functools import wraps

redis_client = redis.Redis(host='localhost', port=6379, decode_responses=True)

def cache_aside(cache_key: str, ttl_seconds: int = 300, lock_ttl_seconds: int = 10):
    def decorator(fetch_fn):
        @wraps(fetch_fn)
        def wrapper(*args, **kwargs):
            cached = redis_client.get(cache_key)
            if cached is not None:
                return json.loads(cached)
            lock_key = f"lock:{cache_key}"
            if redis_client.set(lock_key, "1", nx=True, ex=lock_ttl_seconds):
                try:
                    result = fetch_fn(*args, **kwargs)
                    redis_client.setex(cache_key, ttl_seconds, json.dumps(result))
                    return result
                finally:
                    redis_client.delete(lock_key)
            else:
                time.sleep(0.05)
                cached = redis_client.get(cache_key)
                if cached is not None:
                    return json.loads(cached)
                return fetch_fn(*args, **kwargs)
        def invalidate():
            redis_client.delete(cache_key)
            redis_client.delete(f"lock:{cache_key}")
        wrapper.invalidate = invalidate
        return wrapper
    return decorator

@cache_aside(cache_key="user:{user_id}", ttl_seconds=300)
def get_user(user_id: str) -> dict:
    return db.query_one("SELECT * FROM users WHERE id = %s", (user_id,))

def update_user(user_id: str, data: dict):
    db.execute("UPDATE users SET ... WHERE id = %s", (user_id,))
    get_user.invalidate()  # type: ignore
```

### Snippet 5: Connection Pooling Config (SQLAlchemy + PgBouncer)

```python
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import NullPool

# Use NullPool when connecting through PgBouncer in transaction mode
engine = create_engine(
    DATABASE_URL,  # points to pgbouncer:6432
    poolclass=NullPool,
    connect_args={
        "connect_timeout": 10,
        "options": "-c statement_timeout=30000",
    }
)

# Without PgBouncer, use local pool:
# engine = create_engine(
#     DATABASE_URL,
#     pool_size=10, max_overflow=20, pool_timeout=30,
#     pool_recycle=1800, pool_pre_ping=True,
# )

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Prisma: DATABASE_URL="postgresql://user:pass@pgbouncer:6432/mydb?pgbouncer=true"
# Add directUrl for migrations: directUrl="postgresql://user:pass@postgres:5432/mydb"
```

### Snippet 6: Read Replica Router (TypeScript)

```typescript
import { PrismaClient } from '@prisma/client'

const primary = new PrismaClient({ datasources: { db: { url: process.env.DATABASE_URL! } } })
const replica = new PrismaClient({ datasources: { db: { url: process.env.REPLICA_DATABASE_URL! } } })

const stickyReads = new Map<string, number>()
const STICKY_DURATION_MS = 5000

export class DatabaseRouter {
  static stickyForUser(userId: string, durationMs: number = STICKY_DURATION_MS): void {
    stickyReads.set(userId, Date.now() + durationMs)
  }

  static client(options: { userId?: string; operation: 'read' | 'write' }): PrismaClient {
    if (options.operation === 'write') {
      if (options.userId) this.stickyForUser(options.userId)
      return primary
    }
    if (options.userId) {
      const expiry = stickyReads.get(options.userId)
      if (expiry && Date.now() < expiry) return primary
      stickyReads.delete(options.userId)
    }
    return replica
  }
}

// Usage
class UserService {
  async createUser(data: { email: string }) {
    const client = DatabaseRouter.client({ operation: 'write' })
    const user = await client.user.create({ data })
    DatabaseRouter.stickyForUser(user.id)
    return user
  }
  async getUser(userId: string) {
    const client = DatabaseRouter.client({ operation: 'read', userId })
    return client.user.findUnique({ where: { id: userId } })
  }
}
```

### Snippet 7: Query Optimization — EXPLAIN Helper

```python
from sqlalchemy import text
from typing import Dict, List, Any

class QueryAnalyzer:
    def __init__(self, db_session):
        self.db = db_session

    def analyze(self, query: str, params: Dict = None) -> Dict[str, Any]:
        explain = f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query}"
        result = self.db.execute(text(explain), params or {})
        plan = result.fetchone()[0]
        return self._parse_plan(plan)

    def _parse_plan(self, plan: List[Dict]) -> Dict[str, Any]:
        node = plan[0]["Plan"]
        return {
            "operation": node["Node Type"],
            "total_cost": node["Total Cost"],
            "actual_time": node.get("Actual Total Time"),
            "actual_rows": node.get("Actual Rows"),
            "shared_read_blocks": node.get("Shared Read Blocks", 0),
            "index_name": node.get("Index Name"),
            "warnings": self._detect_warnings(node)
        }

    def _detect_warnings(self, node: Dict) -> List[str]:
        warnings = []
        if node["Node Type"] == "Seq Scan" and node.get("Plan Rows", 0) > 10000:
            warnings.append(f"Seq scan on {node.get('Relation Name')} — consider adding an index")
        for child in node.get("Plans", []):
            warnings.extend(self._detect_warnings(child))
        return warnings

    def find_missing_indexes(self, schema: str = "public") -> List[Dict]:
        sql = """
        SELECT schemaname, tablename, seq_scan, idx_scan, n_live_tup as live_rows
        FROM pg_stat_user_tables
        WHERE schemaname = :schema AND seq_scan > 0 AND n_live_tup > 1000
          AND (idx_scan IS NULL OR seq_scan > idx_scan * 10)
        ORDER BY seq_scan DESC LIMIT 20
        """
        return [dict(row) for row in self.db.execute(text(sql), {"schema": schema}).mappings()]
```

### Snippet 8: N+1 Prevention with DataLoader (Python)

```python
from typing import List, Dict, Callable, TypeVar, Any
import asyncio

T = TypeVar('T')
K = TypeVar('K')

class DataLoader:
    def __init__(self, batch_load_fn: Callable[[List[K]], List[T]], key_fn: Callable[[T], K]):
        self._batch_load_fn = batch_load_fn
        self._key_fn = key_fn
        self._queue = []
        self._scheduled = False

    async def load(self, key: K) -> T:
        future = asyncio.get_event_loop().create_future()
        self._queue.append({"key": key, "future": future})
        if not self._scheduled:
            self._scheduled = True
            asyncio.get_event_loop().call_soon(self._dispatch)
        return await future

    def _dispatch(self):
        self._scheduled = False
        if not self._queue: return
        batch = self._queue; self._queue = []
        keys = [item["key"] for item in batch]
        try:
            results = self._batch_load_fn(keys)
            result_map = {self._key_fn(r): r for r in results if r is not None}
            for item in batch:
                item["future"].set_result(result_map.get(item["key"]))
        except Exception as e:
            for item in batch: item["future"].set_exception(e)

# Usage with SQLAlchemy
from sqlalchemy.orm import Session
from models import Order

def create_order_loader(db: Session) -> DataLoader:
    def batch_load_orders(user_ids: List[str]) -> List[Order]:
        return db.query(Order).filter(Order.user_id.in_(user_ids)).all()
    return DataLoader(batch_load_fn=batch_load_orders, key_fn=lambda order: order.user_id)

async def get_users_with_orders(db: Session, user_ids: List[str]):
    order_loader = create_order_loader(db)
    users = db.query(User).filter(User.id.in_(user_ids)).all()
    for user in users:
        user.orders = await order_loader.load(user.id)
    return users

# GraphQL resolver example
class UserResolver:
    def __init__(self, db: Session):
        self._order_loader = create_order_loader(db)
    async def resolve_orders(self, user_id: str):
        return await self._order_loader.load(user_id)
```

---

## Quick Reference: Decision Checklist

| Decision | Default | When to Override |
|---|---|---|
| Database | PostgreSQL | Sharding >10TB, document-centric, team expertise |
| ORM (TS) | Drizzle | Prisma for rapid prototyping, TypeORM for legacy |
| ORM (Python) | SQLAlchemy 2.0 | Django ORM for Django projects |
| Pooling | PgBouncer + NullPool | Serverless → Prisma Accelerate |
| Caching | Cache-aside + Redis | Strict consistency → write-through |
| Migrations | Incremental + backward-compatible | Zero-downtime → blue-green |
| Reads | Primary only | Read load > 5x write load → add replicas |
| N+1 | DataLoader / JOIN | Simple lists → `IN` clause |

---

*Last updated: 2025. For Prisma 7.0, Drizzle, and SQLAlchemy 2.0 updates, see the ORM comparison table.*
