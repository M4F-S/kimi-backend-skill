#!/bin/bash
set -euo pipefail

# kimi-backend: NestJS + PostgreSQL + Prisma + Redis + Docker scaffold
# Usage: bash init-nestjs-api.sh my-project

PROJECT_NAME="${1:-nestjs-api}"
DIR="$PWD/$PROJECT_NAME"

echo "🔧 Scaffolding NestJS API: $PROJECT_NAME"
mkdir -p "$DIR" && cd "$DIR"

# ─── package.json ───
cat > package.json << 'PKG'
{
  "name": "PROJECT_NAME",
  "version": "1.0.0",
  "description": "NestJS + PostgreSQL + Prisma + Redis API",
  "scripts": {
    "build": "nest build",
    "start": "nest start",
    "start:dev": "nest start --watch",
    "start:prod": "node dist/main",
    "test": "vitest",
    "test:integration": "vitest --config vitest.integration.config.ts",
    "db:generate": "prisma generate",
    "db:migrate": "prisma migrate dev",
    "db:studio": "prisma studio",
    "db:seed": "ts-node prisma/seed.ts",
    "lint": "eslint . --ext .ts",
    "format": "prettier --write ."
  },
  "dependencies": {
    "@nestjs/common": "^11.0.0",
    "@nestjs/core": "^11.0.0",
    "@nestjs/platform-express": "^11.0.0",
    "@nestjs/config": "^4.0.0",
    "@nestjs/jwt": "^11.0.0",
    "@nestjs/passport": "^11.0.0",
    "@nestjs/terminus": "^11.0.0",
    "@prisma/client": "^6.0.0",
    "bcrypt": "^5.1.0",
    "class-transformer": "^0.5.1",
    "class-validator": "^0.14.1",
    "helmet": "^8.0.0",
    "ioredis": "^5.4.0",
    "passport": "^0.7.0",
    "passport-jwt": "^4.0.0",
    "pino": "^9.0.0",
    "pino-pretty": "^13.0.0",
    "nestjs-pino": "^4.0.0",
    "prom-client": "^15.1.0",
    "reflect-metadata": "^0.2.0",
    "rxjs": "^7.8.0",
    "zod": "^3.24.0"
  },
  "devDependencies": {
    "@nestjs/cli": "^11.0.0",
    "@nestjs/schematics": "^11.0.0",
    "@nestjs/testing": "^11.0.0",
    "@types/bcrypt": "^5.0.0",
    "@types/express": "^5.0.0",
    "@types/node": "^22.0.0",
    "@types/passport-jwt": "^4.0.0",
    "@typescript-eslint/eslint-plugin": "^8.0.0",
    "@typescript-eslint/parser": "^8.0.0",
    "eslint": "^9.0.0",
    "prettier": "^3.4.0",
    "prisma": "^6.0.0",
    "supertest": "^7.0.0",
    "ts-node": "^10.9.0",
    "typescript": "^5.7.0",
    "vitest": "^3.0.0"
  }
}
PKG
sed -i.bak "s/PROJECT_NAME/$PROJECT_NAME/g" package.json && rm package.json.bak

# ─── tsconfig.json ───
cat > tsconfig.json << 'TSC'
{
  "compilerOptions": {
    "module": "commonjs",
    "declaration": true,
    "removeComments": true,
    "emitDecoratorMetadata": true,
    "experimentalDecorators": true,
    "allowSyntheticDefaultImports": true,
    "target": "ES2021",
    "sourceMap": true,
    "outDir": "./dist",
    "baseUrl": "./",
    "incremental": true,
    "skipLibCheck": true,
    "strictNullChecks": true,
    "noImplicitAny": true,
    "strictBindCallApply": true,
    "forceConsistentCasingInFileNames": true,
    "noFallthroughCasesInSwitch": true,
    "paths": { "@/*": ["src/*"] }
  }
}
TSC

# ─── nest-cli.json ───
cat > nest-cli.json << 'NEST'
{"collection": "@nestjs/schematics", "sourceRoot": "src", "compilerOptions": {"deleteOutDir": true}}
NEST

# ─── src/main.ts ───
mkdir -p src
cat > src/main.ts << 'MAIN'
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { ValidationPipe } from '@nestjs/common';
import helmet from 'helmet';
import { Logger } from 'nestjs-pino';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  app.useLogger(app.get(Logger));
  app.use(helmet());
  app.enableCors({ origin: process.env.CORS_ORIGIN?.split(',') ?? [], credentials: true });
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
  app.setGlobalPrefix('api/v1');
  await app.listen(process.env.PORT ?? 3000);
  console.log(`🚀 Server running on http://localhost:${process.env.PORT ?? 3000}`);
}
bootstrap();
MAIN

# ─── src/app.module.ts ───
cat > src/app.module.ts << 'APP'
import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { LoggerModule } from 'nestjs-pino';
import { TerminusModule } from '@nestjs/terminus';
import { AuthModule } from './auth/auth.module';
import { UsersModule } from './users/users.module';
import { HealthController } from './health/health.controller';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    LoggerModule.forRoot({
      pinoHttp: {
        level: process.env.LOG_LEVEL ?? 'info',
        redact: ['req.headers.authorization', '*.password', '*.token'],
      },
    }),
    TerminusModule,
    AuthModule,
    UsersModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
APP

# ─── src/health/health.controller.ts ───
mkdir -p src/health
cat > src/health/health.controller.ts << 'HEALTH'
import { Controller, Get } from '@nestjs/common';
import { HealthCheck, HealthCheckService, PrismaHealthIndicator } from '@nestjs/terminus';

@Controller('health')
export class HealthController {
  constructor(private health: HealthCheckService, private prisma: PrismaHealthIndicator) {}

  @Get()
  @HealthCheck()
  check() {
    return this.health.check([() => this.prisma.pingCheck('database')]);}
}
HEALTH

# ─── src/auth/auth.module.ts ───
mkdir -p src/auth
cat > src/auth/auth.module.ts << 'AUTHM'
import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { JwtStrategy } from './jwt.strategy';

@Module({
  imports: [JwtModule.register({ secret: process.env.JWT_SECRET!, signOptions: { expiresIn: '15m' } })],
  controllers: [AuthController],
  providers: [AuthService, JwtStrategy],
})
export class AuthModule {}
AUTHM

# ─── src/auth/jwt.strategy.ts ───
cat > src/auth/jwt.strategy.ts << 'JWT'
import { Injectable } from '@nestjs/common';
import { PassportStrategy } from '@nestjs/passport';
import { ExtractJwt, Strategy } from 'passport-jwt';

@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  constructor() {
    super({ jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(), secretOrKey: process.env.JWT_SECRET! });
  }
  async validate(payload: { sub: string; email: string }) {
    return { userId: payload.sub, email: payload.email };
  }
}
JWT

# ─── src/auth/auth.controller.ts ───
cat > src/auth/auth.controller.ts << 'AUTHC'
import { Controller, Post, Body, UnauthorizedException } from '@nestjs/common';
import { AuthService } from './auth.service';
import { LoginDto } from './dto/login.dto';

@Controller('auth')
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  @Post('login')
  async login(@Body() dto: LoginDto) {
    const user = await this.authService.validateUser(dto.email, dto.password);
    if (!user) throw new UnauthorizedException('Invalid credentials');
    return this.authService.login(user);
  }
}
AUTHC

# ─── src/auth/auth.service.ts ───
cat > src/auth/auth.service.ts << 'AUTHS'
import { Injectable } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { PrismaClient } from '@prisma/client';
import * as bcrypt from 'bcrypt';

const prisma = new PrismaClient();

@Injectable()
export class AuthService {
  constructor(private jwtService: JwtService) {}

  async validateUser(email: string, password: string) {
    const user = await prisma.user.findUnique({ where: { email } });
    if (!user) return null;
    const ok = await bcrypt.compare(password, user.passwordHash);
    return ok ? user : null;
  }

  async login(user: { id: string; email: string }) {
    const payload = { sub: user.id, email: user.email };
    return { accessToken: this.jwtService.sign(payload) };
  }
}
AUTHS

# ─── src/auth/dto/login.dto.ts ───
mkdir -p src/auth/dto
cat > src/auth/dto/login.dto.ts << 'DTO'
import { IsEmail, IsString, MinLength } from 'class-validator';

export class LoginDto {
  @IsEmail() email: string;
  @IsString() @MinLength(8) password: string;
}
DTO

# ─── src/users/users.module.ts ───
mkdir -p src/users
cat > src/users/users.module.ts << 'USERSM'
import { Module } from '@nestjs/common';
import { UsersController } from './users.controller';
import { UsersService } from './users.service';

@Module({ controllers: [UsersController], providers: [UsersService] })
export class UsersModule {}
USERSM

# ─── src/users/users.controller.ts ───
cat > src/users/users.controller.ts << 'USERSC'
import { Controller, Get, Post, Body, UseGuards, Request, Param } from '@nestjs/common';
import { AuthGuard } from '@nestjs/passport';
import { UsersService } from './users.service';
import { CreateUserDto } from './dto/create-user.dto';

@Controller('users')
export class UsersController {
  constructor(private readonly usersService: UsersService) {}

  @Post()
  async create(@Body() dto: CreateUserDto) { return this.usersService.create(dto); }

  @Get('me')
  @UseGuards(AuthGuard('jwt'))
  async me(@Request() req: { user: { userId: string } }) {
    return this.usersService.findById(req.user.userId);
  }

  @Get(':id')
  @UseGuards(AuthGuard('jwt'))
  async findOne(@Param('id') id: string, @Request() req: { user: { userId: string } }) {
    // BOLA prevention: verify ownership
    const user = await this.usersService.findById(id);
    if (!user || user.id !== req.user.userId) return { error: 'Not found' };
    return user;
  }
}
USERSC

# ─── src/users/users.service.ts ───
cat > src/users/users.service.ts << 'USERSS'
import { Injectable } from '@nestjs/common';
import { PrismaClient } from '@prisma/client';
import * as bcrypt from 'bcrypt';

const prisma = new PrismaClient();

@Injectable()
export class UsersService {
  async create(data: { email: string; password: string; name?: string }) {
    const passwordHash = await bcrypt.hash(data.password, 12);
    return prisma.user.create({ data: { ...data, passwordHash } });
  }
  async findById(id: string) { return prisma.user.findUnique({ where: { id }, select: { id: true, email: true, name: true, createdAt: true } }); }
}
USERSS

# ─── src/users/dto/create-user.dto.ts ───
mkdir -p src/users/dto
cat > src/users/dto/create-user.dto.ts << 'CDTO'
import { IsEmail, IsString, MinLength, IsOptional } from 'class-validator';

export class CreateUserDto {
  @IsEmail() email: string;
  @IsString() @MinLength(8) password: string;
  @IsOptional() @IsString() name?: string;
}
CDTO

# ─── prisma/schema.prisma ───
mkdir -p prisma
cat > prisma/schema.prisma << 'PRISMA'
generator client { provider = "prisma-client-js" }

datasource db { provider = "postgresql", url = env("DATABASE_URL") }

model User {
  id            String   @id @default(cuid())
  email         String   @unique
  name          String?
  passwordHash  String
  role          String   @default("user")
  createdAt     DateTime @default(now())
  updatedAt     DateTime @updatedAt
  @@index([email])
  @@index([role])
}

model AuditLog {
  id        String   @id @default(cuid())
  action    String
  userId    String?
  metadata  Json?
  createdAt DateTime @default(now())
  @@index([createdAt])
  @@index([userId])
}
PRISMA

# ─── prisma/seed.ts ───
cat > prisma/seed.ts << 'SEED'
import { PrismaClient } from '@prisma/client';
import * as bcrypt from 'bcrypt';

const prisma = new PrismaClient();

async function main() {
  const passwordHash = await bcrypt.hash('admin123!', 12);
  await prisma.user.upsert({
    where: { email: 'admin@example.com' },
    update: {},
    create: { email: 'admin@example.com', name: 'Admin', passwordHash, role: 'admin' },
  });
  console.log('✅ Seeded admin user');
}

main().catch(console.error).finally(() => prisma.$disconnect());
SEED

# ─── .env.example ───
cat > .env.example << 'ENV'
NODE_ENV=development
PORT=3000
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/PROJECT_NAME?schema=public
REDIS_URL=redis://localhost:6379
JWT_SECRET=change-me-in-production-min-32-characters-long
CORS_ORIGIN=http://localhost:3000,http://localhost:5173
LOG_LEVEL=info
ENV
sed -i.bak "s/PROJECT_NAME/$PROJECT_NAME/g" .env.example && rm .env.example.bak

# ─── .env ───
cp .env.example .env

# ─── Dockerfile ───
cat > Dockerfile << 'DF'
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npx prisma generate && npm run build

FROM node:22-alpine AS production
RUN apk add --no-cache dumb-init
ENV NODE_ENV=production
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
COPY --from=builder /app/prisma ./prisma
RUN npx prisma generate
EXPOSE 3000
USER node
CMD ["dumb-init", "node", "dist/main.js"]
DF

# ─── docker-compose.yml ───
cat > docker-compose.yml << 'DC'
version: '3.8'

services:
  app:
    build: .
    ports: ["3000:3000"]
    env_file: .env
    depends_on:
      db: { condition: service_healthy }
      redis: { condition: service_healthy }
    volumes: [".:/app", "/app/node_modules"]
    command: npm run start:dev

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: PROJECT_NAME
    ports: ["5432:5432"]
    volumes: ["postgres_data:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  pgadmin:
    image: dpage/pgadmin4:latest
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@example.com
      PGADMIN_DEFAULT_PASSWORD: admin
    ports: ["5050:80"]
    depends_on: [db]

volumes:
  postgres_data:
DC
sed -i.bak "s/PROJECT_NAME/$PROJECT_NAME/g" docker-compose.yml && rm docker-compose.yml.bak

# ─── .dockerignore ───
cat > .dockerignore << 'DIGNORE'
node_modules
.env
.env.local
.DS_Store
*.log
dist
coverage
.vscode
.idea
DIGNORE

# ─── .gitignore ───
cat > .gitignore << 'GITIGNORE'
node_modules
.env
.env.local
*.log
dist
coverage
.vscode
.idea
*.tsbuildinfo
GITIGNORE

# ─── vitest.config.ts ───
cat > vitest.config.ts << 'VITEST'
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { environment: 'node', globals: true, setupFiles: ['./test/setup.ts'] },
});
VITEST

# ─── test/setup.ts ───
mkdir -p test
cat > test/setup.ts << 'SETUP'
// Global test setup — mock external services here
SETUP

# ─── .github/workflows/ci.yml ───
mkdir -p .github/workflows
cat > .github/workflows/ci.yml << 'CI'
name: CI/CD
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env: { POSTGRES_USER: postgres, POSTGRES_PASSWORD: postgres, POSTGRES_DB: test }
        options: >-
          --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5
        ports: ["5432:5432"]
      redis:
        image: redis:7-alpine
        ports: ["6379:6379"]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22', cache: 'npm' }
      - run: npm ci
      - run: npx prisma generate
      - run: npx prisma migrate deploy
        env: { DATABASE_URL: postgresql://postgres:postgres@localhost:5432/test?schema=public }
      - run: npm run test
      - run: npm run build
      - uses: aquasecurity/trivy-action@master
        with: { image-ref: '.', format: 'table', exit-code: '1', severity: 'CRITICAL,HIGH' }
CI

echo ""
echo "✅ NestJS scaffold complete: $PROJECT_NAME"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npm install"
echo "  npx prisma migrate dev --name init"
echo "  npm run db:seed"
echo "  docker compose up -d db redis"
echo "  npm run start:dev"
