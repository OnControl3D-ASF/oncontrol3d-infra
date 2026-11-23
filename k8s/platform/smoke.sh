#!/usr/bin/env bash
# Smoke test of the public edge.   Usage: smoke.sh <host> [platform|full]
#
#   platform  edge + Orthanc only (works before any application is deployed):
#               1 HTTP->HTTPS 301/308   2 valid TLS chain (no -k)   6 /volview/ served   7 /volview rate limit
#   full      platform + routing of the application workloads (needs auth, clinical, imaging, frontend):
#               3a login served by auth   3b clinical's legacy register is NOT public   3c /internal never routed
#               3d login rate limit   4 imaging derived allowlist   5 imaging non-allowlisted paths   8 Orthanc not public
#   9 (default-deny NetworkPolicy) is skipped until T2-7 and is not part of either level.
#
# Rate-limit checks run last because they exhaust the per-IP buckets of this machine.
# SMOKE_STAGING_CERT=1: the Certificate still comes from Let's Encrypt STAGING (not publicly trusted). Check 2 is skipped
# and verification is relaxed for the other checks. Never set it once the production issuer is active.
# Test hooks (used by test/smoke-selftest.sh): SMOKE_HTTP_BASE, SMOKE_HTTPS_BASE, SMOKE_CACERT, SMOKE_RATE_PAUSE.
set -uo pipefail

host=${1:?usage: smoke.sh <host> [platform|full]}
level=${2:-platform}
case "$level" in platform | full) ;; *) echo "unknown level '$level' (platform|full)" >&2; exit 2 ;; esac

http_base=${SMOKE_HTTP_BASE:-http://$host}
https_base=${SMOKE_HTTPS_BASE:-https://$host}
cacert=${SMOKE_CACERT:-}
staging=${SMOKE_STAGING_CERT:-0}
insecure=()
[ "$staging" = 1 ] && insecure=(-k)
rate_pause=${SMOKE_RATE_PAUSE:-6}
zero_id=00000000-00000000-00000000-00000000-00000000

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

c() { curl -sS --max-time 30 ${cacert:+--cacert "$cacert"} "${insecure[@]}" "$@"; }
pass() { echo "PASS check $1: $2"; }
fail() { echo "FAIL check $1: $2"; failures=$((failures + 1)); }

# req METHOD URL [data] -> sets CODE and BODY ("000" when the connection or TLS handshake fails)
req() {
  local method=$1 url=$2 data=${3:-}
  CODE=$(c -o "$work/body" -w '%{http_code}' -X "$method" ${data:+-H 'Content-Type: application/json' --data "$data"} "$url" 2>"$work/err") || CODE=000
  BODY=$(head -c 300 "$work/body" 2>/dev/null || true)
}
is_json() { [[ $BODY == "{"* || $BODY == "["* ]]; }

check_http_redirect() {
  # Traefik v3 permanent entryPoint redirect: GET/HEAD -> 301, other methods -> 308 (method-preserving).
  local loc post ploc
  CODE=$(c -o /dev/null -w '%{http_code} %{redirect_url}' "$http_base/" 2>/dev/null) || CODE="000 "
  loc=${CODE#* }
  post=$(c -o /dev/null -X POST -w '%{http_code} %{redirect_url}' "$http_base/" 2>/dev/null) || post="000 "
  ploc=${post#* }
  if [[ ${CODE%% *} =~ ^(301|308)$ && $loc == https://* && ${post%% *} = 308 && $ploc == https://* ]]; then
    pass 1 "HTTP -> GET ${CODE%% *} / POST 308 $loc"
  else
    fail 1 "expected GET 301|308 and POST 308 to https://, got GET '$CODE' POST '$post'"
  fi
}

check_tls() {
  if [ "$staging" = 1 ]; then echo "SKIP check 2: staging certificate (SMOKE_STAGING_CERT=1), chain not verified"; return; fi
  # Any HTTP status is fine (Traefik answers 503 while a backend is missing); what matters is that
  # curl completed the handshake with certificate verification ON.
  local rc=0
  CODE=$(c -o /dev/null -w '%{http_code}' "$https_base/" 2>"$work/err") || rc=$?
  if [ "$rc" -eq 0 ] && [ "$CODE" != 000 ]; then pass 2 "TLS chain valid (HTTP $CODE)"; else fail 2 "TLS verification failed (curl exit $rc): $(head -c 200 "$work/err")"; fi
}

check_volview() {
  req GET "$https_base/volview/index.html"
  if [ "$CODE" = 200 ]; then pass 6 "/volview/index.html 200"; else fail 6 "expected 200, got $CODE"; fi
}

check_volview_rate_limit() {
  # rl-volview is 30/s with burst 100: a burst above 100 requests must produce 429s. Each curl opens a new TLS
  # connection (~300-400 ms from Peru to brazilsouth), so 25 in parallel stayed under 30/s + burst: 60 do not.
  local n
  n=$(seq 300 | xargs -P 60 -I{} curl -s --max-time 15 -o /dev/null -w '%{http_code}\n' ${cacert:+--cacert "$cacert"} "${insecure[@]}" "$https_base/volview/index.html" | grep -Ec '^429$' || true)
  if [ "${n:-0}" -ge 1 ]; then pass 7 "300 GETs /volview/ -> $n x 429"; else fail 7 "no 429 in 300 rapid GETs to /volview/"; fi
}

check_login_served_by_auth() {
  req POST "$https_base/api/auth/login" '{"email":"smoke@invalid.example","password":"wrong-password"}'
  if [ "$CODE" = 401 ] && is_json; then pass 3a "login with bad credentials -> 401 JSON"; else fail 3a "expected 401 JSON, got $CODE '$BODY'"; fi
}

check_register_not_clinical() {
  # clinical's legacy iam would answer 400 here; auth has no such route -> 404.
  req POST "$https_base/api/auth/register/organization" '{}'
  if [ "$CODE" = 404 ]; then pass 3b "register/organization -> 404 (served by auth)"; else fail 3b "expected 404, got $CODE '$BODY'"; fi
}

check_internal_unrouted() {
  local p bad=0
  for p in /internal/accounts /api/auth/internal/accounts; do
    req GET "$https_base$p"
    [ "$CODE" = 404 ] || { fail 3c "GET $p -> $CODE (expected 404)"; bad=1; }
  done
  [ "$bad" -eq 0 ] && pass 3c "/internal/accounts and /api/auth/internal/accounts -> 404"
}

check_login_rate_limit() {
  local i got=0
  for i in $(seq 25); do
    req POST "$https_base/api/auth/login" '{"email":"smoke@invalid.example","password":"wrong-password"}'
    [ "$CODE" = 429 ] && { got=1; break; }
  done
  if [ "$got" -eq 1 ]; then pass 3d "rapid bad logins -> 429 after $i attempts"; else fail 3d "no 429 in 25 rapid bad logins"; fi
}

check_imaging_derived() {
  # Proves the allowlisted path reaches imaging (JSON with FastAPI's "detail", not the frontend's HTML).
  # Imaging answers 409 for a study without DICOMs (precondition: /segment-lungs first), 404 in older versions.
  req GET "$https_base/imaging/studies/$zero_id/derived/lung-surface"
  if [[ $CODE =~ ^(404|409)$ ]] && is_json && [[ $BODY == *'"detail"'* ]]; then
    pass 4 "derived/lung-surface zero id -> imaging JSON $CODE"
  else
    fail 4 "expected imaging JSON 404|409 with detail, got $CODE '$BODY'"
  fi
}

check_imaging_not_exposed() {
  local label url method bad=0
  while IFS='|' read -r label method url; do
    req "$method" "$https_base$url"
    if [ "$CODE" = 404 ] || [ "$CODE" = 405 ]; then
      is_json && { fail 5 "$label reached a JSON backend ($CODE '$BODY')"; bad=1; }
    else
      fail 5 "$label -> $CODE (expected 404/405 from the frontend)"; bad=1
    fi
  done <<EOT
segment-lungs|POST|/imaging/studies/$zero_id/segment-lungs
orthanc proxy|GET|/imaging/orthanc/system
name outside allowlist|GET|/imaging/studies/$zero_id/derived/other-name
non-GET on derived|POST|/imaging/studies/$zero_id/derived/lung-surface
EOT
  [ "$bad" -eq 0 ] && pass 5 "non-allowlisted imaging paths fall through to the frontend"
}

check_orthanc_not_public() {
  local p bad=0
  for p in /studies /app/explorer.html; do
    req GET "$https_base$p"
    { [ "$CODE" = 404 ] && ! is_json; } || { fail 8 "GET $p -> $CODE '$BODY' (Orthanc must not be public)"; bad=1; }
  done
  [ "$bad" -eq 0 ] && pass 8 "/studies and /app/explorer.html are not Orthanc"
}

echo "smoke: host=$host level=$level"
check_http_redirect
check_tls
check_volview
if [ "$level" = full ]; then
  check_login_served_by_auth
  check_register_not_clinical
  check_internal_unrouted
  check_imaging_derived
  check_imaging_not_exposed
  check_orthanc_not_public
fi
# Rate-limit checks last (they exhaust this IP's buckets); wait for the buckets to refill in between.
check_volview_rate_limit
if [ "$level" = full ]; then
  sleep "$rate_pause"
  check_login_rate_limit
  echo "note: this IP is now rate-limited on /api/auth/login for ~1 minute"
fi
echo "check 9 (default-deny NetworkPolicy): SKIPPED until T2-7"

if [ "$failures" -gt 0 ]; then echo "smoke: $failures check(s) FAILED"; exit 1; fi
echo "smoke: all checks passed ($level)"
