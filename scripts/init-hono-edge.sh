#!/bin/bash
set -euo pipefail

# kimi-backend: Hono + Cloudflare Workers + D1 + R2 scaffold
# Usage: bash init-hono-edge.sh my-project

PROJECT_NAME="${1:-hono-edge}"
DIR="$PWD/$PROJECT_NAME"

echo "🔧 Scaffolding Hono Edge API: $PROJECT_NAME"
mkdir -p "$DIR" && cd "$DIR"

# ─── package.json ───
cat > package.json << 'PKG'
{
  "name": "PROJECT_NAME",
  "version": "1.0.0",
  "description": "Hono + Cloudflare Workers + D1 + R2 edge API",
  "type": "module",
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "test": "vitest",
    "format": "prettier --write .",
    "lint": "eslint ."
  },
  "dependencies": {
    "hono": "^4.6.0",
    "zod": "^3.24.0"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^4.20241218.0",
    "@eslint/js": "^9.0.0",
    "eslint": "^9.0.0",
    "prettier": "^3.4.0",
    "typescript": "^5.7.0",
    "vitest": "^3.0.0",
    "wrangler": "^3.95.0"
  }
}
PKG
sed -i.bak "s/PROJECT_NAME/$PROJECT_NAME/g" package.json && rm package.json.bak

# ─── tsconfig.json ───
cat > tsconfig.json << 'TSC'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "bundler",
    "lib": ["ES2022"],
    "types": ["@cloudflare/workers-types"],
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "strictFunctionTypes": true,
    "strictBindCallApply": true,
    "strictPropertyInitialization": true,
    "noImplicitThis": true,
    "alwaysStrict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "outDir": "./dist",
    "rootDir": "./src",
    "declaration": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
TSC

# ─── wrangler.toml ───
cat > wrangler.toml << 'WRANGLER'
name = "PROJECT_NAME"
main = "src/index.ts"
compatibility_date = "2024-12-18"
compatibility_flags = ["nodejs_compat"]

[vars]
APP_NAME = "PROJECT_NAME"
APP_VERSION = "1.0.0"

[[d1_databases]]
binding = "DB"
database_name = "PROJECT_NAME-db"
database_id = "your-database-id-here"

[[r2_buckets]]
binding = "BUCKET"
bucket_name = "PROJECT_NAME-bucket"

[[kv_namespaces]]
binding = "CACHE"
id = "your-kv-namespace-id-here"

[env.staging]
name = "PROJECT_NAME-staging"

[env.production]
name = "PROJECT_NAME-production"
WRANGLER
sed -i.bak "s/PROJECT_NAME/$PROJECT_NAME/g" wrangler.toml && rm wrangler.toml.bak

# ─── src/index.ts ───
mkdir -p src/routes src/middleware src/types
cat > src/index.ts << 'INDEX'
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { logger } from 'hono/logger';
import { prettyJSON } from 'hono/pretty-json';
import { errorHandler } from './middleware/error.js';
import { auth } from './routes/auth.js';
import { users } from './routes/users.js';
import { health } from './routes/health.js';
import type { AppContext } from './types/index.js';

const app = new Hono<AppContext>();

app.use(logger());
app.use(prettyJSON());
app.use(cors({
  origin: ['http://localhost:3000', 'http://localhost:5173'],
  credentials: true,
}));

app.onError(errorHandler);

app.route('/api/v1/health', health);
app.route('/api/v1/auth', auth);
app.route('/api/v1/users', users);

app.get('/', (c) => c.json({ message: 'PROJECT_NAME API', version: '1.0.0' }));

export default app;
INDEX
sed -i.bak "s/PROJECT_NAME/$PROJECT_NAME/g" src/index.ts && rm src/index.ts.bak

# ─── src/types/index.ts ───
cat > src/types/index.ts << 'TYPES'
import type { D1Database, R2Bucket, KVNamespace } from '@cloudflare/workers-types';

export interface Bindings {
  DB: D1Database;
  BUCKET: R2Bucket;
  CACHE: KVNamespace;
  JWT_SECRET: string;
  APP_NAME: string;
  APP_VERSION: string;
}

export interface Variables {
  userId?: string;
  requestId: string;
}

export type AppContext = {
  Bindings: Bindings;
  Variables: Variables;
};
TYPES

# ─── src/middleware/error.ts ───
cat > src/middleware/error.ts << 'ERROR'
import type { ErrorHandler } from 'hono';
import type { AppContext } from '../types/index.js';

export const errorHandler: ErrorHandler<AppContext> = (err, c) => {
  console.error('Error:', err);
  const requestId = c.get('requestId') ?? 'unknown';
  
  if (err.message?.includes('Unauthorized')) {
    return c.json({ error: 'Unauthorized', code: 'UNAUTHORIZED', request_id: requestId }, 401);
  }
  if (err.message?.includes('Not found')) {
    return c.json({ error: 'Not found', code: 'NOT_FOUND', request_id: requestId }, 404);
  }
  if (err.message?.includes('Rate limit')) {
    return c.json({ error: 'Rate limit exceeded', code: 'RATE_LIMIT', request_id: requestId }, 429);
  }
  
  return c.json({ error: 'Internal server error', code: 'INTERNAL_ERROR', request_id: requestId }, 500);
};
ERROR

# ─── src/middleware/auth.ts ───
cat > src/middleware/auth.ts << 'AUTHMW'
import { createMiddleware } from 'hono/factory';
import { jwt } from 'hono/jwt';
import type { AppContext } from '../types/index.js';

export const authenticate = createMiddleware<AppContext>(async (c, next) => {
  const authHeader = c.req.header('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return c.json({ error: 'Missing token', code: 'MISSING_TOKEN' }, 401);
  }
  
  const token = authHeader.slice(7);
  try {
    const { jwtVerify, importSPKI } = await import('jose');
    // In production: use RS256 with public key from JWKS
    // For simplicity, using HS256 with shared secret (set via wrangler secret)
    const { payload } = await jwtVerify(token, new TextEncoder().encode(c.env.JWT_SECRET));
    c.set('userId', payload.sub as string);
  } catch {
    return c.json({ error: 'Invalid token', code: 'INVALID_TOKEN' }, 401);
  }
  
  await next();
});
AUTHMW

# ─── src/routes/health.ts ───
cat > src/routes/health.ts << 'HEALTH'
import { Hono } from 'hono';
import type { AppContext } from '../types/index.js';

const health = new Hono<AppContext>();

health.get('/live', (c) => c.json({ status: 'alive' }));

health.get('/ready', async (c) => {
  try {
    await c.env.DB.prepare('SELECT 1').first();
    return c.json({ status: 'ready' });
  } catch (e) {
    return c.json({ status: 'not_ready', detail: String(e) }, 503);
  }
});

export { health };
HEALTH

# ─── src/routes/auth.ts ───
cat > src/routes/auth.ts << 'AUTH'
import { Hono } from 'hono';
import { z } from 'zod';
import { SignJWT } from 'jose';
import { bcrypt } from 'hono/bcrypt';
import type { AppContext } from '../types/index.js';

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8),
});

const auth = new Hono<AppContext>();

auth.post('/login', async (c) => {
  const body = await c.req.json();
  const result = loginSchema.safeParse(body);
  if (!result.success) {
    return c.json({ error: 'Invalid input', code: 'VALIDATION_ERROR', details: result.error.flatten() }, 400);
  }
  
  const { email, password } = result.data;
  const user = await c.env.DB.prepare('SELECT id, email, password_hash FROM users WHERE email = ?')
    .bind(email)
    .first<{ id: string; email: string; password_hash: string }>();
  
  if (!user || !(await bcrypt.verify(password, user.password_hash))) {
    return c.json({ error: 'Invalid credentials', code: 'INVALID_CREDENTIALS' }, 401);
  }
  
  const token = await new SignJWT({ sub: user.id, email: user.email })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime('15m')
    .sign(new TextEncoder().encode(c.env.JWT_SECRET));
  
  return c.json({ access_token: token, token_type: 'bearer', expires_in: 900 });
});

auth.post('/register', async (c) => {
  const body = await c.req.json();
  const result = loginSchema.safeParse(body);
  if (!result.success) {
    return c.json({ error: 'Invalid input', code: 'VALIDATION_ERROR', details: result.error.flatten() }, 400);
  }
  
  const { email, password } = result.data;
  const existing = await c.env.DB.prepare('SELECT id FROM users WHERE email = ?').bind(email).first();
  if (existing) {
    return c.json({ error: 'Email already registered', code: 'CONFLICT' }, 409);
  }
  
  const passwordHash = await bcrypt.hash(password);
  const id = crypto.randomUUID();
  await c.env.DB.prepare('INSERT INTO users (id, email, password_hash, role) VALUES (?, ?, ?, ?)')
    .bind(id, email, passwordHash, 'user')
    .run();
  
  const token = await new SignJWT({ sub: id, email })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime('15m')
    .sign(new TextEncoder().encode(c.env.JWT_SECRET));
  
  return c.json({ access_token: token, token_type: 'bearer', expires_in: 900 }, 201);
});

export { auth };
AUTH

# ─── src/routes/users.ts ───
cat > src/routes/users.ts << 'USERS'
import { Hono } from 'hono';
import { authenticate } from '../middleware/auth.js';
import type { AppContext } from '../types/index.js';

const users = new Hono<AppContext>();

users.get('/me', authenticate, async (c) => {
  const userId = c.get('userId');
  const user = await c.env.DB.prepare(
    'SELECT id, email, name, role, created_at FROM users WHERE id = ?'
  ).bind(userId).first();
  
  if (!user) return c.json({ error: 'Not found', code: 'NOT_FOUND' }, 404);
  return c.json(user);
});

users.get('/:id', authenticate, async (c) => {
  const userId = c.get('userId');
  const requestedId = c.req.param('id');
  
  // BOLA prevention
  if (userId !== requestedId) {
    return c.json({ error: 'Not found', code: 'NOT_FOUND' }, 404);
  }
  
  const user = await c.env.DB.prepare(
    'SELECT id, email, name, role, created_at FROM users WHERE id = ?'
  ).bind(requestedId).first();
  
  if (!user) return c.json({ error: 'Not found', code: 'NOT_FOUND' }, 404);
  return c.json(user);
});

export { users };
USERS

# ─── src/routes/upload.ts (R2 example) ───
cat > src/routes/upload.ts << 'UPLOAD'
import { Hono } from 'hono';
import { authenticate } from '../middleware/auth.js';
import type { AppContext } from '../types/index.js';

const upload = new Hono<AppContext>();

upload.post('/image', authenticate, async (c) => {
  const body = await c.req.blob();
  if (body.size > 5 * 1024 * 1024) {
    return c.json({ error: 'File too large', code: 'FILE_TOO_LARGE' }, 413);
  }
  
  const key = `uploads/${crypto.randomUUID()}`;
  await c.env.BUCKET.put(key, body, { httpMetadata: { contentType: body.type } });
  
  return c.json({ key, url: `https://${c.env.BUCKET.name}.r2.cloudflarestorage.com/${key}` }, 201);
});

export { upload };
UPLOAD

# ─── migrations/001_init.sql ───
mkdir -p migrations
cat > migrations/001_init.sql << 'MIGRATE'
-- D1 schema: users and audit_logs
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  name TEXT,
  password_hash TEXT NOT NULL,
  role TEXT DEFAULT 'user',
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);

CREATE TABLE IF NOT EXISTS audit_logs (
  id TEXT PRIMARY KEY,
  action TEXT NOT NULL,
  user_id TEXT,
  metadata TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id);
MIGRATE

# ─── .env.example ───
cat > .env.example << 'ENV'
JWT_SECRET=change-me-in-production-min-32-characters-long
ENV

# ─── .env ───
cp .env.example .env

# ─── .gitignore ───
cat > .gitignore << 'GITIGNORE'
node_modules
dist
.env
.env.local
*.log
.wrangler
.DS_Store
.vscode
.idea
GITIGNORE

# ─── .prettierrc ───
cat > .prettierrc << 'PRETTIER'
{
  "semi": true,
  "singleQuote": true,
  "trailingComma": "es5",
  "tabWidth": 2,
  "printWidth": 100
}
PRETTIER

# ─── .eslintrc.json ───
cat > .eslintrc.json << 'ESLINT'
{
  "extends": ["eslint:recommended"],
  "parserOptions": { "ecmaVersion": 2022, "sourceType": "module" },
  "env": { "es2022": true, "worker": true },
  "rules": {}
}
ESLINT

# ─── vitest.config.ts ───
cat > vitest.config.ts << 'VITEST'
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { environment: 'miniflare', globals: true },
});
VITEST

# ─── tests/index.test.ts ───
mkdir -p tests
cat > tests/index.test.ts << 'TEST'
import { describe, it, expect } from 'vitest';
import app from '../src/index';

describe('API', () => {
  it('GET / returns hello', async () => {
    const res = await app.request('/');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.message).toContain('API');
  });

  it('GET /api/v1/health/live returns alive', async () => {
    const res = await app.request('/api/v1/health/live');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe('alive');
  });
});
TEST

echo ""
echo "✅ Hono Edge scaffold complete: $PROJECT_NAME"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npm install"
echo "  wrangler d1 create $PROJECT_NAME-db"
echo "  wrangler d1 migrations apply $PROJECT_NAME-db --local"
echo "  # Update wrangler.toml with your database_id"
echo "  npm run dev"
echo ""
echo "To deploy:"
echo "  wrangler secret put JWT_SECRET"
echo "  npm run deploy"
