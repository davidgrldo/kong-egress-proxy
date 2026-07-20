#!/usr/bin/env bash
# e2e harness: Kong 3.9 DB-less + Squid + echo backend (docker compose).
# Proves traffic actually crosses the forward proxy by asserting on
# squid's access log, not just on end-to-end success. Requires docker + jq.
#
#   ./run.sh          run everything, tear down after
#   KEEP=1 ./run.sh   leave the stack running for inspection
set -u
cd "$(dirname "$0")"

PROXY=http://localhost:18100
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "ok    $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

# assert_json <name> <jq filter> <expected> -- <curl args...>
assert_json() {
  local name=$1 filter=$2 expected=$3
  shift 4
  local body actual
  body=$(curl -s "$@")
  actual=$(jq -r "$filter" <<<"$body" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    ok "$name"
  else
    fail "$name (expected '$expected', got '$actual')"
  fi
}

# assert_status <name> <expected> -- <curl args...>
assert_status() {
  local name=$1 expected=$2
  shift 3
  local actual
  actual=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [ "$actual" = "$expected" ]; then
    ok "$name"
  else
    fail "$name (expected HTTP $expected, got $actual)"
  fi
}

squid_log() { docker compose exec -T squid cat /var/log/squid/access.log 2>/dev/null; }

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v docker >/dev/null || { echo "docker is required"; exit 1; }

docker compose up -d --quiet-pull 2>&1 | grep -v '^\s*$' || true

cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    docker compose down -v >/dev/null 2>&1
  else
    echo "(KEEP=1: stack left running; docker compose down -v to stop)"
  fi
}
trap cleanup EXIT

printf 'waiting for kong'
up=0
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/direct/ping" 2>/dev/null || true)
  if [ "$code" = "200" ]; then up=1; break; fi
  printf .; sleep 1
done
echo
if [ "$up" != "1" ]; then
  echo "kong never became ready; logs:"
  docker compose logs --tail 60 kong
  exit 1
fi

# --- baseline -----------------------------------------------------------------
assert_json "baseline route reaches the echo backend directly" \
  '.path' /direct/ping -- "$PROXY/direct/ping"

# --- through the proxy ----------------------------------------------------------
VIA=("$PROXY/via/orders?a=1")
assert_json "proxied route reaches the origin" '.path' /via/orders -- "${VIA[@]}"
assert_json "query string survives the absolute-form rewrite" \
  '.query.a' 1 -- "${VIA[@]}"
assert_json "origin sees the origin Host, not the proxy" \
  '.headers.host' echo.internal:8080 -- "${VIA[@]}"

# The proof: squid saw the request in absolute form for the origin.
if squid_log | grep -q "http://echo.internal.*/via/orders"; then
  ok "squid access log records the proxied request"
else
  fail "squid access log records the proxied request (no matching line)"
fi

# --- proxy credentials ----------------------------------------------------------
assert_json "proxy credentials are consumed by the proxy hop" \
  '.headers."proxy-authorization" // "absent"' absent -- "$PROXY/auth/ping"
assert_json "authenticated route still reaches the origin" \
  '.path' /auth/ping -- "$PROXY/auth/ping"

# --- https handling -------------------------------------------------------------
assert_status "https upstream is rejected by default (no CONNECT)" 503 -- \
  "$PROXY/https-reject/x"
assert_json "on_https=bypass goes direct with TLS to the origin" \
  '.connection.servername' echo.internal -- "$PROXY/https-bypass/ping"
if squid_log | grep -q "https-bypass"; then
  fail "bypassed https traffic never touches squid (found in log)"
else
  ok "bypassed https traffic never touches squid"
fi

# --------------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "--- kong logs (tail) ---"
  docker compose logs --tail 40 kong
  echo "--- squid access log ---"
  squid_log | tail -20
  exit 1
fi
