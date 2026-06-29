# Real-Time Communication Reference

> Production-ready patterns for SSE, WebSocket, presence, message ordering, and real-time architecture.

---

## Table of Contents

- [Server-Sent Events (SSE)](#server-sent-events-sse)
  - [When to Use SSE](#when-to-use-sse)
  - [SSE Headers & Event Format](#sse-headers--event-format)
  - [Express SSE Endpoint](#express-sse-endpoint)
  - [SSE Client (JavaScript)](#sse-client-javascript)
  - [Reconnection with Last-Event-ID](#reconnection-with-last-event-id)
  - [Connection Cleanup](#connection-cleanup)
- [WebSocket](#websocket)
  - [When to Use WebSocket](#when-to-use-websocket)
  - [Socket.io Server Setup](#socketio-server-setup)
  - [Socket.io Auth Middleware](#socketio-auth-middleware)
  - [Rooms & Namespaces](#rooms--namespaces)
  - [Socket.io with Redis Adapter](#socketio-with-redis-adapter)
  - [Acknowledgment Pattern](#acknowledgment-pattern)
- [WebSocket vs SSE Decision Tree](#websocket-vs-sse-decision-tree)
- [Presence System](#presence-system)
  - [Heartbeat & TTL with Redis](#heartbeat--ttl-with-redis)
  - [Typing Indicators & Read Receipts](#typing-indicators--read-receipts)
- [Disconnection & Reconnection](#disconnection--reconnection)
  - [Message Buffering on Disconnect](#message-buffering-on-disconnect)
  - [Exponential Backoff Reconnection](#exponential-backoff-reconnection)
  - [Connection State Machine](#connection-state-machine)
- [Message Ordering](#message-ordering)
  - [Sequence Numbers](#sequence-numbers)
  - [Deduplication & Delivery Semantics](#deduplication--delivery-semantics)
- [Rate Limiting Real-Time](#rate-limiting-real-time)
  - [WebSocket Message Rate Limiter](#websocket-message-rate-limiter)
- [Real-Time Architecture Patterns](#real-time-architecture-patterns)
  - [Pub/Sub with Redis](#pubsub-with-redis)
  - [Event Bus for Real-Time Events](#event-bus-for-real-time-events)
  - [CQRS with Read Models](#cqrs-with-read-models)
  - [Fan-Out Pattern for Notifications](#fan-out-pattern-for-notifications)
- [Code Snippet Index](#code-snippet-index)

---

## Server-Sent Events (SSE)

### When to Use SSE

| Use Case | Why SSE? |
|----------|----------|
| **Live notifications** | One-way push from server; no client→server overhead |
| **AI streaming responses** | Stream tokens as they're generated; HTTP-friendly |
| **Live logs / tail -f** | Continuous text stream; native browser `EventSource` support |
| **Progress updates** | Upload/build/job progress bars pushed from server |
| **Social feed updates** | New posts pushed to active viewers without polling |

SSE is ideal when the server needs to **push** data to the client and the client rarely needs to send data back. It runs over HTTP, works through most corporate proxies/firewalls, and has automatic reconnection built into the browser.

---

### SSE Headers & Event Format

The server must send these headers for SSE to work correctly:

```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

The event format is line-oriented:

```
event: message
id: 42
data: {"user":"alice","text":"hello"}
retry: 5000

```

Fields:

| Field | Required | Description |
|-------|----------|-------------|
| `data:` | Yes | Event payload. Multiline `data:` lines are joined with `\n`. |
| `event:` | No | Event type name. Client listens via `addEventListener('name', ...)`. |
| `id:` | No | Event ID. Used for `Last-Event-ID` header on reconnection. |
| `retry:` | No | Reconnection delay in milliseconds (hint to the client). |

Each event is terminated by a **double newline** (`\n\n`).

---

### Express SSE Endpoint

```typescript
import { Request, Response } from 'express';
import { EventEmitter } from 'events';

// Global event emitter for demo; in production use Redis Pub/Sub or an event bus
const globalEvents = new EventEmitter();

interface SSEClient {
  id: string;
  userId: string;
  res: Response;
}

const clients = new Map<string, SSEClient>();

/**
 * SSE endpoint: GET /events/stream
 * Headers set automatically. Supports ?lastEventId for replay.
 */
export function sseHandler(req: Request, res: Response): void {
  const userId = (req as any).user?.id as string | undefined;
  if (!userId) {
    res.status(401).json({ error: 'Unauthorized' });
    return;
  }

  // Set SSE headers
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no'); // Disable nginx buffering

  // Optional CORS
  res.setHeader('Access-Control-Allow-Origin', '*');

  const clientId = crypto.randomUUID();
  const client: SSEClient = { id: clientId, userId, res };
  clients.set(clientId, client);

  // Send initial retry hint and welcome event
  res.write(`retry: 3000\n`);
  res.write(`event: connected\n`);
  res.write(`data: {"clientId":"${clientId}","userId":"${userId}"}\n\n`);

  // Handle client disconnect
  req.on('close', () => {
    clients.delete(clientId);
    console.log(`SSE client ${clientId} disconnected`);
  });

  // Send heartbeat every 30s to keep connection alive
  const heartbeat = setInterval(() => {
    if (res.writableEnded) {
      clearInterval(heartbeat);
      return;
    }
    res.write(`: heartbeat\n\n`); // Comment lines are ignored by client
  }, 30000);

  // Subscribe to user-specific events
  const onEvent = (payload: unknown) => {
    if (res.writableEnded) return;
    const data = JSON.stringify(payload);
    res.write(`id: ${Date.now()}\n`);
    res.write(`event: message\n`);
    res.write(`data: ${data}\n\n`);
  };
  globalEvents.on(`user:${userId}`, onEvent);

  // Cleanup on close
  req.on('close', () => {
    clearInterval(heartbeat);
    globalEvents.off(`user:${userId}`, onEvent);
    clients.delete(clientId);
  });

  console.log(`SSE client ${clientId} connected for user ${userId}`);
}

/**
 * Broadcast an event to all connected clients of a specific user.
 */
export function broadcastToUser(userId: string, payload: unknown): void {
  globalEvents.emit(`user:${userId}`, payload);
}
```

---

### SSE Client (JavaScript)

```javascript
class SSEClient {
  constructor(url, options = {}) {
    this.url = url;
    this.options = options;
    this.eventSource = null;
    this.reconnectDelay = 3000;
    this.maxReconnectDelay = 30000;
    this.listeners = new Map();
    this.onConnect = options.onConnect || (() => {});
    this.onError = options.onError || (() => {});
    this.lastEventId = null;
    this.intentionalClose = false;
  }

  connect() {
    if (this.eventSource) return;

    const headers = {};
    if (this.lastEventId) {
      headers['Last-Event-ID'] = this.lastEventId;
    }

    this.eventSource = new EventSource(this.url, {
      headers: this.options.headers,
      withCredentials: this.options.withCredentials ?? true,
    });

    this.eventSource.onopen = () => {
      console.log('SSE connected');
      this.reconnectDelay = 3000; // Reset backoff
      this.onConnect();
    };

    this.eventSource.onmessage = (event) => {
      if (event.id) this.lastEventId = event.id;
      const handler = this.listeners.get('message');
      if (handler) {
        try {
          handler(JSON.parse(event.data));
        } catch {
          handler(event.data);
        }
      }
    };

    this.eventSource.onerror = (error) => {
      this.onError(error);
      this.eventSource.close();
      this.eventSource = null;

      if (!this.intentionalClose) {
        setTimeout(() => this.connect(), this.reconnectDelay);
        this.reconnectDelay = Math.min(
          this.reconnectDelay * 1.5,
          this.maxReconnectDelay
        );
      }
    };

    // Register custom event listeners
    for (const [eventName, handler] of this.listeners.entries()) {
      if (eventName === 'message') continue;
      this.eventSource.addEventListener(eventName, (event) => {
        if (event.id) this.lastEventId = event.id;
        try {
          handler(JSON.parse(event.data));
        } catch {
          handler(event.data);
        }
      });
    }
  }

  on(eventName, handler) {
    this.listeners.set(eventName, handler);
    if (this.eventSource) {
      this.eventSource.addEventListener(eventName, (event) => {
        if (event.id) this.lastEventId = event.id;
        try {
          handler(JSON.parse(event.data));
        } catch {
          handler(event.data);
        }
      });
    }
  }

  close() {
    this.intentionalClose = true;
    if (this.eventSource) {
      this.eventSource.close();
      this.eventSource = null;
    }
  }
}

// Usage
const client = new SSEClient('https://api.example.com/events/stream', {
  headers: { Authorization: 'Bearer TOKEN' },
  onConnect: () => console.log('Stream ready'),
  onError: (e) => console.error('SSE error', e),
});

client.on('message', (data) => console.log('Message:', data));
client.on('connected', (data) => console.log('Connected event:', data));
client.connect();
```

---

### Reconnection with Last-Event-ID

When a client reconnects, it sends the `Last-Event-ID` header with the ID of the last successfully received event. The server should replay missed events from that point.

```typescript
// Express middleware to extract lastEventId
export function extractLastEventId(req: Request, res: Response, next: () => void): void {
  const lastEventId = req.headers['last-event-id'] as string | undefined;
  (req as any).lastEventId = lastEventId ? parseInt(lastEventId, 10) : null;
  next();
}

// In your SSE handler, use lastEventId to fetch missed events
async function sendMissedEvents(res: Response, userId: string, lastEventId: number | null): Promise<void> {
  if (lastEventId == null) return;

  // Fetch from persistent store (e.g., message log, event log, or Redis stream)
  const missedEvents = await fetchEventsAfterId(userId, lastEventId);
  for (const event of missedEvents) {
    res.write(`id: ${event.id}\n`);
    res.write(`event: ${event.type}\n`);
    res.write(`data: ${JSON.stringify(event.payload)}\n\n`);
  }
}

// Placeholder: replace with your actual event store query
async function fetchEventsAfterId(userId: string, lastEventId: number): Promise<Array<{ id: number; type: string; payload: unknown }>> {
  // Example: query from Redis Stream, PostgreSQL, or a message log table
  return [];
}
```

---

### Connection Cleanup

SSE connections are long-lived. Always clean up on disconnect to prevent memory leaks:

```typescript
function cleanupSSE(req: Request, res: Response, cleanupFns: Array<() => void>): void {
  let cleaned = false;

  const doCleanup = () => {
    if (cleaned) return;
    cleaned = true;
    for (const fn of cleanupFns) {
      try { fn(); } catch (e) { console.error('Cleanup error:', e); }
    }
    if (!res.writableEnded) {
      res.end();
    }
  };

  req.on('close', doCleanup);
  req.on('error', doCleanup);
  req.on('timeout', doCleanup);

  // Also cleanup if the response finishes for any reason
  res.on('finish', doCleanup);
  res.on('error', doCleanup);
}
```

---

## WebSocket

### When to Use WebSocket

| Use Case | Why WebSocket? |
|----------|---------------|
| **Chat / messaging** | Bidirectional; client sends messages, server pushes replies and presence |
| **Real-time gaming** | Low latency, binary support, frequent client→server input |
| **Collaborative editing** | Client sends edits, server broadcasts to other collaborators |
| **Live dashboards** | Client subscribes to data streams; server pushes updates |
| **Trading / financial tickers** | Sub-100ms latency requirements; bidirectional subscription control |
| **IoT control** | Device sends telemetry; server sends commands |

Use WebSocket when the client needs to **send frequent messages** to the server, or when **latency is critical**. For pure server→client push, SSE is simpler and more reliable.

---

### Socket.io Server Setup

```typescript
import { Server as HttpServer } from 'http';
import { Server as SocketIOServer, Socket } from 'socket.io';

let io: SocketIOServer | null = null;

export function createSocketServer(httpServer: HttpServer): SocketIOServer {
  io = new SocketIOServer(httpServer, {
    cors: {
      origin: process.env.CLIENT_ORIGIN || 'http://localhost:3000',
      methods: ['GET', 'POST'],
      credentials: true,
    },
    // Ping/pong to detect dead connections
    pingInterval: 10000,
    pingTimeout: 5000,
    // Transport preference: WebSocket first, fallback to HTTP long-polling
    transports: ['websocket', 'polling'],
  });

  io.on('connection', (socket: Socket) => {
    console.log(`Socket connected: ${socket.id}, user: ${socket.data.userId}`);

    socket.on('disconnect', (reason) => {
      console.log(`Socket disconnected: ${socket.id}, reason: ${reason}`);
    });

    socket.on('error', (error) => {
      console.error(`Socket error: ${socket.id}`, error);
    });
  });

  return io;
}

export function getIO(): SocketIOServer {
  if (!io) throw new Error('Socket.io not initialized');
  return io;
}
```

---

### Socket.io Auth Middleware

```typescript
import { Socket } from 'socket.io';
import { ExtendedError } from 'socket.io/dist/namespace';
import jwt from 'jsonwebtoken';

interface AuthenticatedSocket extends Socket {
  data: {
    userId: string;
    email: string;
    roles: string[];
  };
}

export function socketAuthMiddleware(
  socket: Socket,
  next: (err?: ExtendedError) => void
): void {
  try {
    const token = socket.handshake.auth.token || socket.handshake.headers.authorization?.replace('Bearer ', '');

    if (!token) {
      return next(new Error('Authentication error: token missing'));
    }

    const decoded = jwt.verify(token, process.env.JWT_SECRET!) as { sub: string; email: string; roles: string[] };

    (socket as AuthenticatedSocket).data = {
      userId: decoded.sub,
      email: decoded.email,
      roles: decoded.roles || [],
    };

    next();
  } catch (error) {
    next(new Error('Authentication error: invalid token'));
  }
}

// Apply middleware globally
// io.use(socketAuthMiddleware);
```

---

### Rooms & Namespaces

```typescript
import { Socket } from 'socket.io';

/**
 * Room naming conventions:
 * - user:{userId}     — per-user notifications
 * - room:{roomId}     — chat rooms / collaborative spaces
 * - project:{projectId} — project-specific updates
 * - broadcast          — all connected clients (use sparingly)
 */

export function joinUserRoom(socket: Socket): void {
  const userId = socket.data.userId;
  if (userId) {
    socket.join(`user:${userId}`);
  }
}

export function joinChatRoom(socket: Socket, roomId: string): void {
  // Check permission before joining (pseudo-code)
  // const canJoin = await canAccessRoom(socket.data.userId, roomId);
  // if (!canJoin) return socket.emit('error', { message: 'Access denied' });

  socket.join(`room:${roomId}`);
  socket.emit('joined', { roomId });

  // Notify other room members
  socket.to(`room:${roomId}`).emit('member_joined', {
    userId: socket.data.userId,
    socketId: socket.id,
  });
}

export function leaveChatRoom(socket: Socket, roomId: string): void {
  socket.leave(`room:${roomId}`);
  socket.to(`room:${roomId}`).emit('member_left', {
    userId: socket.data.userId,
  });
}

// Emitting patterns
export function emitToUser(io: SocketIOServer, userId: string, event: string, payload: unknown): void {
  io.to(`user:${userId}`).emit(event, payload);
}

export function emitToRoom(io: SocketIOServer, roomId: string, event: string, payload: unknown, exceptSocketId?: string): void {
  const target = io.to(`room:${roomId}`);
  if (exceptSocketId) {
    target.except(exceptSocketId).emit(event, payload);
  } else {
    target.emit(event, payload);
  }
}

export function broadcastToAll(io: SocketIOServer, event: string, payload: unknown): void {
  io.emit(event, payload); // Emit to all connected sockets
}
```

---

### Socket.io with Redis Adapter

When scaling WebSocket servers horizontally, the Redis adapter ensures messages reach clients connected to other server instances.

```typescript
import { Server as HttpServer } from 'http';
import { Server as SocketIOServer } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient } from 'redis';

export async function createSocketServerWithRedis(httpServer: HttpServer): Promise<SocketIOServer> {
  const pubClient = createClient({ url: process.env.REDIS_URL || 'redis://localhost:6379' });
  const subClient = pubClient.duplicate();

  await pubClient.connect();
  await subClient.connect();

  const io = new SocketIOServer(httpServer, {
    cors: {
      origin: process.env.CLIENT_ORIGIN || 'http://localhost:3000',
      credentials: true,
    },
    pingInterval: 10000,
    pingTimeout: 5000,
    transports: ['websocket', 'polling'],
  });

  io.adapter(createAdapter(pubClient, subClient));

  io.use(socketAuthMiddleware);

  io.on('connection', (socket) => {
    joinUserRoom(socket);

    socket.on('join:room', (roomId: string) => joinChatRoom(socket, roomId));
    socket.on('leave:room', (roomId: string) => leaveChatRoom(socket, roomId));

    socket.on('message:send', async (data: { roomId: string; text: string }, callback) => {
      try {
        const message = await persistMessage({
          roomId: data.roomId,
          userId: socket.data.userId,
          text: data.text,
        });

        emitToRoom(io, data.roomId, 'message:new', message);

        // Acknowledge receipt to sender
        callback({ success: true, messageId: message.id });
      } catch (error) {
        callback({ success: false, error: error.message });
      }
    });

    socket.on('disconnect', async () => {
      await markUserOffline(socket.data.userId);
      io.emit('presence:offline', { userId: socket.data.userId });
    });
  });

  return io;
}

// Placeholder implementations
async function persistMessage(_data: { roomId: string; userId: string; text: string }): Promise<{ id: string; roomId: string; userId: string; text: string; createdAt: Date }> {
  return { id: crypto.randomUUID(), ..._data, createdAt: new Date() };
}

async function markUserOffline(_userId: string): Promise<void> {}
```

---

### Acknowledgment Pattern

Use acknowledgments for operations that need confirmation (e.g., message sent, operation completed).

```typescript
// Client sends a message with a callback (ack)
socket.emit('message:send', { roomId: 'abc', text: 'Hello' }, (ack) => {
  if (ack.success) {
    console.log('Message delivered, ID:', ack.messageId);
  } else {
    console.error('Delivery failed:', ack.error);
  }
});

// Server handles the event with acknowledgment
socket.on('message:send', async (data, callback) => {
  try {
    const message = await saveMessage(data);
    broadcastToRoom(data.roomId, 'message:new', message);
    callback({ success: true, messageId: message.id });
  } catch (error) {
    callback({ success: false, error: error.message });
  }
});
```

---

## WebSocket vs SSE Decision Tree

```
                    ┌─────────────────┐
                    │  Server Push?   │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
        ┌─────────┐                   ┌─────────┐
        │   Yes   │                   │   No    │
        └────┬────┘                   └────┬────┘
             │                               │
    ┌────────┴────────┐              ┌─────┴─────┐
    ▼                   ▼              ▼           ▼
┌─────────┐       ┌─────────┐   ┌─────────┐  ┌─────────┐
│ Client  │       │  Just   │   │  Chat   │  │ Gaming  │
│ sends   │       │  push   │   │/Collab  │  │ /Trading│
│ data?   │       │  data   │   │         │  │         │
└────┬────┘       └─────────┘   └─────────┘  └─────────┘
     │                    ▲            ▲            ▲
┌────┴────┐               │            │            │
▼         ▼               │            │            │
Yes       No              │            │            │
├─────────┤               │            │            │
▼         ▼               │            │            │
WebSocket  SSE ────────────┘            │            │
                                      WebSocket   WebSocket
```

### Comparison Table

| Aspect | SSE | WebSocket (Socket.io) |
|--------|-----|----------------------|
| **Direction** | Server → Client only | Bidirectional |
| **Protocol** | HTTP (EventSource) | WebSocket (TCP) |
| **Auto reconnect** | ✅ Browser built-in | ❌ Manual implementation |
| **Reconnection ID** | ✅ `Last-Event-ID` | ❌ Custom implementation |
| **Binary data** | ❌ Base64 only | ✅ Native support |
| **Browser support** | ✅ All modern browsers | ✅ All modern browsers |
| **Firewall/proxy** | ✅ HTTP-friendly | ⚠️ May need WS upgrades |
| **Multiplexing** | ❌ One stream per client | ✅ Namespaces & rooms |
| **Broadcast** | Per-connection | Rooms + Redis adapter |
| **Latency** | ~ms (HTTP overhead) | ~sub-ms |
| **Connection limit** | 6 per browser (HTTP/1) | Higher |
| **Best for** | Notifications, streaming, logs | Chat, gaming, collaboration |

---

## Presence System

### Heartbeat & TTL with Redis

Track online users with Redis TTL-based heartbeats. If a user stops heartbeating, they expire automatically.

```typescript
import { Redis } from 'ioredis';

const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');
const PRESENCE_KEY = (userId: string) => `presence:${userId}`;
const PRESENCE_CHANNEL = 'presence:updates';
const HEARTBEAT_INTERVAL_MS = 30000; // Client heartbeat every 30s
const PRESENCE_TTL_SECONDS = 60;     // Redis key expires after 60s

interface PresenceData {
  userId: string;
  status: 'online' | 'away' | 'dnd';
  lastSeenAt: string;
  clientMeta?: Record<string, unknown>;
}

/**
 * Update user presence with a heartbeat. Called when:
 * - User connects via WebSocket
 * - Client sends periodic heartbeat pings
 */
export async function heartbeat(userId: string, status: PresenceData['status'] = 'online', clientMeta?: Record<string, unknown>): Promise<void> {
  const data: PresenceData = {
    userId,
    status,
    lastSeenAt: new Date().toISOString(),
    clientMeta,
  };

  await redis.setex(PRESENCE_KEY(userId), PRESENCE_TTL_SECONDS, JSON.stringify(data));
  await redis.publish(PRESENCE_CHANNEL, JSON.stringify({ type: 'heartbeat', userId, data }));
}

/**
 * Mark user as offline immediately (e.g., on disconnect).
 */
export async function setOffline(userId: string): Promise<void> {
  await redis.del(PRESENCE_KEY(userId));
  await redis.publish(PRESENCE_CHANNEL, JSON.stringify({ type: 'offline', userId, at: new Date().toISOString() }));
}

/**
 * Check if a user is currently online.
 */
export async function isOnline(userId: string): Promise<boolean> {
  const exists = await redis.exists(PRESENCE_KEY(userId));
  return exists === 1;
}

/**
 * Get presence data for a user.
 */
export async function getPresence(userId: string): Promise<PresenceData | null> {
  const data = await redis.get(PRESENCE_KEY(userId));
  return data ? JSON.parse(data) : null;
}

/**
 * Get online status for multiple users (batch).
 */
export async function getBulkPresence(userIds: string[]): Promise<Record<string, PresenceData | null>> {
  if (userIds.length === 0) return {};
  const keys = userIds.map(PRESENCE_KEY);
  const values = await redis.mget(...keys);

  const result: Record<string, PresenceData | null> = {};
  userIds.forEach((id, i) => {
    result[id] = values[i] ? JSON.parse(values[i]!) : null;
  });
  return result;
}

/**
 * Subscribe to presence updates (use with Redis Pub/Sub or your event bus).
 */
export function subscribePresenceUpdates(handler: (update: { type: string; userId: string; data?: PresenceData }) => void): void {
  redis.subscribe(PRESENCE_CHANNEL, (err) => {
    if (err) console.error('Failed to subscribe to presence channel:', err);
  });

  redis.on('message', (channel, message) => {
    if (channel === PRESENCE_CHANNEL) {
      try {
        handler(JSON.parse(message));
      } catch (e) {
        console.error('Failed to parse presence update:', e);
      }
    }
  });
}
```

### Typing Indicators & Read Receipts

```typescript
import { Socket } from 'socket.io';

/**
 * Typing indicator: ephemeral, short TTL.
 */
const TYPING_KEY = (roomId: string, userId: string) => `typing:${roomId}:${userId}`;
const TYPING_TTL = 5; // seconds

export async function setTyping(redis: Redis, roomId: string, userId: string, isTyping: boolean): Promise<void> {
  if (isTyping) {
    await redis.setex(TYPING_KEY(roomId, userId), TYPING_TTL, Date.now().toString());
  } else {
    await redis.del(TYPING_KEY(roomId, userId));
  }
}

export async function getTypingUsers(redis: Redis, roomId: string): Promise<string[]> {
  const keys = await redis.keys(`typing:${roomId}:*`);
  return keys.map((k) => k.split(':').pop()!).filter(Boolean);
}

/**
 * Read receipt: mark the last message read by a user in a room.
 */
const READ_RECEIPT_KEY = (roomId: string, userId: string) => `read:${roomId}:${userId}`;

export async function markRead(redis: Redis, roomId: string, userId: string, messageId: string, messageSequence: number): Promise<void> {
  await redis.set(READ_RECEIPT_KEY(roomId, userId), JSON.stringify({ messageId, messageSequence, readAt: new Date().toISOString() }));
}

export async function getReadReceipt(redis: Redis, roomId: string, userId: string): Promise<{ messageId: string; messageSequence: number; readAt: string } | null> {
  const data = await redis.get(READ_RECEIPT_KEY(roomId, userId));
  return data ? JSON.parse(data) : null;
}

// Socket.io handlers for typing and read receipts
export function registerTypingHandlers(io: SocketIOServer, socket: Socket, redis: Redis): void {
  socket.on('typing:start', async ({ roomId }: { roomId: string }) => {
    await setTyping(redis, roomId, socket.data.userId, true);
    socket.to(`room:${roomId}`).emit('typing:update', {
      roomId,
      userId: socket.data.userId,
      isTyping: true,
    });
  });

  socket.on('typing:stop', async ({ roomId }: { roomId: string }) => {
    await setTyping(redis, roomId, socket.data.userId, false);
    socket.to(`room:${roomId}`).emit('typing:update', {
      roomId,
      userId: socket.data.userId,
      isTyping: false,
    });
  });

  socket.on('message:read', async ({ roomId, messageId, messageSequence }: { roomId: string; messageId: string; messageSequence: number }) => {
    await markRead(redis, roomId, socket.data.userId, messageId, messageSequence);
    socket.to(`room:${roomId}`).emit('message:read', {
      roomId,
      userId: socket.data.userId,
      messageId,
      messageSequence,
    });
  });
}
```

---

## Disconnection & Reconnection

### Message Buffering on Disconnect

Buffer messages for disconnected users so they can be delivered on reconnect.

```typescript
import { Redis } from 'ioredis';

const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');
const BUFFER_KEY = (userId: string) => `messages:buffer:${userId}`;
const MAX_BUFFER_SIZE = 100; // per user
const BUFFER_TTL = 86400;    // 24 hours

interface BufferedMessage {
  id: string;
  type: string;
  payload: unknown;
  sequence: number;
  bufferedAt: string;
}

/**
 * Buffer a message for a user if they are offline or disconnected.
 */
export async function bufferMessage(userId: string, type: string, payload: unknown, sequence: number): Promise<void> {
  const message: BufferedMessage = {
    id: crypto.randomUUID(),
    type,
    payload,
    sequence,
    bufferedAt: new Date().toISOString(),
  };

  await redis.lpush(BUFFER_KEY(userId), JSON.stringify(message));
  await redis.ltrim(BUFFER_KEY(userId), 0, MAX_BUFFER_SIZE - 1);
  await redis.expire(BUFFER_KEY(userId), BUFFER_TTL);
}

/**
 * Flush buffered messages for a user upon reconnection.
 */
export async function flushBufferedMessages(userId: string): Promise<BufferedMessage[]> {
  const messages = await redis.lrange(BUFFER_KEY(userId), 0, -1);
  if (messages.length > 0) {
    await redis.del(BUFFER_KEY(userId));
  }
  return messages.map((m) => JSON.parse(m)).reverse(); // Return in FIFO order
}

/**
 * Send or buffer a message based on user presence.
 */
export async function sendOrBuffer(io: SocketIOServer, redis: Redis, userId: string, event: string, payload: unknown, sequence: number): Promise<void> {
  const online = await isOnline(userId);
  if (online) {
    emitToUser(io, userId, event, payload);
  } else {
    await bufferMessage(userId, event, payload, sequence);
  }
}
```

---

### Exponential Backoff Reconnection

```typescript
interface ReconnectionConfig {
  initialDelay: number;      // ms
  maxDelay: number;          // ms
  multiplier: number;        // e.g., 1.5 or 2
  maxAttempts: number;        // 0 = unlimited
  jitter: boolean;           // Add randomness to prevent thundering herd
}

const defaultConfig: ReconnectionConfig = {
  initialDelay: 1000,
  maxDelay: 30000,
  multiplier: 1.5,
  maxAttempts: 0,
  jitter: true,
};

class ReconnectionManager {
  private attempt = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private state: 'idle' | 'waiting' | 'connecting' = 'idle';

  constructor(
    private readonly connectFn: () => void,
    private readonly config: ReconnectionConfig = defaultConfig
  ) {}

  schedule(): void {
    if (this.config.maxAttempts > 0 && this.attempt >= this.config.maxAttempts) {
      console.log('Max reconnection attempts reached');
      return;
    }

    this.state = 'waiting';
    this.attempt++;

    const delay = this.calculateDelay();
    console.log(`Reconnecting in ${delay}ms (attempt ${this.attempt})`);

    this.timer = setTimeout(() => {
      this.state = 'connecting';
      this.connectFn();
    }, delay);
  }

  reset(): void {
    if (this.timer) clearTimeout(this.timer);
    this.attempt = 0;
    this.state = 'idle';
  }

  private calculateDelay(): number {
    let delay = this.config.initialDelay * Math.pow(this.config.multiplier, this.attempt - 1);
    delay = Math.min(delay, this.config.maxDelay);

    if (this.config.jitter) {
      delay = delay * (0.5 + Math.random() * 0.5); // 50%-100% of calculated delay
    }

    return Math.round(delay);
  }

  getState(): string {
    return this.state;
  }
}

// Usage with Socket.io client
// const reconnector = new ReconnectionManager(() => socket.connect());
// socket.on('disconnect', () => reconnector.schedule());
// socket.on('connect', () => reconnector.reset());
```

---

### Connection State Machine

```typescript
type ConnectionState =
  | 'disconnected'      // No active connection attempt
  | 'connecting'         // Attempting to connect
  | 'connected'          // Established and healthy
  | 'reconnecting'       // Attempting to reconnect after disconnect
  | 'offline'            // Network unavailable or max retries reached
  | 'error';             // Terminal error state

interface StateTransition {
  from: ConnectionState;
  to: ConnectionState;
  trigger: string;
}

class ConnectionStateMachine {
  private state: ConnectionState = 'disconnected';
  private readonly listeners = new Set<(state: ConnectionState, prev: ConnectionState) => void>();

  transition(to: ConnectionState, trigger: string): void {
    const from = this.state;
    if (from === to) return;

    const valid = this.isValidTransition(from, to);
    if (!valid) {
      console.warn(`Invalid transition: ${from} -> ${to} via ${trigger}`);
      return;
    }

    this.state = to;
    console.log(`State: ${from} -> ${to} (${trigger})`);
    this.listeners.forEach((fn) => fn(to, from));
  }

  private isValidTransition(from: ConnectionState, to: ConnectionState): boolean {
    const transitions: Record<ConnectionState, ConnectionState[]> = {
      disconnected: ['connecting', 'offline'],
      connecting: ['connected', 'disconnected', 'error', 'reconnecting'],
      connected: ['disconnected', 'reconnecting', 'offline'],
      reconnecting: ['connected', 'disconnected', 'offline', 'error'],
      offline: ['connecting', 'disconnected'],
      error: ['disconnected', 'connecting'],
    };
    return transitions[from]?.includes(to) ?? false;
  }

  getState(): ConnectionState {
    return this.state;
  }

  onTransition(fn: (state: ConnectionState, prev: ConnectionState) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }
}

// Usage
const connState = new ConnectionStateMachine();
connState.onTransition((state, prev) => {
  if (state === 'connected') {
    // Fetch missed messages
  }
});
// socket.on('connect', () => connState.transition('connected', 'socket_connect'));
// socket.on('disconnect', () => connState.transition('reconnecting', 'socket_disconnect'));
```

---

## Message Ordering

### Sequence Numbers

Use monotonic sequence numbers per room to ensure ordered delivery and detect gaps.

```typescript
import { Redis } from 'ioredis';

const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');
const SEQ_KEY = (roomId: string) => `seq:${roomId}`;

interface SequencedMessage {
  id: string;
  roomId: string;
  userId: string;
  text: string;
  sequence: number;
  createdAt: string;
}

/**
 * Assign the next sequence number for a room and persist the message.
 */
export async function assignSequenceAndSave(
  redis: Redis,
  message: Omit<SequencedMessage, 'sequence'>
): Promise<SequencedMessage> {
  const sequence = await redis.incr(SEQ_KEY(message.roomId));
  const sequenced: SequencedMessage = { ...message, sequence };

  // Persist to your message store (e.g., PostgreSQL, MongoDB, Redis Stream)
  await persistMessageToStore(sequenced);

  return sequenced;
}

// Placeholder
async function persistMessageToStore(message: SequencedMessage): Promise<void> {
  // Implementation depends on your database
  console.log('Persisted message', message.id, 'seq:', message.sequence);
}

/**
 * Client-side: track the last received sequence and detect gaps.
 */
class OrderedMessageBuffer {
  private lastSequence = 0;
  private readonly pending = new Map<number, SequencedMessage>();
  private readonly onOrderedMessage: (msg: SequencedMessage) => void;

  constructor(onOrderedMessage: (msg: SequencedMessage) => void) {
    this.onOrderedMessage = onOrderedMessage;
  }

  receive(message: SequencedMessage): void {
    if (message.sequence <= this.lastSequence) {
      // Duplicate or already processed
      return;
    }

    if (message.sequence === this.lastSequence + 1) {
      // In order
      this.deliver(message);

      // Check if buffered messages can now be delivered
      while (this.pending.has(this.lastSequence + 1)) {
        const next = this.pending.get(this.lastSequence + 1)!;
        this.pending.delete(next.sequence);
        this.deliver(next);
      }
    } else {
      // Out of order — buffer and request missing messages
      this.pending.set(message.sequence, message);
      this.requestMissingMessages(this.lastSequence + 1, message.sequence - 1);
    }
  }

  private deliver(message: SequencedMessage): void {
    this.lastSequence = message.sequence;
    this.onOrderedMessage(message);
  }

  private requestMissingMessages(from: number, to: number): void {
    // Emit to server requesting missing sequence range
    console.log(`Requesting missing messages: ${from} to ${to}`);
    // socket.emit('messages:missing', { from, to });
  }

  getLastSequence(): number {
    return this.lastSequence;
  }
}
```

---

### Deduplication & Delivery Semantics

| Guarantee | Mechanism | Trade-off |
|-----------|-----------|-----------|
| **At-most-once** | Fire and forget; no retry | Fastest; may lose messages |
| **At-least-once** | Retry until ack; deduplicate by ID | Reliable; may deliver duplicates |
| **Exactly-once** | At-least-once + idempotent consumers | Complex; requires idempotency logic |

```typescript
import { Redis } from 'ioredis';

const redis = new Redis();
const DEDUP_KEY = (userId: string, messageId: string) => `dedup:${userId}:${messageId}`;
const DEDUP_TTL = 86400; // 24 hours

/**
 * Deduplicate message delivery by message ID.
 * Returns true if the message should be delivered.
 */
export async function shouldDeliver(userId: string, messageId: string): Promise<boolean> {
  const key = DEDUP_KEY(userId, messageId);
  const set = await redis.set(key, '1', 'EX', DEDUP_TTL, 'NX');
  return set === 'OK'; // True only if the key did not exist
}

/**
 * At-least-once delivery with acknowledgment tracking.
 */
interface DeliveryTracker {
  messageId: string;
  userId: string;
  roomId: string;
  attempts: number;
  maxAttempts: number;
  deliveredAt?: string;
  ackedAt?: string;
}

const DELIVERY_KEY = (messageId: string, userId: string) => `delivery:${messageId}:${userId}`;

export async function trackDelivery(redis: Redis, messageId: string, userId: string, roomId: string): Promise<void> {
  const tracker: DeliveryTracker = {
    messageId,
    userId,
    roomId,
    attempts: 1,
    maxAttempts: 3,
  };
  await redis.setex(DELIVERY_KEY(messageId, userId), 3600, JSON.stringify(tracker));
}

export async function markAcknowledged(redis: Redis, messageId: string, userId: string): Promise<void> {
  const key = DELIVERY_KEY(messageId, userId);
  const data = await redis.get(key);
  if (!data) return;

  const tracker: DeliveryTracker = JSON.parse(data);
  tracker.ackedAt = new Date().toISOString();
  await redis.setex(key, 3600, JSON.stringify(tracker));
}

export async function getUndeliveredMessages(redis: Redis, userId: string): Promise<DeliveryTracker[]> {
  const keys = await redis.keys(`delivery:*:${userId}`);
  if (keys.length === 0) return [];

  const values = await redis.mget(...keys);
  return values
    .filter((v): v is string => v !== null)
    .map((v) => JSON.parse(v))
    .filter((t: DeliveryTracker) => !t.ackedAt && t.attempts < t.maxAttempts);
}
```

---

## Rate Limiting Real-Time

### WebSocket Message Rate Limiter

```typescript
import { Redis } from 'ioredis';
import { Socket } from 'socket.io';

interface RateLimitConfig {
  maxMessagesPerWindow: number;  // e.g., 30
  windowSeconds: number;          // e.g., 60
  maxConnectionsPerIP: number;  // e.g., 5
  burstAllowance: number;         // e.g., 5 extra messages
}

const defaultConfig: RateLimitConfig = {
  maxMessagesPerWindow: 30,
  windowSeconds: 60,
  maxConnectionsPerIP: 5,
  burstAllowance: 5,
};

class WebSocketRateLimiter {
  private readonly redis: Redis;
  private readonly config: RateLimitConfig;

  constructor(redis: Redis, config: RateLimitConfig = defaultConfig) {
    this.redis = redis;
    this.config = config;
  }

  /**
   * Check if a user can send a message in a room.
   * Returns true if allowed, false if rate limited.
   */
  async canSendMessage(userId: string, roomId: string): Promise<boolean> {
    const key = `ratelimit:msg:${roomId}:${userId}`;
    const current = await this.redis.incr(key);

    if (current === 1) {
      await this.redis.expire(key, this.config.windowSeconds);
    }

    const limit = this.config.maxMessagesPerWindow + this.config.burstAllowance;
    return current <= limit;
  }

  /**
   * Check if an IP has exceeded max connection count.
   */
  async canConnect(ip: string): Promise<boolean> {
    const key = `ratelimit:conn:${ip}`;
    const current = await this.redis.incr(key);

    if (current === 1) {
      await this.redis.expire(key, this.config.windowSeconds);
    }

    return current <= this.config.maxConnectionsPerIP;
  }

  /**
   * Decrement connection count on disconnect.
   */
  async onDisconnect(ip: string): Promise<void> {
    const key = `ratelimit:conn:${ip}`;
    await this.redis.decr(key);
  }

  /**
   * Middleware for Socket.io to enforce rate limits on events.
   */
  middleware() {
    return async (socket: Socket, next: (err?: Error) => void) => {
      const ip = socket.handshake.address || 'unknown';
      const canConnect = await this.canConnect(ip);

      if (!canConnect) {
        return next(new Error('Rate limit exceeded: too many connections'));
      }

      socket.on('disconnect', () => this.onDisconnect(ip));

      // Wrap message handlers with rate limiting
      const originalOn = socket.on.bind(socket);
      socket.on = (event: string, handler: (...args: any[]) => void) => {
        if (event.startsWith('message:')) {
          const wrapped = async (...args: any[]) => {
            const userId = socket.data.userId;
            const roomId = args[0]?.roomId;

            if (!userId || !roomId) {
              return handler(...args);
            }

            const allowed = await this.canSendMessage(userId, roomId);
            if (!allowed) {
              socket.emit('error', { code: 'RATE_LIMITED', message: 'Too many messages. Slow down.' });
              return;
            }

            return handler(...args);
          };
          return originalOn(event, wrapped);
        }
        return originalOn(event, handler);
      };

      next();
    };
  }
}

export { WebSocketRateLimiter };
```

---

## Real-Time Architecture Patterns

### Pub/Sub with Redis

```typescript
import { Redis } from 'ioredis';

interface EventEnvelope {
  type: string;
  payload: unknown;
  metadata: {
    timestamp: string;
    source: string;
    traceId?: string;
  };
}

class RedisEventBus {
  private readonly pub: Redis;
  private readonly sub: Redis;
  private readonly handlers = new Map<string, Array<(event: EventEnvelope) => void>>();

  constructor(redisUrl: string) {
    this.pub = new Redis(redisUrl);
    this.sub = new Redis(redisUrl);

    this.sub.on('message', (channel, message) => {
      try {
        const event: EventEnvelope = JSON.parse(message);
        const handlers = this.handlers.get(channel);
        handlers?.forEach((h) => h(event));
      } catch (e) {
        console.error('Failed to parse event:', e);
      }
    });
  }

  async subscribe(channel: string, handler: (event: EventEnvelope) => void): Promise<void> {
    const handlers = this.handlers.get(channel) || [];
    handlers.push(handler);
    this.handlers.set(channel, handlers);

    if (handlers.length === 1) {
      await this.sub.subscribe(channel);
    }
  }

  async unsubscribe(channel: string, handler: (event: EventEnvelope) => void): Promise<void> {
    const handlers = this.handlers.get(channel) || [];
    const filtered = handlers.filter((h) => h !== handler);

    if (filtered.length === 0) {
      this.handlers.delete(channel);
      await this.sub.unsubscribe(channel);
    } else {
      this.handlers.set(channel, filtered);
    }
  }

  async publish(channel: string, type: string, payload: unknown, traceId?: string): Promise<void> {
    const envelope: EventEnvelope = {
      type,
      payload,
      metadata: {
        timestamp: new Date().toISOString(),
        source: process.env.SERVICE_NAME || 'unknown',
        traceId,
      },
    };
    await this.pub.publish(channel, JSON.stringify(envelope));
  }

  async disconnect(): Promise<void> {
    await this.pub.disconnect();
    await this.sub.disconnect();
  }
}

export { RedisEventBus };
```

---

### Event Bus for Real-Time Events

```typescript
import EventEmitter from 'events';

/**
 * Typed event bus for in-process real-time communication.
 * Use Redis Pub/Sub for cross-process communication.
 */
interface EventMap {
  'user:connected': { userId: string; socketId: string };
  'user:disconnected': { userId: string; socketId: string; reason: string };
  'message:created': { messageId: string; roomId: string; userId: string };
  'notification:send': { userId: string; notification: unknown };
  'presence:heartbeat': { userId: string; status: string };
}

type EventName = keyof EventMap;

class TypedEventBus {
  private readonly emitter = new EventEmitter();

  emit<T extends EventName>(event: T, payload: EventMap[T]): void {
    this.emitter.emit(event, payload);
  }

  on<T extends EventName>(event: T, handler: (payload: EventMap[T]) => void): () => void {
    this.emitter.on(event, handler);
    return () => this.emitter.off(event, handler);
  }

  once<T extends EventName>(event: T, handler: (payload: EventMap[T]) => void): void {
    this.emitter.once(event, handler);
  }

  off<T extends EventName>(event: T, handler: (payload: EventMap[T]) => void): void {
    this.emitter.off(event, handler);
  }
}

// Singleton instance for the application
export const eventBus = new TypedEventBus();

// Usage
// eventBus.on('message:created', ({ messageId, roomId }) => {
//   // Broadcast to room via WebSocket
// });
```

---

### CQRS with Read Models for Live Updates

```typescript
/**
 * CQRS Pattern: Separate command (write) and query (read) paths.
 * Read models are optimized for real-time queries and live updates.
 */

// Command side: handles writes
interface CommandHandler<T> {
  execute(command: T): Promise<void>;
}

interface SendMessageCommand {
  messageId: string;
  roomId: string;
  userId: string;
  text: string;
}

class SendMessageHandler implements CommandHandler<SendMessageCommand> {
  async execute(command: SendMessageCommand): Promise<void> {
    // 1. Validate
    // 2. Persist to write model (e.g., PostgreSQL)
    // 3. Publish event to update read models
    const event = {
      type: 'MessageSent',
      payload: command,
      sequence: await getNextSequence(command.roomId),
    };

    await eventStore.append(event);
    await eventBus.publish(`room:${command.roomId}`, 'MessageSent', event);
  }
}

// Query side: read model optimized for live updates
interface ChatRoomReadModel {
  roomId: string;
  messages: Array<{
    id: string;
    userId: string;
    text: string;
    sequence: number;
    sentAt: string;
  }>;
  participants: string[];
  lastMessageAt: string;
}

class ChatRoomReadModelProjection {
  private readonly models = new Map<string, ChatRoomReadModel>();

  constructor() {
    // Subscribe to events and update read models
    eventBus.on('message:created', ({ messageId, roomId, userId }) => {
      // Update in-memory read model or cache
      const model = this.models.get(roomId);
      if (model) {
        model.messages.push({
          id: messageId,
          userId,
          text: '', // Would be populated from event
          sequence: 0,
          sentAt: new Date().toISOString(),
        });
        model.lastMessageAt = new Date().toISOString();
      }
    });
  }

  get(roomId: string): ChatRoomReadModel | undefined {
    return this.models.get(roomId);
  }

  // Push live updates to connected clients
  async subscribeToRoom(roomId: string, onUpdate: (model: ChatRoomReadModel) => void): Promise<() => void> {
    const handler = (event: unknown) => {
      const model = this.models.get(roomId);
      if (model) onUpdate(model);
    };

    await redisEventBus.subscribe(`room:${roomId}`, handler);
    return () => redisEventBus.unsubscribe(`room:${roomId}`, handler);
  }
}

// Placeholders
const eventStore = {
  async append(_event: unknown) {},
};

async function getNextSequence(_roomId: string): Promise<number> {
  return 0;
}

const redisEventBus = new RedisEventBus('redis://localhost:6379');
const eventBus = new TypedEventBus();
```

---

### Fan-Out Pattern for Notifications

```typescript
import { Redis } from 'ioredis';

interface NotificationPayload {
  id: string;
  type: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
  priority: 'low' | 'normal' | 'high' | 'urgent';
  targetUsers: string[];
  targetRoles?: string[];
  targetChannels?: string[];
}

class NotificationFanOut {
  constructor(
    private readonly redis: Redis,
    private readonly io: SocketIOServer
  ) {}

  async send(notification: NotificationPayload): Promise<void> {
    // Resolve target users
    const userIds = await this.resolveTargets(notification);

    // Deduplicate
    const uniqueUserIds = [...new Set(userIds)];

    // Batch fan-out
    const batchSize = 100;
    for (let i = 0; i < uniqueUserIds.length; i += batchSize) {
      const batch = uniqueUserIds.slice(i, i + batchSize);
      await Promise.all(batch.map((userId) => this.deliverToUser(userId, notification)));
    }

    // Publish metrics
    await this.redis.publish('metrics:notifications', JSON.stringify({
      notificationId: notification.id,
      sentTo: uniqueUserIds.length,
      timestamp: new Date().toISOString(),
    }));
  }

  private async resolveTargets(notification: NotificationPayload): Promise<string[]> {
    const userIds = [...notification.targetUsers];

    // Resolve by roles (if supported)
    if (notification.targetRoles) {
      for (const role of notification.targetRoles) {
        const roleUsers = await this.redis.smembers(`role:${role}`);
        userIds.push(...roleUsers);
      }
    }

    // Resolve by channel membership
    if (notification.targetChannels) {
      for (const channel of notification.targetChannels) {
        const channelUsers = await this.redis.smembers(`channel:${channel}:members`);
        userIds.push(...channelUsers);
      }
    }

    return userIds;
  }

  private async deliverToUser(userId: string, notification: NotificationPayload): Promise<void> {
    // 1. Persist to user's notification inbox
    await this.redis.lpush(`inbox:${userId}`, JSON.stringify({
      ...notification,
      deliveredAt: new Date().toISOString(),
    }));

    // 2. Send real-time if online
    const online = await isOnline(userId);
    if (online) {
      emitToUser(this.io, userId, 'notification:new', {
        id: notification.id,
        type: notification.type,
        title: notification.title,
        body: notification.body,
        priority: notification.priority,
        data: notification.data,
      });
    } else {
      // 3. Queue for push notification (FCM, APNs, etc.)
      await this.redis.lpush('push:queue', JSON.stringify({
        userId,
        notification,
      }));
    }
  }
}

export { NotificationFanOut };
```

---

## Code Snippet Index

| # | Snippet | File Section | Purpose |
|---|---------|-------------|---------|
| 1 | **Express SSE Endpoint** | [Express SSE Endpoint](#express-sse-endpoint) | Production SSE server with heartbeats, user-specific events, and cleanup |
| 2 | **SSE Client (JavaScript)** | [SSE Client (JavaScript)](#sse-client-javascript) | Reconnecting client with exponential backoff and `lastEventId` tracking |
| 3 | **Socket.io Server Setup** | [Socket.io Server Setup](#socketio-server-setup) | Socket.io initialization with ping/pong and CORS |
| 4 | **Socket.io Auth Middleware** | [Socket.io Auth Middleware](#socketio-auth-middleware) | JWT token validation on WebSocket connection |
| 5 | **Socket.io with Redis Adapter** | [Socket.io with Redis Adapter](#socketio-with-redis-adapter) | Horizontal scaling with Redis for cross-server message routing |
| 6 | **Presence System with Redis** | [Heartbeat & TTL with Redis](#heartbeat--ttl-with-redis) | Online/offline tracking with TTL heartbeats and bulk presence queries |
| 7 | **Message Buffering on Disconnect** | [Message Buffering on Disconnect](#message-buffering-on-disconnect) | Buffer messages for offline users and flush on reconnect |
| 8 | **Message Ordering with Sequence Numbers** | [Sequence Numbers](#sequence-numbers) | Monotonic sequence assignment, gap detection, and ordered delivery |
| 9 | **WebSocket Message Rate Limiter** | [WebSocket Message Rate Limiter](#websocket-message-rate-limiter) | Per-user, per-room rate limiting with Redis-backed sliding window |
| 10 | **Redis Pub/Sub Event Bus** | [Pub/Sub with Redis](#pubsub-with-redis) | Typed event envelope system for cross-process real-time events |
| 11 | **Exponential Backoff Reconnection** | [Exponential Backoff Reconnection](#exponential-backoff-reconnection) | Configurable reconnection manager with jitter |
| 12 | **Connection State Machine** | [Connection State Machine](#connection-state-machine) | Finite state machine for connection lifecycle management |
| 13 | **Notification Fan-Out** | [Fan-Out Pattern for Notifications](#fan-out-pattern-for-notifications) | Batch notification delivery to users, roles, and channels |
| 14 | **SSE Reconnection with Last-Event-ID** | [Reconnection with Last-Event-ID](#reconnection-with-last-event-id) | Replay missed events on reconnection using persistent event IDs |
| 15 | **Typing Indicators & Read Receipts** | [Typing Indicators & Read Receipts](#typing-indicators--read-receipts) | Ephemeral presence indicators with Redis-backed state |
| 16 | **Deduplication & Delivery Semantics** | [Deduplication & Delivery Semantics](#deduplication--delivery-semantics) | At-least-once delivery with acknowledgment tracking and deduplication |
