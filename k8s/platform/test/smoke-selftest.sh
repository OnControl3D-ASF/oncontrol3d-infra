#!/usr/bin/env bash
# Offline test for smoke.sh: runs it against a stub edge (test/stub_edge.py).
#   good  stub -> smoke.sh must pass at both levels
#   leaky stub -> smoke.sh must FAIL (proves each check can actually detect a defect)
#   nothing listening -> smoke.sh must FAIL
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
smoke="$here/../smoke.sh"
work=$(mktemp -d)
stub_pid=""
cleanup() { [ -z "$stub_pid" ] || kill "$stub_pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null

run_smoke() { # level -> exit code, output in $work/out
  SMOKE_HTTP_BASE="http://localhost:$http_port" SMOKE_HTTPS_BASE="https://localhost:$https_port" \
    SMOKE_CACERT="$work/cert.pem" SMOKE_RATE_PAUSE=0 "$smoke" localhost "$1" >"$work/out" 2>&1
}
start_stub() {
  [ -z "$stub_pid" ] || { kill "$stub_pid" 2>/dev/null || true; wait "$stub_pid" 2>/dev/null || true; }
  : >"$work/ports"
  python3 -I "$here/stub_edge.py" "$1" "$work/cert.pem" "$work/key.pem" "$work/ports" &
  stub_pid=$!
  for _ in $(seq 50); do [ -s "$work/ports" ] && break; sleep 0.1; done
  read -r http_port https_port <"$work/ports"
}
fails=0
expect() { # description expected-exit actual-exit
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected exit $2, got $3)"; sed 's/^/       /' "$work/out"; fails=$((fails + 1)); fi
}

for level in platform full; do
  start_stub good # fresh stub per run: it counts requests to emulate the rate limits
  rc=0; run_smoke "$level" || rc=$?
  expect "good edge passes level $level" 0 "$rc"
done
start_stub good
rc=0; run_smoke bogus || rc=$?
expect "unknown level is rejected" 2 "$rc"

start_stub leaky
rc=0; run_smoke platform || rc=$?
expect "leaky edge fails level platform (no 308, no 429)" 1 "$rc"
start_stub leaky
rc=0; run_smoke full || rc=$?
expect "leaky edge fails level full" 1 "$rc"
for check in "check 3b" "check 3c" "check 3d" "check 8"; do
  if rg -q "FAIL.*$check" "$work/out"; then echo "ok   - leaky edge trips $check"; else echo "FAIL - leaky edge did not trip $check"; fails=$((fails + 1)); fi
done

http_port=1; https_port=1
rc=0; run_smoke platform || rc=$?
expect "nothing listening fails" 1 "$rc"

if [ "$fails" -ne 0 ]; then echo "smoke self-test: $fails failure(s)"; exit 1; fi
echo "smoke self-test: all good"
