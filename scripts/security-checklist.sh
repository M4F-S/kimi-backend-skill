#!/bin/bash
set -euo pipefail

# kimi-backend: Automated API Security Checklist
# Usage: bash security-checklist.sh http://localhost:3000
#        bash security-checklist.sh http://localhost:3000 --auth-token "Bearer eyJ..."

API_BASE="${1:-}"
AUTH_HEADER="${2:-}"

if [ -z "$API_BASE" ]; then
  echo "Usage: bash security-checklist.sh <api-base-url> [--auth-token 'Bearer TOKEN']"
  echo ""
  echo "Example:"
  echo "  bash security-checklist.sh http://localhost:3000"
  echo "  bash security-checklist.sh http://localhost:3000 --auth-token 'Bearer eyJ...'"
  exit 1
fi

CURL_FLAGS="-s -o /dev/null -w %{http_code}"
AUTH=""
if [ -n "$AUTH_HEADER" ]; then
  AUTH="-H Authorization: $AUTH_HEADER"
fi

PASS=0
FAIL=0
TOTAL=0

check() {
  TOTAL=$((TOTAL + 1))
  local name="$1"
  local status="$2"
  if [ "$status" = "pass" ]; then
    echo "✅ PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "❌ FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "🔒 API Security Checklist"
echo "========================"
echo "Target: $API_BASE"
echo ""

# ─── 1. HTTPS Enforcement ───
HTTP_CODE=$(curl $CURL_FLAGS "$API_BASE" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "308" ] || [[ "$API_BASE" == https://* ]]; then
  check "HTTPS redirect / already HTTPS" "pass"
else
  check "HTTPS redirect / already HTTPS" "fail"
fi

# ─── 2. Security Headers ───
HEADERS=$(curl -s -I "$API_BASE" 2>/dev/null | tr '[:upper:]' '[:lower:]')
if echo "$HEADERS" | grep -q "strict-transport-security"; then check "HSTS header present" "pass"; else check "HSTS header present" "fail"; fi
if echo "$HEADERS" | grep -q "x-content-type-options"; then check "X-Content-Type-Options header" "pass"; else check "X-Content-Type-Options header" "fail"; fi
if echo "$HEADERS" | grep -q "x-frame-options"; then check "X-Frame-Options header" "pass"; else check "X-Frame-Options header" "fail"; fi
if echo "$HEADERS" | grep -q "content-security-policy"; then check "Content-Security-Policy header" "pass"; else check "Content-Security-Policy header" "fail"; fi
if echo "$HEADERS" | grep -q "x-powered-by"; then check "X-Powered-By header removed" "fail"; else check "X-Powered-By header removed" "pass"; fi

# ─── 3. CORS ───
CORS_PREFLIGHT=$(curl -s -I -X OPTIONS -H "Origin: https://evil.com" -H "Access-Control-Request-Method: POST" "$API_BASE" 2>/dev/null | tr '[:upper:]' '[:lower:]')
if echo "$CORS_PREFLIGHT" | grep -q "access-control-allow-origin: https://evil.com"; then
  check "CORS not allowing wildcard/origins" "fail"
else
  check "CORS not allowing wildcard/origins" "pass"
fi

# ─── 4. Rate Limiting ───
R1=$(curl -s -o /dev/null -w "%{http_code}" "$API_BASE" 2>/dev/null)
R2=$(curl -s -o /dev/null -w "%{http_code}" "$API_BASE" 2>/dev/null)
R3=$(curl -s -o /dev/null -w "%{http_code}" "$API_BASE" 2>/dev/null)
R4=$(curl -s -o /dev/null -w "%{http_code}" "$API_BASE" 2>/dev/null)
R5=$(curl -s -o /dev/null -w "%{http_code}" "$API_BASE" 2>/dev/null)
if [ "$R5" = "429" ] || [ "$R5" = "503" ]; then
  check "Rate limiting responds with 429" "pass"
else
  check "Rate limiting responds with 429" "fail"
fi

# ─── 5. Input Validation ───
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{"email": "not-an-email"}' "$API_BASE" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "422" ]; then
  check "Invalid input rejected with 400/422" "pass"
else
  check "Invalid input rejected with 400/422" "fail"
fi

# ─── 6. SQL Injection Test ───
SQL_PAYLOAD="admin' OR '1'='1"
# Try on a common endpoint that might accept user input
SQL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"email\":\"$SQL_PAYLOAD\",\"password\":\"test\"}" "$API_BASE" 2>/dev/null || echo "000")
# If it returns 200 with valid data, that's suspicious. If 400/401/500, that's fine.
if [ "$SQL_CODE" = "200" ]; then
  check "SQL injection payload rejected" "fail"
else
  check "SQL injection payload rejected" "pass"
fi

# ─── 7. Authentication Required ───
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_BASE" 2>/dev/null || echo "000")
# This is a general check; specific protected endpoints need auth
if [ -n "$AUTH_HEADER" ]; then
  # Test with bad token
  BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer invalid_token" "$API_BASE" 2>/dev/null || echo "000")
  if [ "$BAD_CODE" = "401" ] || [ "$BAD_CODE" = "403" ]; then
    check "Invalid token rejected with 401/403" "pass"
  else
    check "Invalid token rejected with 401/403" "fail"
  fi
else
  echo "⚠️  SKIP: Auth token not provided — skipping auth checks"
fi

# ─── 8. BOLA Test (if auth provided) ───
if [ -n "$AUTH_HEADER" ]; then
  # Try accessing /users/1 with a different user's token (if endpoint exists)
  BOLA_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "$AUTH" "$API_BASE/api/v1/users/99999999" 2>/dev/null || echo "000")
  if [ "$BOLA_CODE" = "404" ] || [ "$BOLA_CODE" = "403" ]; then
    check "BOLA: unauthorized resource returns 404/403" "pass"
  elif [ "$BOLA_CODE" = "200" ]; then
    check "BOLA: unauthorized resource returns 404/403" "fail"
  else
    echo "⚠️  SKIP: BOLA check — endpoint not available or different behavior"
  fi
fi

# ─── 9. Method Not Allowed ───
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$API_BASE" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "405" ]; then
  check "DELETE on root returns 405 Method Not Allowed" "pass"
else
  check "DELETE on root returns 405 Method Not Allowed" "fail"
fi

# ─── 10. Content-Type Validation ───
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: text/xml" -d "<xml></xml>" "$API_BASE" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "415" ] || [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "422" ]; then
  check "Unsupported Content-Type rejected" "pass"
else
  check "Unsupported Content-Type rejected" "fail"
fi

# ─── 11. Error Handling (No Stack Traces) ───
ERROR_BODY=$(curl -s -X POST -H "Content-Type: application/json" -d '{"email": "not-an-email"}' "$API_BASE" 2>/dev/null || echo "")
if echo "$ERROR_BODY" | grep -qi "stack\|trace\|exception\|sql\|query"; then
  check "Error response does not leak stack traces/DB details" "fail"
else
  check "Error response does not leak stack traces/DB details" "pass"
fi

echo ""
echo "========================"
echo "Results: $PASS/$TOTAL passed, $FAIL/$TOTAL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "🎉 All checks passed!"
  exit 0
else
  echo "⚠️  $FAIL checks failed. Review and fix before deploying."
  exit 1
fi
