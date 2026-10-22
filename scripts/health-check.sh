#!/usr/bin/env bash
#
# health-check.sh — verify the public frontend and the API are reachable.
#
#   ./scripts/health-check.sh
#   BASE_URL=http://54.81.38.205 ./scripts/health-check.sh
#
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1}"
TIMEOUT="${TIMEOUT:-10}"
FAILED=0
HEALTH_BODY="$(mktemp)"
trap 'rm -f "$HEALTH_BODY"' EXIT

check() {
  local name="$1" url="$2" expected="${3:-200}" body_file="${4:-}"
  local code
  if [[ -n "$body_file" ]]; then
    code="$(curl -s -o "$body_file" -w '%{http_code}' --max-time "$TIMEOUT" "$url" || true)"
  else
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$url" || true)"
  fi
  if [[ "$code" == "$expected" ]]; then
    printf '  [ OK ] %-12s %s -> %s\n' "$name" "$url" "$code"
  else
    printf '  [FAIL] %-12s %s -> %s (expected %s)\n' "$name" "$url" "${code:-no-response}" "$expected"
    FAILED=1
  fi
}

echo "Health check against $BASE_URL"
check "frontend"   "$BASE_URL/"           200
check "api-health" "$BASE_URL/api/health" 200 "$HEALTH_BODY"
check "api-list"   "$BASE_URL/api/products" 200

echo
echo "API health payload:"
cat "$HEALTH_BODY" 2>/dev/null || true
echo

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more checks FAILED"
  exit 1
fi

echo "All checks passed"
