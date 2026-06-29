#!/bin/bash
set -euo pipefail

# kimi-backend: FastAPI + PostgreSQL + SQLAlchemy + Alembic + Docker scaffold
# Usage: bash init-fastapi-api.sh my-project

PROJECT_NAME="${1:-fastapi-api}"
DIR="$PWD/$PROJECT_NAME"

echo "🔧 Scaffolding FastAPI API: $PROJECT_NAME"
mkdir -p "$DIR" && cd "$DIR"

# ─── pyproject.toml ───
cat > pyproject.toml << 'PY'
[project]
name = "PROJECT_NAME"
version = "1.0.0"
description = "FastAPI + PostgreSQL + SQLAlchemy + Alembic API"
requires-python = ">=3.11"
dependencies = [
  "fastapi[standard]>=0.115",
  "uvicorn[standard]>=0.32",
  "sqlalchemy>=2.0",
  "asyncpg>=0.30",
  "alembic>=1.14",
  "pydantic>=2.9",
  "pydantic-settings>=2.6",
  "python-jose[cryptography]>=3.3",
  "passlib[bcrypt]>=1.7",
  "python-multipart>=0.0.17",
  "httpx>=0.28",
  "redis>=5.2",
  "prometheus-client>=0.21",
  "structlog>=24.4",
  "python-json-logger>=2.0",
  "email-validator>=2.2",
]

[project.optional-dependencies]
dev = [
  "pytest>=8.3",
  "pytest-asyncio>=0.24",
  "pytest-cov>=6.0",
  "httpx>=0.28",
  "testcontainers>=4.9",
  "ruff>=0.8",
  "mypy>=1.13",
  "pre-commit>=4.0",
]

[tool.ruff]
line-length = 100
target-version = "py311"
[tool.ruff.lint]
select = ["E", "F", "I", "N", "W", "UP", "B", "C4", "SIM"]

[tool.mypy]
python_version = "3.11"
strict = true
warn_return_any = true
warn_unused_ignores = true

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
PY
sed -i.bak "s/PROJECT_NAME/$PROJECT_NAME/g" pyproject.toml && rm pyproject.toml.bak

# ─── app/main.py ───
mkdir -p app
cat > app/main.py << 'MAIN'
import structlog
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from prometheus_client import make_asgi_app

from app.config import settings
from app.database import engine
from app.routers import auth, users, health
from app.middleware.logging import LoggingMiddleware
from app.middleware.rate_limit import RateLimitMiddleware

logger = structlog.get_logger()

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("🚀 Starting up", service=settings.APP_NAME)
    yield
    logger.info("🛑 Shutting down")
    await engine.dispose()

app = FastAPI(
    title=settings.APP_NAME,
    version=settings.APP_VERSION,
    docs_url="/docs" if settings.ENV != "production" else None,
    lifespan=lifespan,
)

app.add_middleware(LoggingMiddleware)
app.add_middleware(RateLimitMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
    allow_headers=["*"],
)

app.include_router(health.router, prefix="/api/v1/health", tags=["health"])
app.include_router(auth.router, prefix="/api/v1/auth", tags=["auth"])
app.include_router(users.router, prefix="/api/v1/users", tags=["users"])

metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error("Unhandled exception", error=str(exc), path=request.url.path)
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error", "code": "INTERNAL_ERROR", "request_id": getattr(request.state, "request_id", None)}
    )
MAIN

# ─── app/config.py ───
cat > app/config.py << 'CONFIG'
from pydantic_settings import BaseSettings
from pydantic import Field, validator

class Settings(BaseSettings):
    APP_NAME: str = "FastAPI App"
    APP_VERSION: str = "1.0.0"
    ENV: str = "development"
    DATABASE_URL: str = Field(..., env="DATABASE_URL")
    REDIS_URL: str = Field(default="redis://localhost:6379", env="REDIS_URL")
    JWT_SECRET: str = Field(..., env="JWT_SECRET")
    JWT_ALGORITHM: str = "HS256"
    JWT_ACCESS_TOKEN_EXPIRE_MINUTES: int = 15
    JWT_REFRESH_TOKEN_EXPIRE_DAYS: int = 7
    CORS_ORIGINS: list[str] = ["http://localhost:3000"]
    LOG_LEVEL: str = "info"
    RATE_LIMIT_ENABLED: bool = True

    @validator("CORS_ORIGINS", pre=True, always=True)
    def parse_cors_origins(cls, v):
        if isinstance(v, str):
            return [x.strip() for x in v.split(",")]
        return v

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"

settings = Settings()
CONFIG

# ─── app/database.py ───
cat > app/database.py << 'DB'
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base
from app.config import settings

engine = create_async_engine(
    settings.DATABASE_URL,
    echo=settings.ENV == "development",
    pool_pre_ping=True,
    pool_size=5,
    max_overflow=10,
)

AsyncSessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
Base = declarative_base()

async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
        finally:
            await session.close()
DB

# ─── app/models.py ───
cat > app/models.py << 'MODELS'
import uuid
from datetime import datetime, timezone
from sqlalchemy import Column, String, DateTime, Integer, Index, func
from sqlalchemy.dialects.postgresql import UUID, JSONB
from app.database import Base

def now_utc():
    return datetime.now(timezone.utc)

class User(Base):
    __tablename__ = "users"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email = Column(String(255), unique=True, nullable=False, index=True)
    name = Column(String(255))
    password_hash = Column(String(255), nullable=False)
    role = Column(String(50), default="user", index=True)
    created_at = Column(DateTime(timezone=True), default=now_utc)
    updated_at = Column(DateTime(timezone=True), default=now_utc, onupdate=now_utc)

class AuditLog(Base):
    __tablename__ = "audit_logs"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    action = Column(String(100), nullable=False)
    user_id = Column(UUID(as_uuid=True), index=True)
    metadata = Column(JSONB)
    created_at = Column(DateTime(timezone=True), default=now_utc, index=True)
    
    __table_args__ = (Index("ix_audit_logs_created_at_user_id", "created_at", "user_id"),)
MODELS

# ─── app/schemas.py ───
cat > app/schemas.py << 'SCHEMAS'
from pydantic import BaseModel, EmailStr, Field, ConfigDict
from datetime import datetime
from uuid import UUID

class UserBase(BaseModel):
    email: EmailStr
    name: str | None = None

class UserCreate(UserBase):
    password: str = Field(..., min_length=8)

class UserResponse(UserBase):
    model_config = ConfigDict(from_attributes=True)
    id: UUID
    role: str
    created_at: datetime

class UserMe(UserResponse):
    pass

class LoginRequest(BaseModel):
    email: EmailStr
    password: str

class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int

class ErrorResponse(BaseModel):
    error: str
    code: str
    details: dict | None = None
    request_id: str | None = None
SCHEMAS

# ─── app/routers/health.py ───
mkdir -p app/routers
cat > app/routers/health.py << 'HEALTH'
from fastapi import APIRouter, status
from sqlalchemy import text
from app.database import engine

router = APIRouter()

@router.get("/live", status_code=status.HTTP_200_OK)
async def liveness():
    return {"status": "alive"}

@router.get("/ready", status_code=status.HTTP_200_OK)
async def readiness():
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        return {"status": "ready"}
    except Exception as e:
        return {"status": "not_ready", "detail": str(e)}
HEALTH

# ─── app/routers/auth.py ───
cat > app/routers/auth.py << 'AUTH'
from datetime import datetime, timedelta, timezone
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession
from jose import JWTError, jwt
from passlib.context import CryptContext

from app.config import settings
from app.database import get_db
from app.models import User
from app.schemas import LoginRequest, TokenResponse
from app.middleware.logging import get_request_id

router = APIRouter()
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
security = HTTPBearer(auto_error=False)

def create_access_token(data: dict, expires_delta: timedelta | None = None) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + (expires_delta or timedelta(minutes=15))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM)

async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: AsyncSession = Depends(get_db)
) -> User:
    if not credentials:
        raise HTTPException(status_code=401, detail="Not authenticated")
    try:
        payload = jwt.decode(credentials.credentials, settings.JWT_SECRET, algorithms=[settings.JWT_ALGORITHM])
        user_id = payload.get("sub")
        if not user_id:
            raise HTTPException(status_code=401, detail="Invalid token")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
    
    from sqlalchemy import select
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
    return user

@router.post("/login", response_model=TokenResponse)
async def login(data: LoginRequest, db: AsyncSession = Depends(get_db)):
    from sqlalchemy import select
    result = await db.execute(select(User).where(User.email == data.email))
    user = result.scalar_one_or_none()
    if not user or not pwd_context.verify(data.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    
    access_token = create_access_token(
        {"sub": str(user.id), "email": user.email},
        timedelta(minutes=settings.JWT_ACCESS_TOKEN_EXPIRE_MINUTES)
    )
    return {"access_token": access_token, "token_type": "bearer", "expires_in": settings.JWT_ACCESS_TOKEN_EXPIRE_MINUTES * 60}

@router.get("/me")
async def me(current_user: User = Depends(get_current_user)):
    return {"id": str(current_user.id), "email": current_user.email, "name": current_user.name, "role": current_user.role}
AUTH

# ─── app/routers/users.py ───
cat > app/routers/users.py << 'USERS'
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.database import get_db
from app.models import User
from app.schemas import UserCreate, UserResponse
from app.routers.auth import get_current_user, pwd_context
from app.middleware.logging import get_request_id

router = APIRouter()

@router.post("/", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
async def create_user(data: UserCreate, db: AsyncSession = Depends(get_db)):
    existing = await db.execute(select(User).where(User.email == data.email))
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Email already registered")
    
    user = User(
        email=data.email,
        name=data.name,
        password_hash=pwd_context.hash(data.password)
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user

@router.get("/me")
async def get_me(current_user: User = Depends(get_current_user)):
    return {"id": str(current_user.id), "email": current_user.email, "name": current_user.name, "role": current_user.role}

@router.get("/{user_id}")
async def get_user(user_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    # BOLA prevention: users can only access their own data
    if str(current_user.id) != user_id:
        raise HTTPException(status_code=404, detail="Not found")
    
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="Not found")
    return {"id": str(user.id), "email": user.email, "name": user.name, "role": user.role}
USERS

# ─── app/middleware/logging.py ───
mkdir -p app/middleware
cat > app/middleware/logging.py << 'LOGMW'
import time
import uuid
import structlog
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

logger = structlog.get_logger()

async def get_request_id():
    # This is a placeholder; actual request_id comes from request.state
    return str(uuid.uuid4())

class LoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request_id = str(uuid.uuid4())
        request.state.request_id = request_id
        
        start = time.time()
        logger.info(
            "request_started",
            request_id=request_id,
            method=request.method,
            path=request.url.path,
            client=request.client.host if request.client else None,
        )
        
        try:
            response = await call_next(request)
        except Exception as e:
            logger.error("request_failed", request_id=request_id, error=str(e))
            raise
        
        duration_ms = (time.time() - start) * 1000
        logger.info(
            "request_completed",
            request_id=request_id,
            method=request.method,
            path=request.url.path,
            status=response.status_code,
            duration_ms=round(duration_ms, 2),
        )
        response.headers["X-Request-Id"] = request_id
        return response
LOGMW

# ─── app/middleware/rate_limit.py ───
cat > app/middleware/rate_limit.py << 'RATELIMIT'
import time
import redis.asyncio as redis
from fastapi import HTTPException
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response
from app.config import settings

redis_client = redis.from_url(settings.REDIS_URL, decode_responses=True) if settings.RATE_LIMIT_ENABLED else None

class RateLimitMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if not redis_client or request.method == "OPTIONS":
            return await call_next(request)
        
        # Simple per-IP rate limit: 100 requests per minute
        client_ip = request.client.host if request.client else "unknown"
        key = f"ratelimit:{client_ip}"
        
        current = await redis_client.get(key)
        if current and int(current) >= 100:
            raise HTTPException(status_code=429, detail="Rate limit exceeded")
        
        pipe = redis_client.pipeline()
        pipe.incr(key)
        pipe.expire(key, 60)
        await pipe.execute()
        
        response = await call_next(request)
        return response
RATELIMIT

# ─── alembic.ini ───
cat > alembic.ini << 'ALEMBIC'
[alembic]
script_location = alembic
prepend_sys_path = .
version_path_separator = os
sqlalchemy.url = %(DATABASE_URL)s

[post_write_hooks]
[loggers]
keys = root,sqlalchemy,alembic
[handlers]
keys = console
[formatters]
keys = generic
[logger_root]
level = WARN
handlers = console
qualname =
[logger_sqlalchemy]
level = WARN
handlers =
qualname = sqlalchemy.engine
[logger_alembic]
level = INFO
handlers =
qualname = alembic
[handler_console]
class = StreamHandler
args = (sys.stderr,)
level = NOTSET
formatter = generic
[formatter_generic]
format = %(levelname)-5.5s [%(name)s] %(message)s
datefmt = %H:%M:%S
ALEMBIC

# ─── alembic/env.py ───
mkdir -p alembic/versions
cat > alembic/env.py << 'ALEMBIC_ENV'
import asyncio
from logging.config import fileConfig
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config
from alembic import context
from app.config import settings
from app.database import Base
from app.models import User, AuditLog  # noqa: F401 — import all models for autogenerate

config = context.config
config.set_main_option("sqlalchemy.url", settings.DATABASE_URL)
if config.config_file_name:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata

def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(url=url, target_metadata=target_metadata, literal_binds=True, dialect_opts={"paramstyle": "named"})
    with context.begin_transaction():
        context.run_migrations()

async def run_async_migrations() -> None:
    connectable = async_engine_from_config(config.get_section(config.config_ini_section, {}), prefix="sqlalchemy.", poolclass=pool.NullPool)
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()

def do_run_migrations(connection: Connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata)
    with context.begin_transaction():
        context.run_migrations()

def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())

if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
ALEMBIC_ENV

# ─── alembic/script.py.mako ───
cat > alembic/script.py.mako << 'MAKO'
"""${message}

Revision ID: ${up_revision}
Revises: ${down_revision | comma,n}
Create Date: ${create_date}

"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
${imports if imports else ""}

revision: str = ${repr(up_revision)}
down_revision: Union[str, None] = ${repr(down_revision)}
branch_labels: Union[str, Sequence[str], None] = ${repr(branch_labels)}
depends_on: Union[str, Sequence[str], None] = ${repr(depends_on)}

def upgrade() -> None:
    ${upgrades if upgrades else "pass"}

def downgrade() -> None:
    ${downgrades if downgrades else "pass"}
MAKO

# ─── .env.example ───
cat > .env.example << 'ENV'
APP_NAME=PROJECT_NAME
APP_VERSION=1.0.0
ENV=development
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/PROJECT_NAME
REDIS_URL=redis://localhost:6379
JWT_SECRET=change-me-in-production-min-32-characters-long
CORS_ORIGINS=http://localhost:3000,http://localhost:5173
LOG_LEVEL=info
RATE_LIMIT_ENABLED=true
ENV
sed -i.bak "s/PROJECT_NAME/$PROJECT_NAME/g" .env.example && rm .env.example.bak

# ─── .env ───
cp .env.example .env

# ─── Dockerfile ───
cat > Dockerfile << 'DF'
FROM python:3.12-slim AS builder
WORKDIR /app
RUN pip install --no-cache-dir uv
COPY pyproject.toml ./
RUN uv pip install --system -e ".[dev]"

FROM python:3.12-slim AS production
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PYTHONFAULTHANDLER=1
WORKDIR /app
RUN pip install --no-cache-dir uv
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY . .
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/api/v1/health/live')" || exit 1
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
DF

# ─── docker-compose.yml ───
cat > docker-compose.yml << 'DC'
version: '3.8'

services:
  app:
    build: .
    ports: ["8000:8000"]
    env_file: .env
    depends_on:
      db: { condition: service_healthy }
      redis: { condition: service_healthy }
    volumes: [".:/app"]
    command: uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

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

volumes:
  postgres_data:
DC
sed -i.bak "s/PROJECT_NAME/$PROJECT_NAME/g" docker-compose.yml && rm docker-compose.yml.bak

# ─── .dockerignore ───
cat > .dockerignore << 'DIGNORE'
__pycache__
*.pyc
*.pyo
.env
.env.local
.venv
*.egg-info
.pytest_cache
.coverage
htmlcov
.mypy_cache
.ruff_cache
.DS_Store
.vscode
.idea
DIGNORE

# ─── .gitignore ───
cat > .gitignore << 'GITIGNORE'
__pycache__
*.pyc
*.pyo
.env
.env.local
.venv
*.egg-info
.pytest_cache
.coverage
htmlcov
.mypy_cache
.ruff_cache
.DS_Store
.vscode
.idea
*.egg-info/
dist/
build/
GITIGNORE

# ─── tests/__init__.py ───
mkdir -p tests
touch tests/__init__.py

# ─── tests/conftest.py ───
cat > tests/conftest.py << 'CONFTEST'
import pytest
from httpx import AsyncClient
from app.main import app

@pytest.fixture
async def client():
    async with AsyncClient(app=app, base_url="http://test") as ac:
        yield ac
CONFTEST

# ─── tests/test_auth.py ───
cat > tests/test_auth.py << 'TESTAUTH'
import pytest
from httpx import AsyncClient
from app.main import app

@pytest.mark.asyncio
async def test_login_invalid_credentials():
    async with AsyncClient(app=app, base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/login", json={"email": "test@test.com", "password": "wrong"})
    assert response.status_code == 401

@pytest.mark.asyncio
async def test_health_live():
    async with AsyncClient(app=app, base_url="http://test") as ac:
        response = await ac.get("/api/v1/health/live")
    assert response.status_code == 200
    assert response.json()["status"] == "alive"
TESTAUTH

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
      - uses: actions/setup-python@v5
        with: { python-version: '3.12' }
      - run: pip install uv
      - run: uv pip install -e ".[dev]"
      - run: alembic upgrade head
        env: { DATABASE_URL: postgresql+asyncpg://postgres:postgres@localhost:5432/test }
      - run: pytest --cov=app --cov-report=xml
      - run: ruff check .
      - run: mypy app
      - run: docker build -t app:test .
CI

# ─── .pre-commit-config.yaml ───
cat > .pre-commit-config.yaml << 'PRECOMMIT'
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.8.0
    hooks:
      - id: ruff
      - id: ruff-format
  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: v1.13.0
    hooks:
      - id: mypy
        additional_dependencies: [types-all]
PRECOMMIT

echo ""
echo "✅ FastAPI scaffold complete: $PROJECT_NAME"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  pip install uv"
echo "  uv pip install -e '.[dev]'"
echo "  alembic init alembic  # (already done)"
echo "  alembic revision --autogenerate -m 'init'"
echo "  alembic upgrade head"
echo "  docker compose up -d db redis"
echo "  uvicorn app.main:app --reload"
