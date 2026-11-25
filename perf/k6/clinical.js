// Performance tests (report section 4.4.3) for the clinical microservice through the public edge.
//
// It logs in ONCE in setup() (the edge limits /api/auth to 20/min per IP and auth to 5/min per pod) and then
// every virtual user replays a doctor's dashboard flow with that token. /api/* has no edge rate limit, so
// the load reaches clinical and drives its HPA (CPU target 70% of a 250m request).
//
// Usage:
//   OC3D_PASSWORD='<seed password>' k6 run -e TEST_TYPE=load   perf/k6/clinical.js
//   OC3D_PASSWORD='<seed password>' k6 run -e TEST_TYPE=stress perf/k6/clinical.js
// Optional: -e BASE_URL=https://... -e OC3D_EMAIL=dr.rodriguez@hospital.com -e TEST_TYPE=smoke
import http from 'k6/http';
import { check, group, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://oc3d-asf-dev.brazilsouth.cloudapp.azure.com';
const EMAIL = __ENV.OC3D_EMAIL || 'dr.garcia@hospital.com';
const TEST_TYPE = __ENV.TEST_TYPE || 'smoke';

const PROFILES = {
  // 1 user, 30 s: checks the script and the credentials before a real run.
  smoke: {
    stages: [{ duration: '30s', target: 1 }],
    thresholds: {
      http_req_failed: ['rate<0.01'],
      checks: ['rate>0.99'],
    },
  },
  // Expected peak: 20 concurrent doctors for 4 minutes. Pass/fail criteria = the SLO for the report.
  load: {
    stages: [
      { duration: '1m', target: 20 },
      { duration: '4m', target: 20 },
      { duration: '1m', target: 0 },
    ],
    thresholds: {
      http_req_failed: ['rate<0.01'],
      http_req_duration: ['p(95)<800'],
      checks: ['rate>0.99'],
    },
  },
  // Steps above the expected peak to find where latency and errors degrade and how far the HPA carries it.
  stress: {
    stages: [
      { duration: '1m', target: 20 },
      { duration: '2m', target: 20 },
      { duration: '1m', target: 50 },
      { duration: '2m', target: 50 },
      { duration: '1m', target: 100 },
      { duration: '2m', target: 100 },
      { duration: '1m', target: 0 },
    ],
    // Informative only: a stress test is expected to cross them; the summary shows where.
    thresholds: {
      http_req_failed: ['rate<0.05'],
      http_req_duration: ['p(95)<2000'],
    },
  },
};

const profile = PROFILES[TEST_TYPE];
if (!profile) {
  throw new Error(`TEST_TYPE must be one of ${Object.keys(PROFILES).join(', ')}; got '${TEST_TYPE}'`);
}

export const options = {
  stages: profile.stages,
  thresholds: profile.thresholds,
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  tags: { test_type: TEST_TYPE },
};

export function setup() {
  const password = __ENV.OC3D_PASSWORD;
  if (!password) {
    throw new Error('Set OC3D_PASSWORD (the seed user password) in the environment');
  }
  const res = http.post(`${BASE_URL}/api/auth/login`, JSON.stringify({ email: EMAIL, password }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'login' },
  });
  if (res.status !== 200) {
    throw new Error(`login failed: HTTP ${res.status} (429 = edge rate limit, wait 1 minute)`);
  }
  const body = res.json();
  if (!body.token || !body.doctorProfileId) {
    throw new Error(`login response has no token or doctorProfileId (role=${body.role})`);
  }
  return { token: body.token, doctorId: body.doctorProfileId };
}

export default function (data) {
  const params = { headers: { Authorization: `Bearer ${data.token}` } };
  const doctor = `${BASE_URL}/api`;

  group('doctor dashboard', () => {
    // `name` groups URLs with ids into one metric per endpoint.
    const responses = http.batch([
      ['GET', `${doctor}/dashboard/doctor/${data.doctorId}/stats`, null, { ...params, tags: { name: 'dashboard-stats' } }],
      ['GET', `${doctor}/reports/doctor/${data.doctorId}/overview`, null, { ...params, tags: { name: 'reports-overview' } }],
      ['GET', `${doctor}/appointments/doctor/${data.doctorId}`, null, { ...params, tags: { name: 'appointments' } }],
      ['GET', `${doctor}/medications/doctor/${data.doctorId}`, null, { ...params, tags: { name: 'medications' } }],
    ]);
    for (const res of responses) {
      check(res, {
        'status 200': (r) => r.status === 200,
        'is JSON': (r) => (r.headers['Content-Type'] || '').includes('application/json'),
      });
    }
  });

  // Think time: a doctor reads the dashboard before the next action.
  sleep(1);
}

export function handleSummary(data) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const file = `perf/k6/results/${TEST_TYPE}-${stamp}.json`;
  return {
    [file]: JSON.stringify(data, null, 2),
    stdout: textSummary(data),
  };
}

// Compact text summary (k6's built-in summary is replaced once handleSummary exists).
function textSummary(data) {
  const m = data.metrics;
  // A metric is absent when nothing recorded it (e.g. setup() failed before any VU ran): print "-".
  const val = (metric, key) => (m[metric] && m[metric].values ? m[metric].values[key] : undefined);
  const ms = (v) => (v === undefined ? '-' : `${v.toFixed(0)} ms`);
  const num = (v, digits = 0) => (v === undefined ? '-' : v.toFixed(digits));
  const failed = val('http_req_failed', 'rate');
  const lines = [
    `\n=== k6 ${TEST_TYPE} — ${BASE_URL} ===`,
    `requests:        ${num(val('http_reqs', 'count'))} (${num(val('http_reqs', 'rate'), 1)} req/s)`,
    `failed:          ${failed === undefined ? '-' : (failed * 100).toFixed(2)} %`,
    `latency avg/med: ${ms(val('http_req_duration', 'avg'))} / ${ms(val('http_req_duration', 'med'))}`,
    `latency p95/p99: ${ms(val('http_req_duration', 'p(95)'))} / ${ms(val('http_req_duration', 'p(99)'))}`,
    `latency max:     ${ms(val('http_req_duration', 'max'))}`,
    `max VUs:         ${num(val('vus_max', 'max'))}`,
    'thresholds:',
  ];
  for (const [name, metric] of Object.entries(m)) {
    for (const [rule, result] of Object.entries(metric.thresholds || {})) {
      lines.push(`  ${result.ok ? 'PASS' : 'FAIL'}  ${name} ${rule}`);
    }
  }
  return `${lines.join('\n')}\n`;
}
