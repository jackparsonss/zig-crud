import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.BASE_URL || 'http://127.0.0.1:8080';
const profile = __ENV.PROFILE || 'scaled';
let noteId = null;
let phase = 'create';

export const options = {
  discardResponseBodies: false,
  // The server intentionally releases a worker after each request, so every
  // request gets a new connection instead of pinning a worker to an idle VU.
  noConnectionReuse: true,
  scenarios: {
    mixed_crud: {
      executor: 'ramping-vus',
      startVUs: 0,
      gracefulRampDown: '30s',
      stages: [
        { duration: '30s', target: 1000 },
        { duration: '90s', target: 10000 },
        { duration: '2m', target: 10000 },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: profile === 'scaled'
    ? {
        http_req_failed: ['rate<0.01'],
        http_req_duration: ['p(95)<250'],
      }
    : {},
};

function createNote() {
  const response = http.post(`${baseUrl}/notes`, `note-${__VU}-${__ITER}`, {
    headers: { 'Content-Type': 'text/plain' },
    tags: { name: 'create_note' },
  });
  check(response, {
    'create returns 201 and an id': (result) => {
      if (result.status !== 201) return false;
      try {
        noteId = JSON.parse(result.body).id;
        phase = 'read_before_update';
        return Number.isInteger(noteId);
      } catch (_) {
        return false;
      }
    },
  });
}

export default function () {
  if (phase === 'create') {
    createNote();
  } else if (phase === 'read_before_update' || phase === 'read_after_update') {
    const response = http.get(`${baseUrl}/notes/${noteId}`, { tags: { name: 'get_note' } });
    check(response, { 'note read returns 200': (result) => result.status === 200 });
    phase = phase === 'read_before_update' ? 'update' : 'delete';
  } else if (phase === 'update') {
    const response = http.put(`${baseUrl}/notes/${noteId}`, `updated-${__VU}-${__ITER}`, {
      headers: { 'Content-Type': 'text/plain' },
      tags: { name: 'update_note' },
    });
    check(response, { 'note update returns 200': (result) => result.status === 200 });
    phase = 'read_after_update';
  } else {
    const response = http.del(`${baseUrl}/notes/${noteId}`, null, { tags: { name: 'delete_note' } });
    check(response, { 'note deletion returns 200': (result) => result.status === 200 });
    if (response.status === 200) {
      noteId = null;
      phase = 'create';
    }
  }

  // One request per virtual user per second makes 10,000 VUs approximately
  // a 10,000-request-per-second workload instead of a client CPU benchmark.
  sleep(1);
}
