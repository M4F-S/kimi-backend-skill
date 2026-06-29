# DevOps Reference for kimi-backend

> Production patterns for containerization, CI/CD, GitOps, monitoring, and deployment.

---

## Table of Contents

| # | Section | Description |
|---|---|---|
| 1 | [Docker Best Practices](#1-docker-best-practices) | Multi-stage Dockerfiles for Node.js and Python |
| 2 | [Docker Compose](#2-docker-compose) | Local development with PostgreSQL + Redis |
| 3 | [CI/CD Pipeline (GitHub Actions)](#3-cicd-pipeline-github-actions) | Lint → test → build → scan → push → deploy |
| 4 | [GitOps with ArgoCD](#4-gitops-with-argocd) | Application manifests, sync policies, Kustomize |
| 5 | [Monitoring](#5-monitoring) | Logs, metrics, and traces (three pillars) |
| 6 | [Health Checks](#6-health-checks) | Liveness, readiness, and startup probes |
| 7 | [Environment Management](#7-environment-management) | Validation, secrets separation, runtime config |
| 8 | [Deployment Patterns](#8-deployment-patterns) | Blue-green, rolling, canary, feature flags |
| 9 | [Infrastructure as Code](#9-infrastructure-as-code) | Terraform, Pulumi, Cloudflare Workers |
| 10 | [Code Snippets](#10-code-snippets) | 8+ ready-to-use configurations |

---

## 1. Docker Best Practices

### 1.1 General Principles

| Principle | Why | Implementation |
|---|---|---|
| Multi-stage builds | Smaller final image, no build tools in production | `FROM ... AS builder` |
| Minimal base images | Smaller attack surface, faster pulls | `node:20-alpine`, `python:3.11-slim` |
| Non-root user | Container security best practice | `USER appuser` or numeric UID |
| Health checks | Container orchestration can detect and restart unhealthy containers | `HEALTHCHECK` directive |
| Layer caching | Reorder instructions to maximize cache hits | Copy `package-lock.json` before `package.json` |
| `.dockerignore` | Prevents unnecessary files from entering the build context | See Section 10 |

### 1.2 Multi-stage Dockerfile for Node.js (NestJS)

```dockerfile
# syntax=docker/dockerfile:1
# ---- Build stage ----
FROM node:20-alpine AS builder

WORKDIR /build

# Install build deps for native modules (if any)
RUN apk add --no-cache python3 make g++

# Copy dependency definitions first (layer caching)
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

# Copy source and build
COPY . .
RUN npm run build

# ---- Production stage ----
FROM node:20-alpine AS production

# Security: run as non-root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Set NODE_ENV early
ENV NODE_ENV=production

# Copy only production dependencies
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --only=production && \
    npm cache clean --force

# Copy built artifacts from builder
COPY --from=builder /build/dist ./dist

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:3000/health || exit 1

USER appuser

EXPOSE 3000

CMD ["node", "dist/main.js"]
```

### 1.3 Multi-stage Dockerfile for Python (FastAPI)

```dockerfile
# syntax=docker/dockerfile:1
# ---- Build stage ----
FROM python:3.11-slim AS builder

WORKDIR /build

# Install system dependencies for build
RUN apt-get update && apt-get install -y --no-install-recommends gcc && \
    rm -rf /var/lib/apt/lists/*

# Install dependencies into a virtual environment
COPY requirements.txt .
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# Copy source and build (if needed)
COPY . .

# ---- Production stage ----
FROM python:3.11-slim AS production

# Security: run as non-root
RUN groupadd -r appgroup && useradd -r -g appgroup appuser

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PATH="/opt/venv/bin:$PATH"

# Copy only the virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /build/app ./app

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

USER appuser

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

---

## 2. Docker Compose

### 2.1 Local Development Stack

```yaml
# docker-compose.yml
version: "3.8"

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
      target: production
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=development
      - DATABASE_URL=postgres://postgres:postgres@db:5432/appdb
      - REDIS_URL=redis://redis:6379
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - .:/app
      - /app/node_modules
    command: npm run start:dev
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: appdb
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Optional: admin tools
  pgadmin:
    image: dpage/pgadmin4:latest
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@local.dev
      PGADMIN_DEFAULT_PASSWORD: admin
    ports:
      - "5050:80"
    depends_on:
      - db

volumes:
  postgres_data:
```

---

## 3. CI/CD Pipeline (GitHub Actions)

### 3.1 Complete Workflow (Node.js)

```yaml
# .github/workflows/backend.yml
name: Backend CI/CD

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'
      - run: npm ci
      - run: npm run lint
      - run: npm run type-check

  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: testdb
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432
      redis:
        image: redis:7-alpine
        ports:
          - 6379:6379
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'
      - run: npm ci
      - run: npm run test:cov
        env:
          DATABASE_URL: postgres://postgres:postgres@localhost:5432/testdb
          REDIS_URL: redis://localhost:6379
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: coverage
          path: coverage/

  build:
    runs-on: ubuntu-latest
    needs: [lint, test]
    steps:
      - uses: actions/checkout@v4
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: Log in to Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=ref,event=branch
            type=sha,prefix=,suffix=,format=short
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  security:
    runs-on: ubuntu-latest
    needs: build
    if: github.event_name != 'pull_request'
    steps:
      - uses: actions/checkout@v4
      - name: Run Trivy vulnerability scanner
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
          format: 'sarif'
          output: 'trivy-results.sarif'
      - name: Upload scan results
        uses: github/codeql-action/upload-sarif@v2
        if: always()
        with:
          sarif_file: 'trivy-results.sarif'

  deploy:
    runs-on: ubuntu-latest
    needs: [build, security]
    if: github.ref == 'refs/heads/main'
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: Deploy to Kubernetes
        run: |
          echo "kubectl set image deployment/app app=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}"
          # Add your actual kubectl / helm / argocd commands here
```

### 3.2 Complete Workflow (Python / FastAPI)

```yaml
# .github/workflows/python-backend.yml
name: Python Backend CI/CD

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: pip install ruff mypy
      - run: ruff check .
      - run: mypy app/

  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: testdb
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: pip install -r requirements.txt
      - run: pytest --cov=app --cov-report=xml
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost:5432/testdb
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: coverage
          path: coverage.xml

  build:
    runs-on: ubuntu-latest
    needs: [lint, test]
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

### 3.3 Dependabot Configuration

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 10
    reviewers:
      - "team/backend"
    labels:
      - "dependencies"
      - "backend"

  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"
      - "docker"

  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"
      - "ci-cd"
```

---

## 4. GitOps with ArgoCD

### 4.1 ArgoCD Application Manifest

```yaml
# k8s/argocd/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backend-api
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: main
    path: k8s/overlays/production
    kustomize:
      images:
        - ghcr.io/your-org/backend-api:${IMAGE_TAG}
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 10
```

### 4.2 Kustomize Structure

```
k8s/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   └── kustomization.yaml
└── overlays/
    ├── development/
    │   ├── kustomization.yaml
    │   ├── replica-count.yaml
    │   └── resource-limits.yaml
    └── production/
        ├── kustomization.yaml
        ├── replica-count.yaml
        ├── resource-limits.yaml
        └── hpa.yaml
```

```yaml
# k8s/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - configmap.yaml

namespace: default

commonLabels:
  app: backend-api
  tier: api

images:
  - name: backend-api
    newName: ghcr.io/your-org/backend-api
    newTag: latest
```

### 4.3 Secret Management with External Secrets Operator

```yaml
# k8s/base/external-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: backend-api-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: backend-api-secrets
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: production/backend-api
        property: database_url
    - secretKey: JWT_SECRET
      remoteRef:
        key: production/backend-api
        property: jwt_secret
    - secretKey: REDIS_PASSWORD
      remoteRef:
        key: production/backend-api
        property: redis_password
```

---

## 5. Monitoring

### 5.1 Three Pillars

| Pillar | Tool | Purpose | Key Data |
|---|---|---|---|
| Logs | Pino | Structured, queryable log output | Timestamp, level, message, trace_id, redacted fields |
| Metrics | Prometheus + Grafana | RED method (Rate, Errors, Duration) | HTTP request rate, latency histogram, error rate |
| Traces | OpenTelemetry | Distributed request flow | Trace ID, span duration, service dependencies |

### 5.2 Pino Logger Configuration (Node.js / NestJS)

```typescript
// src/common/logger/pino.config.ts
import { LoggerModule } from 'nestjs-pino';

const sensitiveFields = ['password', 'token', 'secret', 'authorization', 'apiKey', 'cookie'];

export const PinoConfig = LoggerModule.forRoot({
  pinoHttp: {
    level: process.env.NODE_ENV === 'production' ? 'info' : 'debug',
    transport:
      process.env.NODE_ENV !== 'production'
        ? { target: 'pino-pretty', options: { singleLine: true } }
        : undefined,
    redact: {
      paths: sensitiveFields.map(f => `req.headers.${f}`),
      censor: '[REDACTED]',
    },
    serializers: {
      req(req) {
        return {
          id: req.id,
          method: req.method,
          url: req.url,
          headers: req.headers,
        };
      },
      res(res) {
        return {
          statusCode: res.statusCode,
        };
      },
    },
  },
});
```

### 5.3 Prometheus Metrics Middleware (Node.js)

```typescript
// src/common/metrics/metrics.middleware.ts
import { Injectable, NestMiddleware } from '@nestjs/common';
import { Request, Response, NextFunction } from 'express';
import { Counter, Histogram, register } from 'prom-client';

const httpRequestCounter = new Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
});

const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5],
});

@Injectable()
export class MetricsMiddleware implements NestMiddleware {
  use(req: Request, res: Response, next: NextFunction) {
    const start = Date.now();

    res.on('finish', () => {
      const duration = (Date.now() - start) / 1000;
      const route = req.route?.path || req.path;
      const labels = {
        method: req.method,
        route,
        status_code: res.statusCode.toString(),
      };
      httpRequestCounter.inc(labels);
      httpRequestDuration.observe(labels, duration);
    });

    next();
  }
}

// Metrics endpoint
// GET /metrics -> register.metrics()
```

### 5.4 OpenTelemetry Collector Configuration

```yaml
# otel-collector-config.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024

exporters:
  prometheus:
    endpoint: "0.0.0.0:8889"
  otlp/jaeger:
    endpoint: jaeger-collector:4317
    tls:
      insecure: true
  logging:
    loglevel: debug

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/jaeger, logging]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [prometheus]
```

---

## 6. Health Checks

### 6.1 Probe Types

| Probe | Purpose | Typical Endpoint | Failure Action |
|---|---|---|---|
| Liveness | Is the app running? | `/health/live` | Kubernetes restarts container |
| Readiness | Is it ready to accept traffic? | `/health/ready` | Kubernetes removes from service endpoints |
| Startup | Is the slow-starting app initialized? | `/health/startup` | Disables liveness/readiness until passed |

### 6.2 Health Check Endpoint (Node.js / NestJS)

```typescript
// src/health/health.controller.ts
import { Controller, Get } from '@nestjs/common';
import { HealthCheck, HealthCheckService, TypeOrmHealthIndicator, RedisHealthIndicator } from '@nestjs/terminus';

@Controller('health')
export class HealthController {
  constructor(
    private health: HealthCheckService,
    private db: TypeOrmHealthIndicator,
    private redis: RedisHealthIndicator,
  ) {}

  @Get('live')
  @HealthCheck()
  liveness() {
    return this.health.check([]);
  }

  @Get('ready')
  @HealthCheck()
  async readiness() {
    return this.health.check([
      () => this.db.pingCheck('database', { timeout: 3000 }),
      () => this.redis.pingCheck('redis', { timeout: 3000 }),
    ]);
  }

  @Get('startup')
  @HealthCheck()
  async startup() {
    return this.health.check([
      () => this.db.pingCheck('database', { timeout: 5000 }),
      () => this.redis.pingCheck('redis', { timeout: 5000 }),
    ]);
  }
}
```

### 6.3 Kubernetes Deployment with Probes

```yaml
# k8s/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      containers:
        - name: api
          image: backend-api
          ports:
            - containerPort: 3000
          livenessProbe:
            httpGet:
              path: /health/live
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          startupProbe:
            httpGet:
              path: /health/startup
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 30
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
```

---

## 7. Environment Management

### 7.1 Validation with Zod (Node.js)

```typescript
// src/config/env.validation.ts
import { z } from 'zod';

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  PORT: z.string().transform(Number).default('3000'),
  DATABASE_URL: z.string().url(),
  REDIS_URL: z.string().url(),
  JWT_SECRET: z.string().min(32),
  JWT_EXPIRES_IN: z.string().default('1h'),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
});

export type Env = z.infer<typeof envSchema>;

export function validateEnv(config: Record<string, unknown>): Env {
  const result = envSchema.safeParse(config);
  if (!result.success) {
    console.error('Invalid environment variables:', result.error.format());
    process.exit(1);
  }
  return result.data;
}
```

### 7.2 Secrets vs Config Separation

| Type | Examples | Storage | Rotation |
|---|---|---|---|
| Config (non-sensitive) | `PORT`, `NODE_ENV`, `LOG_LEVEL` | ConfigMap, `.env` | Infrequent |
| Secrets (sensitive) | `DATABASE_URL`, `JWT_SECRET`, `API_KEYS` | External Secrets Operator, Vault, AWS Secrets Manager | Regular |

### 7.3 .env.example Template

```bash
# Application
NODE_ENV=development
PORT=3000
LOG_LEVEL=debug

# Database
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/appdb
DATABASE_POOL_SIZE=10

# Cache
REDIS_URL=redis://localhost:6379
REDIS_PASSWORD=

# Security
JWT_SECRET=replace-with-min-32-char-random-string
JWT_EXPIRES_IN=1h
BCRYPT_ROUNDS=12

# External Services
STRIPE_API_KEY=sk_test_xxx
SENDGRID_API_KEY=SG.xxx

# Monitoring
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
PROMETHEUS_PORT=9090
```

---

## 8. Deployment Patterns

### 8.1 Comparison Table

| Pattern | Risk | Complexity | Best For | Rollback Speed |
|---|---|---|---|---|
| Rolling | Medium | Low | Standard updates, backward-compatible changes | Medium (new rollout) |
| Blue-Green | Low | Medium | Critical releases, zero-downtime deployments | Fast (switch traffic) |
| Canary | Low | High | High-risk changes, gradual user exposure | Fast (traffic shift) |
| Feature Flags | Very Low | High | Trunk-based development, A/B testing | Instant (toggle off) |

### 8.2 Decision Guide

```
Is the change backward-compatible?
  ├── YES → Use Rolling Deployment
  └── NO → Is it a high-risk change?
      ├── YES → Use Canary Deployment (5% → 25% → 100%)
      └── NO → Use Blue-Green Deployment

Do you need to test with real users?
  └── YES → Use Feature Flags (launch darkly, gradual rollout)
```

### 8.3 Blue-Green with Kubernetes

```yaml
# k8s/overlays/production/blue-green-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-api
spec:
  selector:
    app: backend-api
    version: blue  # or green
  ports:
    - port: 80
      targetPort: 3000
```

To switch: `kubectl patch service backend-api -p '{"spec":{"selector":{"version":"green"}}}'`

---

## 9. Infrastructure as Code

### 9.1 Terraform Basics (AWS)

```hcl
# terraform/main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = var.environment == "development"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "${var.project_name}-cluster"
  cluster_version = "1.28"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      desired_size = 2
      min_size     = 1
      max_size     = 5
      instance_types = ["t3.medium"]
    }
  }
}
```

### 9.2 Pulumi Alternative (TypeScript)

```typescript
// pulumi/index.ts
import * as aws from '@pulumi/aws';
import * as eks from '@pulumi/eks';

const vpc = new aws.ec2.Vpc('main', {
  cidrBlock: '10.0.0.0/16',
  tags: { Name: 'main-vpc' },
});

const cluster = new eks.Cluster('main', {
  vpcId: vpc.id,
  subnetIds: vpc.publicSubnetIds,
  instanceType: 't3.medium',
  desiredCapacity: 2,
  minSize: 1,
  maxSize: 5,
});

export const kubeconfig = cluster.kubeconfig;
```

### 9.3 Cloudflare Workers via Wrangler

```toml
# wrangler.toml
name = "backend-api"
main = "src/index.ts"
compatibility_date = "2024-01-01"

[env.production]
routes = [
  { pattern = "api.example.com/*", zone_name = "example.com" }
]

[env.production.vars]
ENVIRONMENT = "production"

[[env.production.kv_namespaces]]
binding = "CACHE"
id = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

```bash
# Deploy commands
wrangler deploy --env production
wrangler tail --env production
```

---

## 10. Code Snippets

### Snippet 1: Multi-stage Dockerfile (Node.js / NestJS)

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /build
RUN apk add --no-cache python3 make g++
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts
COPY . .
RUN npm run build

FROM node:20-alpine AS production
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --only=production && npm cache clean --force
COPY --from=builder /build/dist ./dist
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:3000/health || exit 1
USER appuser
EXPOSE 3000
CMD ["node", "dist/main.js"]
```

### Snippet 2: Multi-stage Dockerfile (Python / FastAPI)

```dockerfile
FROM python:3.11-slim AS builder
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN python -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt
COPY . .

FROM python:3.11-slim AS production
RUN groupadd -r appgroup && useradd -r -g appgroup appuser
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PATH="/opt/venv/bin:$PATH"
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /build/app ./app
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1
USER appuser
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Snippet 3: docker-compose.yml (Full Stack)

```yaml
version: "3.8"
services:
  app:
    build: .
    ports: ["3000:3000"]
    environment:
      - DATABASE_URL=postgres://postgres:postgres@db:5432/appdb
      - REDIS_URL=redis://redis:6379
    depends_on:
      db: { condition: service_healthy }
      redis: { condition: service_healthy }
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: appdb
    volumes: [postgres_data:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
volumes:
  postgres_data:
```

### Snippet 4: GitHub Actions Workflow (Node.js)

```yaml
name: Backend CI/CD
on:
  push: { branches: [main, develop] }
  pull_request: { branches: [main] }
env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: 'npm' }
      - run: npm ci
      - run: npm run lint
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: 'npm' }
      - run: npm ci
      - run: npm run test:cov
  build:
    runs-on: ubuntu-latest
    needs: [lint, test]
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { registry: ${{ env.REGISTRY }}, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
      - uses: docker/metadata-action@v5
        id: meta
        with: { images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }} }
      - uses: docker/build-push-action@v5
        with: { context: ., push: true, tags: ${{ steps.meta.outputs.tags }}, cache-from: type=gha, cache-to: type=gha,mode=max }
```

### Snippet 5: Pino Logger Config (Node.js)

```typescript
import { LoggerModule } from 'nestjs-pino';

const redactPaths = ['password', 'token', 'secret', 'authorization', 'apiKey', 'cookie']
  .map(f => `req.headers.${f}`);

export const PinoConfig = LoggerModule.forRoot({
  pinoHttp: {
    level: process.env.NODE_ENV === 'production' ? 'info' : 'debug',
    transport: process.env.NODE_ENV !== 'production'
      ? { target: 'pino-pretty', options: { singleLine: true } }
      : undefined,
    redact: { paths: redactPaths, censor: '[REDACTED]' },
    serializers: {
      req: (req) => ({ id: req.id, method: req.method, url: req.url }),
      res: (res) => ({ statusCode: res.statusCode }),
    },
  },
});
```

### Snippet 6: Prometheus Metrics Middleware (Node.js)

```typescript
import { Counter, Histogram } from 'prom-client';

const httpRequestCounter = new Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
});

const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5],
});

export function metricsMiddleware(req, res, next) {
  const start = Date.now();
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    const labels = { method: req.method, route: req.route?.path || req.path, status_code: res.statusCode };
    httpRequestCounter.inc(labels);
    httpRequestDuration.observe(labels, duration);
  });
  next();
}
```

### Snippet 7: Health Check Endpoint (Node.js / NestJS)

```typescript
import { Controller, Get } from '@nestjs/common';
import { HealthCheck, HealthCheckService, TypeOrmHealthIndicator, RedisHealthIndicator } from '@nestjs/terminus';

@Controller('health')
export class HealthController {
  constructor(private health: HealthCheckService, private db: TypeOrmHealthIndicator, private redis: RedisHealthIndicator) {}

  @Get('live')  @HealthCheck()  liveness() { return this.health.check([]); }
  @Get('ready')  @HealthCheck()  async readiness() { return this.health.check([
    () => this.db.pingCheck('database', { timeout: 3000 }),
    () => this.redis.pingCheck('redis', { timeout: 3000 }),
  ]); }
  @Get('startup')  @HealthCheck()  async startup() { return this.health.check([
    () => this.db.pingCheck('database', { timeout: 5000 }),
    () => this.redis.pingCheck('redis', { timeout: 5000 }),
  ]); }
}
```

### Snippet 8: ArgoCD Application Manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backend-api
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: main
    path: k8s/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated: { prune: true, selfHeal: true, allowEmpty: false }
    syncOptions: [CreateNamespace=true, PrunePropagationPolicy=foreground, PruneLast=true]
    retry: { limit: 5, backoff: { duration: 5s, factor: 2, maxDuration: 3m } }
  revisionHistoryLimit: 10
```

### Snippet 9: .dockerignore

```
node_modules
npm-debug.log
Dockerfile
.dockerignore
.git
.gitignore
README.md
.env
.env.*
.vscode
.idea
coverage
.nyc_output
dist
build
*.md
.github
*.test.ts
*.spec.ts
```

### Snippet 10: Terraform AWS VPC + EKS

```hcl
terraform {
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } }
}
provider "aws" { region = var.aws_region }

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"
  azs = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  enable_nat_gateway = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"
  cluster_name = "${var.project_name}-cluster"
  cluster_version = "1.28"
  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  eks_managed_node_groups = {
    default = { desired_size = 2, min_size = 1, max_size = 5, instance_types = ["t3.medium"] }
  }
}
```

---

## Quick Reference Checklist

| Task | Tool | Key File |
|---|---|---|
| Containerize app | Docker | `Dockerfile` |
| Local development | Docker Compose | `docker-compose.yml` |
| CI/CD pipeline | GitHub Actions | `.github/workflows/backend.yml` |
| GitOps deployment | ArgoCD | `k8s/argocd/application.yaml` |
| Structured logging | Pino | `src/common/logger/pino.config.ts` |
| Metrics collection | Prometheus | `src/common/metrics/metrics.middleware.ts` |
| Distributed tracing | OpenTelemetry | `otel-collector-config.yaml` |
| Health checks | `@nestjs/terminus` | `src/health/health.controller.ts` |
| Environment validation | Zod | `src/config/env.validation.ts` |
| Infrastructure | Terraform | `terraform/main.tf` |
| Secret management | External Secrets Operator | `k8s/base/external-secret.yaml` |
| Dependency updates | Dependabot | `.github/dependabot.yml` |

---

*End of DevOps Reference for kimi-backend*
