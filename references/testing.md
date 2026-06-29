# Testing Patterns & Strategies Reference

A comprehensive reference for testing backend systems — from unit tests to end-to-end flows, across TypeScript and Python stacks. This guide covers the testing pyramid, tooling choices, real code examples, and production patterns for reliable test suites.

**Table of Contents**

- [1. The Testing Pyramid](#1-the-testing-pyramid)
- [2. Unit Testing (TypeScript)](#2-unit-testing-typescript)
- [3. Unit Testing (Python)](#3-unit-testing-python)
- [4. API Integration Testing](#4-api-integration-testing)
- [5. Contract Testing](#5-contract-testing)
- [6. Security Testing](#6-security-testing)
- [7. Performance Testing](#7-performance-testing)
- [8. Test Database Setup](#8-test-database-setup)
- [9. Mocking Strategies](#9-mocking-strategies)
- [10. E2E Testing](#10-e2e-testing)
- [11. Code Snippets Summary](#11-code-snippets-summary)

---

## 1. The Testing Pyramid

The testing pyramid is the foundational model for allocating test effort across layers. The key insight: **more tests at lower levels, fewer at higher levels**. Lower-level tests are fast, cheap, and give precise failure signals. Higher-level tests are slow, expensive, but validate the system as a whole.

### Visual Diagram

```
        /\
       /  \        E2E Tests (Few, Slow, Expensive)
      / E2E \       ~5-10% of total tests
     /--------\      5-30 min per run
    /          \     Validate full user journeys
   / Integration \   Integration Tests (Moderate)
  /----------------\  ~20-30% of total tests
 /                  \ 1-5 min per run
/     Unit Tests     \  Unit Tests (Many, Fast, Cheap)
----------------------  ~60-75% of total tests
                       <100ms each, <10s total
```

### Layer Breakdown

| Layer | What It Tests | Speed | Cost | Coverage Target | When It Fails |
|-------|--------------|-------|------|-----------------|---------------|
| **Unit** | Single function/class in isolation | <100ms | Very low | 60-75% of tests | Pinpoints exact line |
| **Integration** | Components together (DB, HTTP, services) | 1-5s | Low | 20-30% of tests | Identifies interface mismatch |
| **Contract** | API compatibility between consumer/provider | 10-30s | Low | Per integration point | Detects breaking API changes |
| **E2E** | Full user flows through the real system | 5-30m | High | 5-10% of tests | Catches regression in critical paths |
| **Performance** | System under load | Minutes | Medium | Per release | Reveals scalability issues |
| **Security** | Vulnerabilities, auth, authorization | 10-60m | Medium | Per release | Finds exploitable weaknesses |

### Coverage Targets by Layer

These are pragmatic targets, not dogma. Adjust based on team maturity and risk profile.

| Layer | Target | Measurement Tool |
|-------|--------|------------------|
| Unit (logic) | 80-90% line coverage | `v8` (Vitest), `coverage` (pytest) |
| Unit (branches) | 70-80% branch coverage | Same as above |
| Integration (API) | 100% of endpoints tested | Manual test inventory |
| Integration (DB) | All transaction paths | Migration + seed tests |
| E2E | 100% critical paths | Feature mapping |
| Contract | All consumer/provider pairs | Pact broker coverage |

> **Rule of thumb:** If a bug escapes a layer, add a test at the layer where it *should* have been caught. A production bug means a missing test somewhere.

---

## 2. Unit Testing (TypeScript)

**Vitest** is the preferred test runner for modern TypeScript backends. It has native ESM support, TypeScript awareness out of the box, and a Jest-compatible API.

### Vitest Setup

```typescript
// vitest.config.ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,           // Allows using test/describe without imports
    environment: 'node',   // Sets up Node.js globals
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov', 'html'],
      thresholds: {
        lines: 80,
        functions: 80,
        branches: 70,
      },
    },
    setupFiles: ['./tests/setup.ts'],
    // Parallelism control for DB-heavy tests
    pool: 'forks',
    poolOptions: {
      forks: { singleFork: true },
    },
  },
});
```

### Test File Organization

```
src/
  services/
    user.service.ts
    user.service.test.ts        # Co-located tests (colocation pattern)
  repositories/
    user.repository.ts
    user.repository.test.ts
tests/
  setup.ts                     # Global test setup
  fixtures/
    users.ts                   # Shared test data
  integration/
    user-api.test.ts           # Cross-cutting integration tests
```

> **Co-location pattern:** Keep unit tests next to the source file. This makes tests discoverable and encourages maintenance. Integration and E2E tests live in a separate `tests/` directory.

### Mocking with `vi.fn()`

```typescript
// src/services/user.service.ts
export interface UserRepository {
  findById(id: string): Promise<{ id: string; email: string } | null>;
  create(data: { email: string; password: string }): Promise<{ id: string }>;
}

export class UserService {
  constructor(private repo: UserRepository) {}

  async getUser(id: string) {
    const user = await this.repo.findById(id);
    if (!user) throw new Error('User not found');
    return user;
  }

  async register(email: string, password: string) {
    if (password.length < 8) {
      throw new Error('Password must be at least 8 characters');
    }
    return this.repo.create({ email, password });
  }
}
```

```typescript
// src/services/user.service.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { UserService, UserRepository } from './user.service';

describe('UserService', () => {
  let mockRepo: UserRepository;
  let service: UserService;

  beforeEach(() => {
    // Create a complete mock of the repository interface
    mockRepo = {
      findById: vi.fn(),
      create: vi.fn(),
    };
    service = new UserService(mockRepo);
  });

  describe('getUser', () => {
    it('returns a user when found', async () => {
      const user = { id: 'user-1', email: 'alice@example.com' };
      vi.mocked(mockRepo.findById).mockResolvedValue(user);

      const result = await service.getUser('user-1');

      expect(result).toEqual(user);
      expect(mockRepo.findById).toHaveBeenCalledWith('user-1');
    });

    it('throws when user is not found', async () => {
      vi.mocked(mockRepo.findById).mockResolvedValue(null);

      await expect(service.getUser('missing')).rejects.toThrow('User not found');
    });
  });

  describe('register', () => {
    it('creates a user with valid data', async () => {
      vi.mocked(mockRepo.create).mockResolvedValue({ id: 'new-user' });

      const result = await service.register('bob@example.com', 'secure123!');

      expect(result).toEqual({ id: 'new-user' });
      expect(mockRepo.create).toHaveBeenCalledWith({
        email: 'bob@example.com',
        password: 'secure123!',
      });
    });

    it('rejects short passwords', async () => {
      await expect(
        service.register('bob@example.com', 'short')
      ).rejects.toThrow('Password must be at least 8 characters');

      // Verify create was never called
      expect(mockRepo.create).not.toHaveBeenCalled();
    });
  });
});
```

### MSW for HTTP Mocking

Mock Service Worker (MSW) intercepts HTTP requests at the network level. Use it for testing services that call external APIs.

```typescript
// tests/mocks/handlers.ts
import { http, HttpResponse } from 'msw';
import { setupServer } from 'msw/node';

export const handlers = [
  http.get('https://api.stripe.com/v1/customers/:id', ({ params }) => {
    return HttpResponse.json({
      id: params.id,
      email: 'customer@example.com',
      balance: 0,
    });
  }),

  http.post('https://api.stripe.com/v1/customers', async ({ request }) => {
    const body = await request.json() as { email?: string };
    return HttpResponse.json({
      id: 'cus_new',
      email: body?.email || 'unknown',
    }, { status: 201 });
  }),
];

export const server = setupServer(...handlers);

// tests/setup.ts
import { server } from './mocks/handlers';

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));
afterEach(() => server.resetHandlers());
afterAll(() => server.close());
```

```typescript
// src/services/billing.service.ts
export class BillingService {
  constructor(private apiKey: string) {}

  async getCustomer(id: string) {
    const res = await fetch(`https://api.stripe.com/v1/customers/${id}`, {
      headers: { Authorization: `Bearer ${this.apiKey}` },
    });
    if (!res.ok) throw new Error(`Stripe error: ${res.status}`);
    return res.json();
  }
}

// src/services/billing.service.test.ts
import { describe, it, expect, beforeAll, afterEach, afterAll } from 'vitest';
import { http, HttpResponse } from 'msw';
import { BillingService } from './billing.service';
import { server } from '../../tests/mocks/handlers';

describe('BillingService', () => {
  beforeAll(() => server.listen());
  afterEach(() => server.resetHandlers());
  afterAll(() => server.close());

  it('fetches a customer', async () => {
    const service = new BillingService('sk_test_xxx');
    const customer = await service.getCustomer('cus_123');

    expect(customer.id).toBe('cus_123');
    expect(customer.email).toBe('customer@example.com');
  });

  it('handles Stripe errors', async () => {
    server.use(
      http.get('https://api.stripe.com/v1/customers/:id', () => {
        return HttpResponse.json({ error: 'not_found' }, { status: 404 });
      })
    );

    const service = new BillingService('sk_test_xxx');
    await expect(service.getCustomer('bad')).rejects.toThrow('Stripe error: 404');
  });
});
```

---

## 3. Unit Testing (Python)

**pytest** is the standard for Python testing. It provides fixtures, parametrization, and a rich plugin ecosystem.

### pytest Setup

```ini
# pyproject.toml
[tool.pytest.ini_options]
minversion = "7.0"
testpaths = ["tests"]
python_files = ["test_*.py", "*_test.py"]
python_classes = ["Test*"]
python_functions = ["test_*"]
addopts = "-v --tb=short --strict-markers"
markers = [
    "slow: marks tests as slow (deselect with '-m not slow')",
    "integration: marks tests as integration tests",
]
filterwarnings = [
    "ignore::DeprecationWarning",
]
```

```bash
# Install dependencies
pip install pytest pytest-asyncio pytest-cov
```

### Fixtures and Parametrization

```python
# tests/conftest.py
import pytest
from unittest.mock import MagicMock

from app.services.user_service import UserService
from app.repositories.user_repository import UserRepository


@pytest.fixture
def mock_repo():
    """Returns a mock user repository."""
    return MagicMock(spec=UserRepository)


@pytest.fixture
def user_service(mock_repo):
    """Returns a UserService with a mock repository."""
    return UserService(repository=mock_repo)


@pytest.fixture
def sample_user():
    """Returns a sample user dict for testing."""
    return {"id": "user-1", "email": "alice@example.com", "name": "Alice"}
```

```python
# app/services/user_service.py
from dataclasses import dataclass
from typing import Optional, Protocol


class UserRepository(Protocol):
    def find_by_id(self, user_id: str) -> Optional[dict]: ...
    def create(self, data: dict) -> dict: ...


class UserService:
    def __init__(self, repository: UserRepository):
        self._repo = repository

    def get_user(self, user_id: str) -> dict:
        user = self._repo.find_by_id(user_id)
        if user is None:
            raise ValueError(f"User not found: {user_id}")
        return user

    def register(self, email: str, password: str) -> dict:
        if len(password) < 8:
            raise ValueError("Password must be at least 8 characters")
        return self._repo.create({"email": email, "password": password})
```

```python
# tests/services/test_user_service.py
import pytest
from app.services.user_service import UserService


class TestUserService:
    def test_get_user_returns_user(self, user_service, mock_repo, sample_user):
        mock_repo.find_by_id.return_value = sample_user

        result = user_service.get_user("user-1")

        assert result == sample_user
        mock_repo.find_by_id.assert_called_once_with("user-1")

    def test_get_user_raises_when_not_found(self, user_service, mock_repo):
        mock_repo.find_by_id.return_value = None

        with pytest.raises(ValueError, match="User not found: missing"):
            user_service.get_user("missing")

    def test_register_creates_user(self, user_service, mock_repo):
        mock_repo.create.return_value = {"id": "new-user", "email": "bob@example.com"}

        result = user_service.register("bob@example.com", "securepass123")

        assert result["id"] == "new-user"
        mock_repo.create.assert_called_once()

    @pytest.mark.parametrize("password", ["short", "12345", ""])
    def test_register_rejects_short_passwords(self, user_service, password):
        with pytest.raises(ValueError, match="Password must be at least 8 characters"):
            user_service.register("bob@example.com", password)

        # Ensure create was never called
        user_service._repo.create.assert_not_called()
```

### Testing FastAPI Endpoints

```python
# app/main.py
from fastapi import FastAPI, HTTPException
from app.services.user_service import UserService

app = FastAPI()
user_service = UserService(repository=...)  # injected in real app

@app.get("/users/{user_id}")
async def get_user(user_id: str):
    try:
        user = user_service.get_user(user_id)
        return user
    except ValueError:
        raise HTTPException(status_code=404, detail="User not found")
```

```python
# tests/test_main.py
from fastapi.testclient import TestClient
from unittest.mock import MagicMock, patch
from app.main import app, user_service

client = TestClient(app)


def test_get_user_endpoint():
    with patch.object(user_service, "get_user", return_value={"id": "1", "email": "a@b.com"}):
        response = client.get("/users/1")

    assert response.status_code == 200
    assert response.json()["email"] == "a@b.com"


def test_get_user_not_found():
    with patch.object(user_service, "get_user", side_effect=ValueError("not found")):
        response = client.get("/users/999")

    assert response.status_code == 404
    assert response.json()["detail"] == "User not found"
```

---

## 4. API Integration Testing

Integration tests verify that components work together. They hit real databases and HTTP endpoints but are isolated from external production systems.

### Supertest (Node.js) with Database

```typescript
// tests/integration/user-api.test.ts
import { describe, it, beforeEach, afterEach, expect } from 'vitest';
import request from 'supertest';
import { createApp } from '../../src/app';
import { db } from '../../src/db';

// Helper to create the test app
function createTestApp() {
  return createApp({
    db: db,           // use test database connection
    env: 'test',
  });
}

async function cleanupTables() {
  // Truncate all tables between tests
  await db.execute('TRUNCATE TABLE users, orders CASCADE');
}

async function seedUsers() {
  await db.insertInto('users').values([
    { id: 'user-1', email: 'alice@example.com', name: 'Alice' },
    { id: 'user-2', email: 'bob@example.com', name: 'Bob' },
  ]).execute();
}

describe('User API', () => {
  let app: ReturnType<typeof createTestApp>;

  beforeEach(async () => {
    app = createTestApp();
    await cleanupTables();
    await seedUsers();
  });

  afterEach(async () => {
    await cleanupTables();
  });

  describe('GET /users/:id', () => {
    it('returns a user when found', async () => {
      const res = await request(app)
        .get('/users/user-1')
        .expect(200);

      expect(res.body).toMatchObject({
        id: 'user-1',
        email: 'alice@example.com',
        name: 'Alice',
      });
    });

    it('returns 404 when user not found', async () => {
      await request(app)
        .get('/users/nonexistent')
        .expect(404);
    });
  });

  describe('POST /users', () => {
    it('creates a new user', async () => {
      const res = await request(app)
        .post('/users')
        .send({ email: 'charlie@example.com', name: 'Charlie', password: 'secure123!' })
        .expect(201);

      expect(res.body).toMatchObject({
        email: 'charlie@example.com',
        name: 'Charlie',
      });
      expect(res.body.id).toBeDefined();
      expect(res.body.password).toBeUndefined(); // never return password
    });

    it('validates email format', async () => {
      const res = await request(app)
        .post('/users')
        .send({ email: 'not-an-email', name: 'Bad', password: 'secure123!' })
        .expect(400);

      expect(res.body.errors).toContainEqual(
        expect.objectContaining({ field: 'email' })
      );
    });
  });
});
```

### pytest with TestClient (FastAPI)

```python
# tests/integration/test_user_api.py
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker, Session
from app.main import app, get_db
from app.models import Base

# Use SQLite in-memory for integration tests
TEST_DATABASE_URL = "sqlite:///:memory:"
engine = create_engine(TEST_DATABASE_URL, connect_args={"check_same_thread": False})
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def override_get_db():
    db = TestingSessionLocal()
    try:
        yield db
    finally:
        db.close()


app.dependency_overrides[get_db] = override_get_db


@pytest.fixture(scope="function")
def db_session():
    """Create fresh tables for each test function."""
    Base.metadata.create_all(bind=engine)
    session = TestingSessionLocal()
    yield session
    session.close()
    Base.metadata.drop_all(bind=engine)


@pytest.fixture
def client(db_session):
    """Yield a TestClient with DB override."""
    yield TestClient(app)


def test_get_user(client, db_session):
    # Seed data
    db_session.execute(
        text("INSERT INTO users (id, email, name) VALUES (:id, :email, :name)"),
        {"id": "user-1", "email": "alice@example.com", "name": "Alice"}
    )
    db_session.commit()

    response = client.get("/users/user-1")

    assert response.status_code == 200
    data = response.json()
    assert data["email"] == "alice@example.com"


def test_create_user(client):
    response = client.post("/users", json={
        "email": "bob@example.com",
        "name": "Bob",
        "password": "secure123!"
    })

    assert response.status_code == 201
    data = response.json()
    assert data["email"] == "bob@example.com"
    assert "password" not in data
```

### Database Cleanup Strategies

| Strategy | How It Works | Speed | Use Case |
|----------|-------------|-------|----------|
| **TRUNCATE** | `TRUNCATE TABLE users CASCADE` between tests | Fast | PostgreSQL integration tests |
| **DELETE** | `DELETE FROM users` between tests | Medium | Simple tables, no FK constraints |
| **Rollback** | Wrap each test in a transaction, rollback after | Fastest | ORM-based tests (SQLAlchemy) |
| **Recreate DB** | Drop and recreate schema per test | Slow | Schema migration tests |
| **SQLite In-Memory** | `:memory:` database per test | Very fast | FastAPI/Flask integration tests |

> **Recommendation:** Use transaction rollback for unit-of-work tests, TRUNCATE for cross-table integration tests, and SQLite in-memory for speed when you don't need PostgreSQL-specific features.

---

## 5. Contract Testing

**Consumer-Driven Contract Testing (Pact)** ensures that API consumers and providers agree on the shape of requests and responses. It prevents breaking changes from reaching production.

### When to Use Contract Testing

| Scenario | Contract Test? | Notes |
|----------|---------------|-------|
| Internal microservices (same team) | Optional | Integration tests may suffice |
| Internal microservices (different teams) | **Yes** | Prevents cross-team breakage |
| External APIs you consume | **Yes** | Protect against provider changes |
| External APIs you provide | **Yes** | Consumers validate expectations |
| Mobile app + backend | **Yes** | Mobile releases are slow to fix |

### Pact Basics

```typescript
// tests/contracts/user-service.pact.ts
import { Pact } from '@pact-foundation/pact';
import { like, term } from '@pact-foundation/pact/dsl/matchers';
import path from 'path';
import { UserService } from '../../src/services/user.service';

const provider = new Pact({
  consumer: 'web-frontend',
  provider: 'user-service',
  port: 1234,
  log: path.resolve(process.cwd(), 'logs', 'pact.log'),
  dir: path.resolve(process.cwd(), 'pacts'),
  logLevel: 'warn',
});

describe('User Service Pact', () => {
  beforeAll(() => provider.setup());
  afterAll(() => provider.finalize());
  afterEach(() => provider.verify());

  it('returns a user by ID', async () => {
    await provider.addInteraction({
      state: 'user with id user-1 exists',
      uponReceiving: 'a request for user-1',
      withRequest: {
        method: 'GET',
        path: '/users/user-1',
        headers: { Authorization: term(/^Bearer .+$/, 'Bearer valid-token') },
      },
      willRespondWith: {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
        body: {
          id: like('user-1'),
          email: like('alice@example.com'),
          name: like('Alice'),
        },
      },
    });

    const service = new UserService('http://localhost:1234', 'valid-token');
    const user = await service.getUser('user-1');

    expect(user.id).toBe('user-1');
    expect(user.email).toMatch(/@/);
  });
});
```

### Provider Verification

The provider (backend) runs the pact file against its real codebase to confirm it satisfies all consumer expectations.

```bash
# Add to CI pipeline for the provider service
npx pact-verifier \
  --provider-base-url http://localhost:3000 \
  --pact-broker-base-url https://pact-broker.example.com \
  --provider user-service \
  --provider-app-version $GIT_COMMIT \
  --publish-verification-results
```

---

## 6. Security Testing

Security testing is not optional for production systems. Automate it in CI.

### OWASP ZAP (Automated Scanning)

```bash
# Baseline scan — fast, finds obvious issues
zap-baseline.py -t http://localhost:3000 -r zap-report.html

# Full scan — thorough but slower
zap-full-scan.py -t http://localhost:3000 -r zap-full-report.html

# API scan — for REST/GraphQL endpoints
zap-api-scan.py -t http://localhost:3000/openapi.json -f openapi -r zap-api-report.html
```

### Security Checklist as Code

```typescript
// tests/security/security-checklist.test.ts
import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { createApp } from '../../src/app';

const app = createApp();

describe('Security Headers', () => {
  it('sets X-Content-Type-Options: nosniff', async () => {
    const res = await request(app).get('/health');
    expect(res.headers['x-content-type-options']).toBe('nosniff');
  });

  it('sets X-Frame-Options: DENY', async () => {
    const res = await request(app).get('/health');
    expect(res.headers['x-frame-options']).toBe('DENY');
  });

  it('sets Strict-Transport-Security', async () => {
    const res = await request(app).get('/health');
    expect(res.headers['strict-transport-security']).toMatch(/max-age=/);
  });
});

describe('Input Validation', () => {
  it('rejects SQL injection patterns in query params', async () => {
    const res = await request(app)
      .get('/users?id=1 OR 1=1')
      .expect(400);

    expect(res.body.error).toBeDefined();
  });

  it('sanitizes HTML in request body', async () => {
    const res = await request(app)
      .post('/users')
      .send({ name: '<script>alert(1)</script>', email: 'test@example.com' })
      .expect(201);

    expect(res.body.name).not.toContain('<script>');
  });
});
```

### BOLA (Broken Object Level Authorization) Testing

BOLA is the #1 API security risk. Test that users cannot access other users' resources.

```typescript
// tests/security/bola.test.ts
import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../../src/app';

describe('BOLA — Broken Object Level Authorization', () => {
  let app: ReturnType<typeof createApp>;
  let aliceToken: string;
  let bobToken: string;
  let aliceOrderId: string;

  beforeEach(async () => {
    app = createApp();
    // Create Alice and Bob with their own resources
    aliceToken = await createUserAndLogin({ email: 'alice@example.com' });
    bobToken = await createUserAndLogin({ email: 'bob@example.com' });
    aliceOrderId = await createOrder(aliceToken, { item: 'book', price: 20 });
  });

  it('prevents Bob from accessing Alice order', async () => {
    const res = await request(app)
      .get(`/orders/${aliceOrderId}`)
      .set('Authorization', `Bearer ${bobToken}`)
      .expect(403);

    expect(res.body.error).toMatch(/not authorized|forbidden|access denied/i);
  });

  it('prevents Bob from updating Alice order', async () => {
    const res = await request(app)
      .patch(`/orders/${aliceOrderId}`)
      .set('Authorization', `Bearer ${bobToken}`)
      .send({ status: 'cancelled' })
      .expect(403);
  });

  it('prevents Bob from deleting Alice order', async () => {
    await request(app)
      .delete(`/orders/${aliceOrderId}`)
      .set('Authorization', `Bearer ${bobToken}`)
      .expect(403);
  });

  it('allows Alice to access her own order', async () => {
    const res = await request(app)
      .get(`/orders/${aliceOrderId}`)
      .set('Authorization', `Bearer ${aliceToken}`)
      .expect(200);

    expect(res.body.item).toBe('book');
  });
});
```

### Fuzzing Inputs

```python
# tests/security/test_fuzzing.py
import pytest
from fastapi.testclient import TestClient
from hypothesis import given, strategies as st
from app.main import app

client = TestClient(app)

@given(st.text(min_size=0, max_size=1000))
def test_search_does_not_crash_on_arbitrary_input(query):
    """Any string input to search should not crash the server."""
    response = client.get(f"/search?q={query}")
    # Should never 500 regardless of input
    assert response.status_code != 500

@given(st.integers(min_value=-10**12, max_value=10**12))
def test_user_id_does_not_crash(user_id):
    """Numeric user IDs should be handled gracefully."""
    response = client.get(f"/users/{user_id}")
    assert response.status_code in (200, 400, 404)
    assert response.status_code != 500
```

---

## 7. Performance Testing

Measure how your system behaves under load. Performance regressions are bugs.

### k6 Load Test Script

```javascript
// tests/performance/load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const responseTime = new Trend('response_time');

export const options = {
  stages: [
    { duration: '1m', target: 10 },    // Ramp up to 10 users
    { duration: '3m', target: 50 },    // Ramp up to 50 users
    { duration: '5m', target: 50 },    // Stay at 50 users
    { duration: '2m', target: 100 },   // Ramp up to 100 users
    { duration: '5m', target: 100 },   // Stay at 100 users
    { duration: '2m', target: 0 },     // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],   // 95% of requests under 500ms
    http_req_failed: ['rate<0.01'],     // Error rate under 1%
    errors: ['rate<0.05'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';

export function setup() {
  // Create a test user and get token
  const res = http.post(`${BASE_URL}/auth/register`, JSON.stringify({
    email: `loadtest-${Date.now()}@example.com`,
    password: 'testpass123',
  }), { headers: { 'Content-Type': 'application/json' } });

  return { token: res.json().token };
}

export default function (data) {
  const params = {
    headers: {
      'Authorization': `Bearer ${data.token}`,
      'Content-Type': 'application/json',
    },
  };

  // Simulate a typical user flow
  const start = Date.now();

  // 1. Get user profile
  const profile = http.get(`${BASE_URL}/users/me`, params);
  check(profile, {
    'profile status is 200': (r) => r.status === 200,
    'profile has email': (r) => r.json('email') !== '',
  });
  responseTime.add(Date.now() - start);
  if (profile.status !== 200) errorRate.add(1);

  sleep(Math.random() * 2 + 1); // Think time 1-3s

  // 2. Create an order
  const orderRes = http.post(`${BASE_URL}/orders`, JSON.stringify({
    items: [{ sku: 'BOOK-001', qty: 1 }],
  }), params);
  check(orderRes, {
    'order created': (r) => r.status === 201,
    'order has id': (r) => r.json('id') !== undefined,
  });
  if (orderRes.status !== 201) errorRate.add(1);

  sleep(Math.random() * 3 + 2); // Think time 2-5s
}

export function teardown(data) {
  // Cleanup: delete test user if needed
}
```

Run it:

```bash
# Run against local instance
k6 run --env BASE_URL=http://localhost:3000 tests/performance/load-test.js

# Run against staging
k6 run --env BASE_URL=https://staging.api.example.com tests/performance/load-test.js

# Run in CI with cloud output
k6 run --out cloud tests/performance/load-test.js
```

### What to Measure

| Metric | Definition | Target | Tool |
|--------|-----------|--------|------|
| **RPS** | Requests per second | Sustained at target capacity | k6, Artillery, JMeter |
| **p50 latency** | Median response time | <200ms for APIs | k6, APM |
| **p95 latency** | 95th percentile | <500ms for APIs | k6, APM |
| **p99 latency** | 99th percentile | <1s for non-critical | k6, APM |
| **Error rate** | % of failed requests | <0.1% | k6, logs |
| **CPU utilization** | % CPU under load | <70% sustained | CloudWatch, Datadog |
| **Memory usage** | Heap/ RSS growth | No leaks over 30min | Node --inspect, py-spy |

### Artillery Quick Script

```yaml
# tests/performance/artillery.yml
config:
  target: 'http://localhost:3000'
  phases:
    - duration: 60
      arrivalRate: 10
    - duration: 120
      arrivalRate: 50
  defaults:
    headers:
      Content-Type: 'application/json'
scenarios:
  - flow:
      - post:
          url: '/auth/login'
          json:
            email: 'test@example.com'
            password: 'testpass'
          capture:
            - json: '$.token'
              as: token
      - get:
          url: '/users/me'
          headers:
            Authorization: 'Bearer {{ token }}'
```

```bash
artillery run tests/performance/artillery.yml
```

---

## 8. Test Database Setup

Your test database strategy directly impacts test speed, reliability, and realism.

### Testcontainers (Real PostgreSQL in Docker)

```typescript
// tests/setup/testcontainers.ts
import { PostgreSqlContainer, StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import { execSync } from 'child_process';
import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';

let container: StartedPostgreSqlContainer;
let pool: Pool;

export async function setupTestDatabase() {
  container = await new PostgreSqlContainer('postgres:16-alpine')
    .withDatabase('test_db')
    .withUsername('test')
    .withPassword('test')
    .withExposedPorts(5432)
    .start();

  const connectionString = container.getConnectionUri();
  pool = new Pool({ connectionString });

  // Run migrations
  execSync('npx drizzle-kit migrate', {
    env: { ...process.env, DATABASE_URL: connectionString },
  });

  return { container, pool, db: drizzle(pool) };
}

export async function teardownTestDatabase() {
  await pool.end();
  await container.stop();
}
```

```typescript
// tests/integration/db-testcontainers.test.ts
import { describe, it, beforeAll, afterAll, expect } from 'vitest';
import { setupTestDatabase, teardownTestDatabase } from '../setup/testcontainers';
import { db } from '../../src/db'; // type only

let testDb: Awaited<ReturnType<typeof setupTestDatabase>>;

describe('With Testcontainers PostgreSQL', () => {
  beforeAll(async () => {
    testDb = await setupTestDatabase();
  }, 60000); // 60s timeout for container startup

  afterAll(async () => {
    await teardownTestDatabase();
  });

  it('connects to real PostgreSQL', async () => {
    const result = await testDb.pool.query('SELECT NOW()');
    expect(result.rows[0].now).toBeDefined();
  });

  it('runs migrations successfully', async () => {
    const result = await testDb.pool.query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
    );
    const tables = result.rows.map((r) => r.table_name);
    expect(tables).toContain('users');
  });
});
```

### SQLite In-Memory (Fast)

```python
# tests/conftest.py — SQLite in-memory for FastAPI
import pytest
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker, Session
from app.models import Base
from app.main import app, get_db


@pytest.fixture(scope="session")
def engine():
    """Create a single SQLite in-memory engine for the test session."""
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        echo=False,
    )
    Base.metadata.create_all(bind=engine)
    yield engine
    Base.metadata.drop_all(bind=engine)


@pytest.fixture
def db_session(engine) -> Session:
    """Create a fresh transactional scope for each test."""
    connection = engine.connect()
    transaction = connection.begin()
    session = sessionmaker(bind=connection)()

    # Override the FastAPI dependency
    app.dependency_overrides[get_db] = lambda: session

    yield session

    app.dependency_overrides.clear()
    session.close()
    transaction.rollback()
    connection.close()
```

### Parallel Test Isolation

| Strategy | Isolation Level | Speed | Complexity |
|----------|----------------|-------|------------|
| **SQLite :memory:** per test | Complete | Fastest | Low |
| **SQLite file per worker** | Process-level | Fast | Low |
| **PostgreSQL schema per test** | Complete | Medium | Medium |
| **PostgreSQL transaction rollback** | Test-level | Fast | Medium |
| **Testcontainers per worker** | Complete | Slow | Low |
| **Shared testcontainer + TRUNCATE** | Test-level | Medium | Medium |

> **Best practice:** For CI, use SQLite in-memory for unit tests and a single Testcontainers PostgreSQL instance for integration tests (with TRUNCATE between tests). This gives speed where you need it and realism where it matters.

---

## 9. Mocking Strategies

Mocking is essential for fast, isolated tests. Choose the right mock type for the dependency you're isolating.

### Mocking Decision Matrix

| What You're Mocking | Tool | Use When | Example |
|---------------------|------|----------|---------|
| **Function / dependency** | `vi.fn()`, `unittest.mock` | Unit testing logic | Repository methods, helpers |
| **HTTP calls** | MSW, nock, responses | Service calls external APIs | Stripe, SendGrid, third-party APIs |
| **Database** | In-memory repo, SQLite | Unit testing services | Fast user service tests |
| **Time / dates** | `vi.useFakeTimers()`, `freezegun` | Tests depend on timestamps | TTL, expiry, scheduling |
| **External service** | `MockServer`, `wiremock` | Complex service interactions | OAuth, webhook handlers |
| **Environment / config** | `process.env` override, `monkeypatch` | Tests depend on env vars | Feature flags, API keys |
| **File system** | `memfs`, `tmp_path` | Tests read/write files | CSV imports, exports |
| **Random / UUID** | `vi.spyOn(Math, 'random')`, `faker` | Tests need deterministic IDs | UUID generation, tokens |

### Unit Mocks (TypeScript)

```typescript
// Isolating a service from its repository
const mockRepo = {
  findById: vi.fn().mockResolvedValue({ id: '1', name: 'Alice' }),
  create: vi.fn().mockResolvedValue({ id: '2' }),
};
const service = new UserService(mockRepo as UserRepository);
```

### HTTP Mocks (MSW)

See section 2 for the full MSW example. Key pattern: intercept at the network level so your service code doesn't know it's being tested.

### Time Mocks (Fake Timers)

```typescript
// Vitest fake timers
import { vi, describe, it, expect, beforeEach, afterEach } from 'vitest';

describe('TokenService', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('expires token after 1 hour', () => {
    const token = tokenService.create('user-1');
    expect(tokenService.isValid(token)).toBe(true);

    vi.advanceTimersByTime(60 * 60 * 1000 + 1); // 1 hour + 1ms

    expect(tokenService.isValid(token)).toBe(false);
  });
});
```

```python
# Python freezegun
from freezegun import freeze_time
from datetime import datetime, timedelta

@freeze_time("2024-01-15 12:00:00")
def test_token_expiry():
    token = create_token("user-1", expires_in=3600)
    assert is_valid(token) is True

    # Move forward 2 hours
    with freeze_time("2024-01-15 14:00:01"):
        assert is_valid(token) is False
```

### Database Mocks (In-Memory Repository)

```typescript
// In-memory repository for unit tests
class InMemoryUserRepository implements UserRepository {
  private users = new Map<string, { id: string; email: string }>();

  async findById(id: string) {
    return this.users.get(id) ?? null;
  }

  async create(data: { email: string }) {
    const id = `user-${this.users.size + 1}`;
    const user = { id, ...data };
    this.users.set(id, user);
    return user;
  }

  // Helper for test assertions
  size() { return this.users.size; }
  clear() { this.users.clear(); }
}

// Usage in test
const repo = new InMemoryUserRepository();
const service = new UserService(repo);
await service.register('test@example.com', 'password123');
expect(repo.size()).toBe(1);
```

---

## 10. E2E Testing

End-to-end tests validate the full system. They are expensive but necessary for critical paths.

### Playwright (Browser-Based E2E)

```typescript
// e2e/user-journey.spec.ts
import { test, expect } from '@playwright/test';

test.describe('User Registration Flow', () => {
  test('user can register, login, and view profile', async ({ page }) => {
    // 1. Navigate to registration
    await page.goto('/register');

    // 2. Fill registration form
    await page.fill('[data-testid="email"]', `test-${Date.now()}@example.com`);
    await page.fill('[data-testid="password"]', 'SecurePass123!');
    await page.fill('[data-testid="confirm-password"]', 'SecurePass123!');
    await page.click('[data-testid="submit-register"]');

    // 3. Verify redirect to dashboard
    await expect(page).toHaveURL('/dashboard');
    await expect(page.locator('[data-testid="welcome-message"]')).
      toContainText('Welcome');

    // 4. Logout
    await page.click('[data-testid="logout"]');
    await expect(page).toHaveURL('/login');

    // 5. Login with new credentials
    await page.fill('[data-testid="email"]', 'test@example.com');
    await page.fill('[data-testid="password"]', 'SecurePass123!');
    await page.click('[data-testid="submit-login"]');

    await expect(page).toHaveURL('/dashboard');
  });

  test('registration shows error for duplicate email', async ({ page }) => {
    const email = `dup-${Date.now()}@example.com`;

    // Register once
    await page.goto('/register');
    await page.fill('[data-testid="email"]', email);
    await page.fill('[data-testid="password"]', 'SecurePass123!');
    await page.click('[data-testid="submit-register"]');
    await expect(page).toHaveURL('/dashboard');

    // Logout and try again
    await page.goto('/register');
    await page.fill('[data-testid="email"]', email);
    await page.fill('[data-testid="password"]', 'SecurePass123!');
    await page.click('[data-testid="submit-register"]');

    await expect(page.locator('[data-testid="error-message"]')).
      toContainText('already exists');
  });
});
```

### API-Only E2E with Supertest

When you don't have a frontend (or are testing backend-only), use API E2E tests.

```typescript
// e2e/api-critical-path.test.ts
import { describe, it, beforeAll, afterAll, expect } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app';
import { startTestDb, stopTestDb } from './helpers/test-db';

let app: ReturnType<typeof createApp>;

describe('Critical Path E2E', () => {
  beforeAll(async () => {
    await startTestDb();
    app = createApp();
  });

  afterAll(async () => {
    await stopTestDb();
  });

  it('full checkout flow', async () => {
    // 1. Register
    const register = await request(app)
      .post('/auth/register')
      .send({ email: 'buyer@example.com', password: 'SecurePass123!' })
      .expect(201);
    const token = register.body.token;

    // 2. Add item to cart
    await request(app)
      .post('/cart/items')
      .set('Authorization', `Bearer ${token}`)
      .send({ productId: 'prod-1', quantity: 2 })
      .expect(201);

    // 3. Checkout
    const checkout = await request(app)
      .post('/orders')
      .set('Authorization', `Bearer ${token}`)
      .send({ paymentMethod: 'card_token_123' })
      .expect(201);

    expect(checkout.body.status).toBe('confirmed');
    expect(checkout.body.total).toBeGreaterThan(0);

    // 4. Verify order appears in history
    const orders = await request(app)
      .get('/orders')
      .set('Authorization', `Bearer ${token}`)
      .expect(200);

    expect(orders.body).toHaveLength(1);
    expect(orders.body[0].id).toBe(checkout.body.id);
  });
});
```

### E2E Best Practices

| Practice | Why |
|----------|-----|
| **Test data attributes** | Use `data-testid` selectors, not CSS classes | Resilient to styling changes |
| **Seed data in beforeAll** | Setup reference data once | Faster tests |
| **Cleanup in afterAll** | Delete created users/orders | Prevents state pollution |
| **Test only critical paths** | E2E tests are expensive | Cover happy path + top 2-3 edge cases |
| **Avoid testing third parties** | Mock payment webhooks | You don't control Stripe downtime |
| **Parallelize carefully** | Each worker needs isolated DB | Use worker IDs in DB names |
| **Retry flaky tests** | Network timing causes flakes | Configure 2 retries in CI |

---

## 11. Code Snippets Summary

This section collects all major code snippets for quick reference.

### Snippet 1: Vitest Unit Test with Mocking
```typescript
// src/services/user.service.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { UserService, UserRepository } from './user.service';

describe('UserService', () => {
  let mockRepo: UserRepository;
  let service: UserService;

  beforeEach(() => {
    mockRepo = {
      findById: vi.fn(),
      create: vi.fn(),
    };
    service = new UserService(mockRepo);
  });

  it('returns a user when found', async () => {
    const user = { id: 'user-1', email: 'alice@example.com' };
    vi.mocked(mockRepo.findById).mockResolvedValue(user);
    const result = await service.getUser('user-1');
    expect(result).toEqual(user);
  });

  it('throws when user is not found', async () => {
    vi.mocked(mockRepo.findById).mockResolvedValue(null);
    await expect(service.getUser('missing')).rejects.toThrow('User not found');
  });
});
```

### Snippet 2: pytest Unit Test with Fixtures
```python
# tests/services/test_user_service.py
import pytest
from app.services.user_service import UserService

class TestUserService:
    def test_get_user_returns_user(self, user_service, mock_repo, sample_user):
        mock_repo.find_by_id.return_value = sample_user
        result = user_service.get_user("user-1")
        assert result == sample_user
        mock_repo.find_by_id.assert_called_once_with("user-1")

    def test_get_user_raises_when_not_found(self, user_service, mock_repo):
        mock_repo.find_by_id.return_value = None
        with pytest.raises(ValueError, match="User not found: missing"):
            user_service.get_user("missing")

    @pytest.mark.parametrize("password", ["short", "12345", ""])
    def test_register_rejects_short_passwords(self, user_service, password):
        with pytest.raises(ValueError, match="Password must be at least 8 characters"):
            user_service.register("bob@example.com", password)
```

### Snippet 3: Supertest Integration Test with DB Cleanup
```typescript
// tests/integration/user-api.test.ts
import { describe, it, beforeEach, afterEach, expect } from 'vitest';
import request from 'supertest';
import { createApp } from '../../src/app';
import { db } from '../../src/db';

async function cleanupTables() {
  await db.execute('TRUNCATE TABLE users, orders CASCADE');
}

async function seedUsers() {
  await db.insertInto('users').values([
    { id: 'user-1', email: 'alice@example.com', name: 'Alice' },
  ]).execute();
}

describe('User API', () => {
  let app = createApp();

  beforeEach(async () => {
    await cleanupTables();
    await seedUsers();
  });

  afterEach(async () => await cleanupTables());

  it('returns a user when found', async () => {
    const res = await request(app).get('/users/user-1').expect(200);
    expect(res.body).toMatchObject({ id: 'user-1', email: 'alice@example.com' });
  });
});
```

### Snippet 4: pytest with TestClient (FastAPI)
```python
# tests/integration/test_user_api.py
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from app.main import app, get_db
from app.models import Base

engine = create_engine("sqlite:///:memory:", connect_args={"check_same_thread": False})
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

def override_get_db():
    db = TestingSessionLocal()
    try:
        yield db
    finally:
        db.close()

app.dependency_overrides[get_db] = override_get_db

@pytest.fixture
def client():
    Base.metadata.create_all(bind=engine)
    yield TestClient(app)
    Base.metadata.drop_all(bind=engine)

def test_get_user(client):
    db = TestingSessionLocal()
    db.execute(text("INSERT INTO users (id, email) VALUES ('1', 'a@b.com')"))
    db.commit()
    response = client.get("/users/1")
    assert response.status_code == 200
    assert response.json()["email"] == "a@b.com"
```

### Snippet 5: FastAPI Test with Testcontainers
```python
# tests/test_with_testcontainers.py
import pytest
from testcontainers.postgres import PostgresContainer
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from app.models import Base

@pytest.fixture(scope="module")
def postgres():
    with PostgresContainer("postgres:16-alpine") as pg:
        engine = create_engine(pg.get_connection_url())
        Base.metadata.create_all(engine)
        yield engine
        Base.metadata.drop_all(engine)

@pytest.fixture
def db_session(postgres):
    Session = sessionmaker(bind=postgres)
    session = Session()
    yield session
    session.rollback()
    session.close()

def test_database_is_postgres(db_session):
    result = db_session.execute(text("SELECT version()"))
    version = result.scalar()
    assert "PostgreSQL" in version
```

### Snippet 6: k6 Load Test Script
```javascript
// tests/performance/load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '1m', target: 10 },
    { duration: '3m', target: 50 },
    { duration: '5m', target: 50 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const res = http.get('http://localhost:3000/users/me', {
    headers: { Authorization: 'Bearer test-token' },
  });
  check(res, { 'status is 200': (r) => r.status === 200 });
  sleep(1);
}
```

### Snippet 7: MSW HTTP Mock Setup
```typescript
// tests/mocks/handlers.ts
import { http, HttpResponse } from 'msw';
import { setupServer } from 'msw/node';

export const handlers = [
  http.get('https://api.stripe.com/v1/customers/:id', ({ params }) => {
    return HttpResponse.json({
      id: params.id,
      email: 'customer@example.com',
    });
  }),

  http.post('https://api.stripe.com/v1/customers', async ({ request }) => {
    const body = await request.json() as { email?: string };
    return HttpResponse.json({ id: 'cus_new', email: body?.email }, { status: 201 });
  }),
];

export const server = setupServer(...handlers);

// tests/setup.ts
import { server } from './mocks/handlers';
beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));
afterEach(() => server.resetHandlers());
afterAll(() => server.close());
```

### Snippet 8: Security Test for BOLA
```typescript
// tests/security/bola.test.ts
import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../../src/app';

describe('BOLA — Broken Object Level Authorization', () => {
  let app: ReturnType<typeof createApp>;
  let aliceToken: string;
  let bobToken: string;
  let aliceOrderId: string;

  beforeEach(async () => {
    app = createApp();
    aliceToken = await createUserAndLogin({ email: 'alice@example.com' });
    bobToken = await createUserAndLogin({ email: 'bob@example.com' });
    aliceOrderId = await createOrder(aliceToken, { item: 'book', price: 20 });
  });

  it('prevents Bob from accessing Alice order', async () => {
    const res = await request(app)
      .get(`/orders/${aliceOrderId}`)
      .set('Authorization', `Bearer ${bobToken}`)
      .expect(403);
    expect(res.body.error).toMatch(/not authorized|forbidden/i);
  });

  it('prevents Bob from updating Alice order', async () => {
    await request(app)
      .patch(`/orders/${aliceOrderId}`)
      .set('Authorization', `Bearer ${bobToken}`)
      .send({ status: 'cancelled' })
      .expect(403);
  });

  it('allows Alice to access her own order', async () => {
    const res = await request(app)
      .get(`/orders/${aliceOrderId}`)
      .set('Authorization', `Bearer ${aliceToken}`)
      .expect(200);
    expect(res.body.item).toBe('book');
  });
});
```

---

## Quick Reference Checklist

Use this when setting up testing for a new project or reviewing test coverage.

**Unit Tests**
- [ ] Test runner configured (Vitest/pytest)
- [ ] Coverage thresholds set (80% line, 70% branch minimum)
- [ ] All business logic functions have unit tests
- [ ] Mock external dependencies (DB, HTTP, file system)
- [ ] Parametrize edge cases (empty, max length, invalid format)

**Integration Tests**
- [ ] All API endpoints tested with real HTTP calls
- [ ] Test database isolated from production/development
- [ ] Cleanup runs between tests (TRUNCATE or rollback)
- [ ] Seed data covers happy path and common error cases
- [ ] Auth middleware tested (valid, expired, missing token)

**Contract Tests**
- [ ] Pact configured for consumer/provider pairs
- [ ] Provider verification runs in CI
- [ ] Broker publishes verification results

**Security Tests**
- [ ] OWASP ZAP runs in CI (baseline or API scan)
- [ ] BOLA tests for all resource endpoints
- [ ] Input validation tests (SQL injection, XSS)
- [ ] Auth bypass tests (missing token, invalid signature)
- [ ] Security headers verified (CSP, HSTS, X-Frame-Options)

**Performance Tests**
- [ ] k6/Artillery scripts for critical paths
- [ ] Load test runs before every major release
- [ ] Baseline metrics established (p50, p95, p99, RPS)
- [ ] Regression detection: fail CI if p95 > baseline + 20%

**E2E Tests**
- [ ] Critical user paths covered (register → login → action → verify)
- [ ] Playwright tests use `data-testid` selectors
- [ ] Tests run in parallel with isolated databases
- [ ] Screenshots on failure captured in CI artifacts
- [ ] Flaky tests identified and fixed (not just retried)

---

*Last updated: auto-generated for kimi-backend skill.*
