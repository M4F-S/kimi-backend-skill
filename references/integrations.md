# Integration Patterns Reference

Production-ready patterns for payment, email, storage, search, notifications, webhooks, and third-party API integrations.

---

## Table of Contents

1. [Payment Integration (Stripe)](#1-payment-integration-stripe)
2. [Email Integration](#2-email-integration)
3. [File Storage (S3 / R2)](#3-file-storage-s3--r2)
4. [Search Integration](#4-search-integration)
5. [Notification System](#5-notification-system)
6. [Webhook Patterns](#6-webhook-patterns)
7. [Third-party API Integration](#7-third-party-api-integration)
8. [Code Snippets Index](#8-code-snippets-index)

---

## 1. Payment Integration (Stripe)

### 1.1 PaymentIntent Flow

| Step | Responsibility | Pattern |
|------|---------------|---------|
| Create PaymentIntent | Server | Always on backend; never expose secret keys to client |
| Confirm payment | Client | Use Stripe.js with `client_secret` |
| Fulfill order | Server | Only after `payment_intent.succeeded` webhook |

### 1.2 Creating a PaymentIntent (Server)

```typescript
import Stripe from 'stripe';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: '2024-06-20',
});

interface CreatePaymentIntentParams {
  amount: number;
  currency: string;
  customerId?: string;
  metadata?: Record<string, string>;
}

async function createPaymentIntent(
  params: CreatePaymentIntentParams
): Promise<{ clientSecret: string; paymentIntentId: string }> {
  const paymentIntent = await stripe.paymentIntents.create({
    amount: params.amount,
    currency: params.currency,
    customer: params.customerId,
    metadata: params.metadata,
    automatic_payment_methods: { enabled: true },
  });

  return {
    clientSecret: paymentIntent.client_secret!,
    paymentIntentId: paymentIntent.id,
  };
}
```

### 1.3 Webhook Handler with Signature Verification & Idempotency

```typescript
import Stripe from 'stripe';
import express, { Request, Response } from 'express';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, { apiVersion: '2024-06-20' });
const endpointSecret = process.env.STRIPE_WEBHOOK_SECRET!;
const app = express();

app.post('/webhooks/stripe', express.raw({ type: 'application/json' }), async (req, res) => {
  const signature = req.headers['stripe-signature'] as string;
  let event: Stripe.Event;

  try {
    event = stripe.webhooks.constructEvent(req.body, signature, endpointSecret);
  } catch (err: any) {
    console.error(`Webhook signature verification failed: ${err.message}`);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  res.status(200).json({ received: true }); // Acknowledge immediately
  await processStripeEvent(event); // Process asynchronously
});

async function processStripeEvent(event: Stripe.Event): Promise<void> {
  if (await isEventProcessed(event.id)) {
    console.log(`Event ${event.id} already processed; skipping.`);
    return;
  }

  switch (event.type) {
    case 'payment_intent.succeeded': {
      const pi = event.data.object as Stripe.PaymentIntent;
      await fulfillOrder(pi);
      break;
    }
    case 'payment_intent.payment_failed': {
      const pi = event.data.object as Stripe.PaymentIntent;
      await handlePaymentFailure(pi);
      break;
    }
    case 'charge.refunded': {
      const charge = event.data.object as Stripe.Charge;
      await handleRefund(charge);
      break;
    }
    case 'invoice.payment_succeeded': {
      const invoice = event.data.object as Stripe.Invoice;
      await handleSubscriptionPayment(invoice);
      break;
    }
    default:
      console.log(`Unhandled event type: ${event.type}`);
  }

  await markEventProcessed(event.id);
}

async function fulfillOrder(pi: Stripe.PaymentIntent): Promise<void> {
  const orderId = pi.metadata?.orderId;
  if (!orderId) return;

  await db.transaction(async (trx) => {
    const order = await trx.orders.findByIdForUpdate(orderId);
    if (order.status === 'paid') return; // Idempotent
    await trx.orders.update(orderId, { status: 'paid', paidAt: new Date() });
    await trx.inventory.decrement(order.productId, order.quantity);
    await enqueueEmail('order-confirmation', { orderId, customerEmail: order.email });
  });
}

async function handlePaymentFailure(pi: Stripe.PaymentIntent): Promise<void> {
  const orderId = pi.metadata?.orderId;
  if (orderId) {
    await db.orders.update(orderId, {
      status: 'payment_failed',
      failureMessage: pi.last_payment_error?.message,
    });
  }
}

async function handleRefund(charge: Stripe.Charge): Promise<void> {
  const orderId = charge.metadata?.orderId;
  if (orderId) {
    await db.orders.update(orderId, { status: 'refunded', refundedAt: new Date() });
    await enqueueEmail('refund-confirmation', { orderId, amount: charge.amount_refunded });
  }
}
```

### 1.4 Subscription Basics

Stripe model: **Product → Price → Subscription**.

```typescript
async function createSubscription(customerId: string, priceId: string): Promise<Stripe.Subscription> {
  return stripe.subscriptions.create({
    customer: customerId,
    items: [{ price: priceId }],
    payment_behavior: 'default_incomplete',
    expand: ['latest_invoice.payment_intent'],
  });
}
```

---

## 2. Email Integration

### 2.1 Transactional Email Providers

| Provider | Best For | Free Tier | Strength | Weakness |
|----------|----------|-----------|----------|----------|
| **Resend** | Startups | 3,000/mo | Great DX, modern API | Fewer enterprise features |
| **SendGrid** | Scale | 100/day | Mature, detailed analytics | Complex UI |
| **Amazon SES** | Cost at scale | 62K/mo (EC2) | Cheapest | Setup complexity |
| **Postmark** | Deliverability | 100/mo | Best deliverability | Higher cost |

### 2.2 Queue-Based Email Sending (BullMQ + Resend)

**Never send emails synchronously in the request path.**

```typescript
import { Queue, Worker } from 'bullmq';
import { Resend } from 'resend';

const resend = new Resend(process.env.RESEND_API_KEY);

const emailQueue = new Queue('email', {
  connection: { host: process.env.REDIS_HOST, port: 6379 },
  defaultJobOptions: {
    attempts: 5,
    backoff: { type: 'exponential', delay: 2000 },
    removeOnComplete: { age: 86400 },
    removeOnFail: { age: 604800 },
  },
});

interface EmailJob {
  to: string | string[];
  from: string;
  subject: string;
  template: string;
  variables: Record<string, any>;
}

async function enqueueEmail(template: string, variables: Record<string, any>): Promise<void> {
  const job: EmailJob = {
    to: variables.to,
    from: variables.from || 'noreply@example.com',
    subject: variables.subject,
    template,
    variables,
  };
  await emailQueue.add('send-email', job, {
    priority: template === 'password-reset' ? 1 : 5,
  });
}

const emailWorker = new Worker<EmailJob>(
  'email',
  async (job) => {
    const { to, from, subject, template, variables } = job.data;
    const html = await renderTemplate(template, variables);
    const result = await resend.emails.send({
      from, to: Array.isArray(to) ? to : [to], subject, html,
    });
    if (result.error) throw new Error(`Email failed: ${result.error.message}`);
    return { messageId: result.data?.id };
  },
  { connection: { host: process.env.REDIS_HOST, port: 6379 } }
);

// Bounce webhook
app.post('/webhooks/email/bounce', async (req, res) => {
  const { email, type, reason } = req.body;
  if (type === 'bounce' || type === 'complaint') {
    await db.users.updateEmailStatus(email, { bounced: true, bounceReason: reason });
  }
  res.status(200).send('OK');
});
```

### 2.3 Email Template Pattern

```typescript
import { compile } from 'handlebars';

const templates: Record<string, string> = {
  'welcome': '<h1>Welcome, {{name}}!</h1><p>Your account is ready.</p>',
  'password-reset': '<p>Reset code: <strong>{{code}}</strong> (expires in {{expiresIn}})</p>',
  'order-confirmation': '<h1>Order #{{orderId}}</h1><p>Total: ${{total}}</p>',
};

async function renderTemplate(key: string, vars: Record<string, any>): Promise<string> {
  const source = templates[key];
  if (!source) throw new Error(`Template "${key}" not found`);
  return compile(source)(vars);
}
```

---

## 3. File Storage (S3 / R2)

### 3.1 S3 vs R2 Decision

| Factor | AWS S3 | Cloudflare R2 |
|--------|--------|---------------|
| Egress fees | $0.09/GB | **$0** |
| Storage cost | $0.023/GB | $0.015/GB |
| API | Native | S3-compatible |
| Best for | General storage, AWS workloads | Public media, high egress |

### 3.2 Presigned Upload URL

```typescript
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import crypto from 'crypto';

const s3Client = new S3Client({
  region: process.env.S3_REGION || 'auto',
  endpoint: process.env.S3_ENDPOINT,
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY_ID!,
    secretAccessKey: process.env.S3_SECRET_ACCESS_KEY!,
  },
});

const BUCKET = process.env.S3_BUCKET!;

interface PresignedUploadUrl {
  uploadUrl: string;
  publicUrl: string;
  key: string;
}

async function generatePresignedUploadUrl(
  filename: string,
  contentType: string,
  maxSizeBytes: number = 10 * 1024 * 1024
): Promise<PresignedUploadUrl> {
  const key = `uploads/${Date.now()}-${crypto.randomUUID()}-${filename.replace(/[^a-zA-Z0-9.-]/g, '_')}`;

  const command = new PutObjectCommand({
    Bucket: BUCKET, Key: key, ContentType: contentType, ContentLength: maxSizeBytes,
  });

  const uploadUrl = await getSignedUrl(s3Client, command, { expiresIn: 300 });
  const publicUrl = process.env.S3_PUBLIC_URL
    ? `${process.env.S3_PUBLIC_URL}/${key}`
    : `https://${BUCKET}.s3.${process.env.S3_REGION}.amazonaws.com/${key}`;

  return { uploadUrl, publicUrl, key };
}
```

### 3.3 Image Processing Pipeline

Upload → Queue → Process variants (thumb, medium, large) asynchronously.

```typescript
import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import sharp from 'sharp';

async function processImageVariants(key: string): Promise<void> {
  const response = await s3Client.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
  const buffer = await response.Body!.transformToByteArray();

  const variants = [
    { suffix: 'thumb', width: 150, height: 150, fit: 'cover' as const },
    { suffix: 'medium', width: 800, height: 600, fit: 'inside' as const },
    { suffix: 'large', width: 1920, height: 1080, fit: 'inside' as const },
  ];

  for (const v of variants) {
    const resized = await sharp(Buffer.from(buffer))
      .resize(v.width, v.height, { fit: v.fit, withoutEnlargement: true })
      .webp({ quality: 85 })
      .toBuffer();

    const variantKey = key.replace(/\.[^.]+$/, `-${v.suffix}.webp`);
    await s3Client.send(new PutObjectCommand({
      Bucket: BUCKET, Key: variantKey, Body: resized,
      ContentType: 'image/webp', CacheControl: 'public, max-age=31536000',
    }));
  }

  await db.media.updateByKey(key, { status: 'processed', processedAt: new Date() });
}
```

### 3.4 Storage Path Conventions

```
BUCKET/
├── uploads/images/{timestamp}-{uuid}-{filename}
├── uploads/documents/{timestamp}-{uuid}-{filename}
├── uploads/videos/{timestamp}-{uuid}-{filename}
├── processed/images/{key}-{thumb|medium|large}.webp
├── avatars/{userId}-{timestamp}.webp
├── exports/{jobId}/{timestamp}-{filename}.csv
└── backups/{date}/...
```

---

## 4. Search Integration

### 4.1 PostgreSQL Full-Text Search

```sql
-- Add search column and GIN index
ALTER TABLE posts ADD COLUMN search_vector tsvector;
CREATE INDEX idx_posts_search ON posts USING GIN(search_vector);

-- Auto-update function with weighted fields
CREATE OR REPLACE FUNCTION posts_search_update()
RETURNS TRIGGER AS $$
BEGIN
  NEW.search_vector :=
    setweight(to_tsvector('english', COALESCE(NEW.title, '')), 'A') ||
    setweight(to_tsvector('english', COALESCE(NEW.content, '')), 'B') ||
    setweight(to_tsvector('english', COALESCE(NEW.tags::text, '')), 'C');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER posts_search_trigger
  BEFORE INSERT OR UPDATE ON posts
  FOR EACH ROW EXECUTE FUNCTION posts_search_update();

-- Backfill existing data
UPDATE posts SET search_vector =
  setweight(to_tsvector('english', COALESCE(title, '')), 'A') ||
  setweight(to_tsvector('english', COALESCE(content, '')), 'B') ||
  setweight(to_tsvector('english', COALESCE(tags::text, '')), 'C');

-- Ranked search query
SELECT id, title, ts_rank_cd(search_vector, query, 32) AS rank
FROM posts, plainto_tsquery('english', 'search terms') query
WHERE search_vector @@ query
ORDER BY rank DESC
LIMIT 20;

-- Highlighted results
SELECT id, title, ts_headline('english', content, query) AS highlighted
FROM posts, plainto_tsquery('english', 'search terms') query
WHERE search_vector @@ query;
```

### 4.2 pgvector for Semantic/AI Search

```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE documents (
  id SERIAL PRIMARY KEY,
  content TEXT NOT NULL,
  embedding vector(1536),  -- OpenAI text-embedding-3-small
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- HNSW index for fast approximate nearest neighbor
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- Semantic search with similarity threshold
SELECT id, content, 1 - (embedding <=> query_embedding) AS similarity
FROM documents
WHERE 1 - (embedding <=> query_embedding) > 0.8
ORDER BY embedding <=> query_embedding
LIMIT 10;
```

### 4.3 Search Technology Decision Tree

| Use Case | Technology | When to Use |
|----------|------------|-------------|
| Simple text (< 1M docs) | PostgreSQL `tsvector` | Already using Postgres |
| Semantic/AI search | `pgvector` | Embedding-based search |
| Complex aggregations, scale | Elasticsearch | Facets, high volume |
| Managed, instant UI | Algolia | Speed to implement |
| Open-source, self-hosted | Meilisearch | Algolia-like, self-hosted |

---

## 5. Notification System

### 5.1 Multi-Channel Architecture

Events are routed to per-channel queues (email, push, SMS, in-app) based on user preferences. Each channel has its own worker and rate limits.

### 5.2 Notification Queue with Priority

```typescript
import { Queue, Worker } from 'bullmq';

interface NotificationJob {
  userId: string;
  type: 'email' | 'push' | 'sms' | 'in_app';
  template: string;
  variables: Record<string, any>;
  channels: Array<'email' | 'push' | 'sms' | 'in_app'>;
}

const notificationQueue = new Queue<NotificationJob>('notifications', {
  connection: redisConnection,
  defaultJobOptions: { attempts: 3, backoff: { type: 'exponential', delay: 1000 } },
});

class NotificationService {
  async send(notification: Omit<NotificationJob, 'type'>): Promise<void> {
    const prefs = await this.getUserPreferences(notification.userId);
    const enabled = notification.channels.filter(ch => prefs[ch]?.enabled !== false);

    for (const channel of enabled) {
      const priority = this.getPriority(channel, notification.template);
      await notificationQueue.add(`${channel}:${notification.template}`,
        { ...notification, type: channel }, { priority });
    }

    if (prefs.in_app?.enabled !== false) {
      await this.createInAppNotification(notification);
    }
  }

  private getPriority(channel: string, template: string): number {
    if (template === 'security-alert' || template === 'password-reset') return 1;
    if (channel === 'sms') return 2;
    if (channel === 'push') return 3;
    return 5;
  }

  private async getUserPreferences(userId: string) {
    return db.userPreferences.findByUserId(userId);
  }

  private async createInAppNotification(n: NotificationJob): Promise<void> {
    await db.notifications.create({
      userId: n.userId, type: n.template, content: n.variables, read: false, createdAt: new Date(),
    });
  }
}

const notificationWorker = new Worker<NotificationJob>('notifications', async (job) => {
  if (job.data.type === 'email') await sendEmail(job.data);
  else if (job.data.type === 'push') await sendPushNotification(job.data);
  else if (job.data.type === 'sms') await sendSms(job.data);
}, { connection: redisConnection, concurrency: 10, limiter: { max: 50, duration: 1000 } });
```

### 5.3 User Preference Management

```typescript
interface NotificationPreferences {
  email: { enabled: boolean; digest: 'immediate' | 'daily' | 'weekly' };
  push: { enabled: boolean; quietHoursStart?: number; quietHoursEnd?: number };
  sms: { enabled: boolean; phoneNumber?: string };
  in_app: { enabled: boolean };
  categories: Record<string, boolean>;
}

async function shouldSend(userId: string, channel: string, category: string): Promise<boolean> {
  const prefs = await db.userPreferences.findByUserId(userId);
  if (!prefs[channel]?.enabled) return false;
  if (prefs.categories[category] === false) return false;
  if (channel === 'push' && isInQuietHours(prefs.push)) return false;
  return true;
}
```

### 5.4 Batch Notification Handling

```typescript
async function sendBatchNotifications(
  userIds: string[],
  notification: Omit<NotificationJob, 'userId'>
): Promise<void> {
  for (const chunk of chunkArray(userIds, 100)) {
    const jobs = chunk.map(userId => ({
      name: 'batch-notification',
      data: { ...notification, userId },
      opts: { priority: 5 },
    }));
    await notificationQueue.addBulk(jobs);
  }
}

function chunkArray<T>(arr: T[], size: number): T[][] {
  return Array.from({ length: Math.ceil(arr.length / size) },
    (_, i) => arr.slice(i * size, i * size + size));
}
```

---

## 6. Webhook Patterns

### 6.1 Receiving Webhooks (Signature + Idempotency)

```typescript
import crypto from 'crypto';
import { Queue } from 'bullmq';

const webhookQueue = new Queue('webhook-processing', { connection: redisConnection });

app.post('/webhooks/:provider', express.raw({ type: 'application/json' }), async (req, res) => {
  const provider = req.params.provider;
  const signature = req.headers['x-signature'] as string;
  const payload = req.body;

  if (!verifyWebhookSignature(provider, payload, signature)) {
    return res.status(401).send('Invalid signature');
  }

  const event = JSON.parse(payload);
  const eventId = event.id || `${provider}-${event.timestamp}-${crypto.randomUUID()}`;

  res.status(200).send('OK'); // Acknowledge immediately

  await webhookQueue.add('process-webhook', { provider, eventId, event }, {
    jobId: eventId, // Deduplication
    attempts: 3,
    backoff: { type: 'exponential', delay: 5000 },
  });
});

function verifyWebhookSignature(provider: string, payload: string, signature: string): boolean {
  const secret = process.env[`WEBHOOK_SECRET_${provider.toUpperCase()}`];
  if (!secret) return false;
  const expected = crypto.createHmac('sha256', secret).update(payload).digest('hex');
  return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
}

const webhookWorker = new Worker('webhook-processing', async (job) => {
  const { provider, eventId, event } = job.data;
  if (await db.webhookEvents.findById(eventId)) {
    console.log(`Webhook ${eventId} already processed`); return;
  }
  await db.transaction(async (trx) => {
    await trx.webhookEvents.create({ id: eventId, provider, status: 'processing' });
    await routeWebhookEvent(provider, event);
    await trx.webhookEvents.update(eventId, { status: 'completed' });
  });
});
```

### 6.2 Sending Webhooks (Retry + Circuit Breaker + Dead Letter)

```typescript
import axios, { AxiosError } from 'axios';
import CircuitBreaker from 'opossum';

interface OutgoingWebhook {
  id: string; subscriptionId: string; url: string; payload: any;
  eventType: string; attemptCount: number;
}

class WebhookSender {
  private breakers = new Map<string, CircuitBreaker>();

  async send(webhook: OutgoingWebhook): Promise<void> {
    const cb = this.getBreaker(webhook.url);
    try {
      await cb.fire(webhook);
      await db.webhooks.update(webhook.id, { status: 'delivered', deliveredAt: new Date() });
    } catch (error) {
      await this.handleFailure(webhook, error as AxiosError);
    }
  }

  private async executeWebhook(webhook: OutgoingWebhook): Promise<void> {
    const signature = this.signPayload(webhook.payload, webhook.subscriptionId);
    await axios.post(webhook.url, webhook.payload, {
      headers: {
        'Content-Type': 'application/json',
        'X-Webhook-Signature': signature,
        'X-Webhook-Id': webhook.id,
        'X-Event-Type': webhook.eventType,
      },
      timeout: 10000,
    });
  }

  private getBreaker(url: string): CircuitBreaker {
    if (!this.breakers.has(url)) {
      const cb = new CircuitBreaker(this.executeWebhook.bind(this), {
        timeout: 15000, errorThresholdPercentage: 50, resetTimeout: 30000, volumeThreshold: 5,
      });
      cb.on('open', () => console.warn(`Circuit breaker OPEN for ${url}`));
      this.breakers.set(url, cb);
    }
    return this.breakers.get(url)!;
  }

  private async handleFailure(webhook: OutgoingWebhook, error: AxiosError): Promise<void> {
    const next = webhook.attemptCount + 1;
    if (next > 5) {
      await db.webhookDeadLetters.create({ webhookId: webhook.id, error: error.message, failedAt: new Date() });
      await db.webhooks.update(webhook.id, { status: 'dead_letter' });
      return;
    }
    const delayMs = Math.pow(2, next) * 1000;
    await db.webhooks.update(webhook.id, { attemptCount: next, nextRetryAt: new Date(Date.now() + delayMs), status: 'pending_retry' });
    await webhookQueue.add('send-webhook', webhook, { delay: delayMs, jobId: `${webhook.id}-attempt-${next}` });
  }

  private signPayload(payload: any, subId: string): string {
    return crypto.createHmac('sha256', process.env.WEBHOOK_SIGNING_SECRET! + subId)
      .update(JSON.stringify(payload)).digest('hex');
  }
}
```

---

## 7. Third-party API Integration

### 7.1 HTTP Client with Retry & Circuit Breaker

```typescript
import axios, { AxiosInstance, AxiosError, AxiosRequestConfig } from 'axios';
import axiosRetry from 'axios-retry';
import { RateLimiter } from 'limiter';

class ApiClient {
  private client: AxiosInstance;
  private limiter: RateLimiter;

  constructor(baseURL: string, apiKey: string, ratePerSecond: number = 10) {
    this.client = axios.create({ baseURL, timeout: 30000, headers: { 'Authorization': `Bearer ${apiKey}` } });
    this.limiter = new RateLimiter({ tokensPerInterval: ratePerSecond, interval: 'second' });

    this.client.interceptors.request.use(async (config) => {
      await this.limiter.removeTokens(1);
      if (['POST','PUT','PATCH','DELETE'].includes(config.method?.toUpperCase() || '')) {
        config.headers['X-Idempotency-Key'] = crypto.createHash('sha256')
          .update(`${config.method}:${config.url}:${JSON.stringify(config.data)}`).digest('hex').slice(0,32);
      }
      return config;
    });

    this.client.interceptors.response.use(
      (response) => response,
      async (error: AxiosError) => {
        const req = error.config as AxiosRequestConfig & { _retry?: boolean };
        if (error.response?.status === 401 && !req._retry) {
          req._retry = true;
          req.headers = req.headers || {};
          req.headers['Authorization'] = `Bearer ${await this.refreshToken()}`;
          return this.client(req);
        }
        return Promise.reject(error);
      }
    );

    axiosRetry(this.client, {
      retries: 3, retryDelay: axiosRetry.exponentialDelay,
      retryCondition: (err) => axiosRetry.isNetworkOrIdempotentRequestError(err) ||
        err.response?.status === 429 || (err.response?.status ?? 0) >= 500,
    });
  }

  async get<T>(path: string, params?: Record<string, any>): Promise<T> {
    return (await this.client.get<T>(path, { params })).data;
  }
  async post<T>(path: string, data: any): Promise<T> {
    return (await this.client.post<T>(path, data)).data;
  }
  private async refreshToken(): Promise<string> { return 'new-token'; }
}
```

### 7.2 API Key Rotation

```typescript
class RotatingKeyManager {
  private keys: string[]; private current = 0; private failed = new Set<number>();
  constructor(keys: string[]) { this.keys = keys; }
  getKey(): string {
    if (this.failed.size >= this.keys.length) throw new Error('All API keys exhausted');
    while (this.failed.has(this.current)) this.current = (this.current + 1) % this.keys.length;
    return this.keys[this.current];
  }
  markFailed(index: number): void { this.failed.add(index); this.current = (this.current + 1) % this.keys.length; }
  reset(): void { this.failed.clear(); this.current = 0; }
}

async function callWithRotation<T>(manager: RotatingKeyManager, apiCall: (key: string) => Promise<T>): Promise<T> {
  let lastError: Error;
  for (let i = 0; i < manager.keys.length; i++) {
    const key = manager.getKey();
    try { return await apiCall(key); }
    catch (e: any) { lastError = e; if (e.response?.status === 429 || e.response?.status === 403) manager.markFailed(i); else throw e; }
  }
  throw lastError!;
}
```

### 7.3 Response Caching

```typescript
import NodeCache from 'node-cache';
const apiCache = new NodeCache({ stdTTL: 300, checkperiod: 60 });

async function cachedApiCall<T>(key: string, apiCall: () => Promise<T>, ttl: number = 300): Promise<T> {
  const cached = apiCache.get<T>(key);
  if (cached) return cached;
  const result = await apiCall();
  apiCache.set(key, result, ttl);
  return result;
}

function invalidateCache(pattern: string): void {
  apiCache.del(apiCache.keys().filter(k => k.includes(pattern)));
}
```

---

## 8. Code Snippets Index

| # | Snippet | Language | Section |
|---|---------|----------|---------|
| 1 | Stripe PaymentIntent creation | TypeScript | §1.2 |
| 2 | Stripe webhook handler + idempotency | TypeScript | §1.3 |
| 3 | Email queue with BullMQ + Resend | TypeScript | §2.2 |
| 4 | Presigned S3/R2 upload URL | TypeScript | §3.2 |
| 5 | PostgreSQL full-text search | SQL | §4.1 |
| 6 | Notification queue (multi-channel) | TypeScript | §5.2 |
| 7 | Webhook receiver with signature + idempotency | TypeScript | §6.1 |
| 8 | Webhook sender with retry + circuit breaker | TypeScript | §6.2 |
| 9 | HTTP client with retry + circuit breaker | TypeScript | §7.1 |
