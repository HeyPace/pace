import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { onRequest } from '../functions/_middleware.ts';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));
const origin = 'https://heypace.app';
const requests = [];
const assets = {
  async fetch(request) {
    requests.push(request);
    const path = new URL(request.url).pathname;
    const files =
      path === '/' ? ['index.html'] : [path.slice(1), `${path.slice(1)}/index.html`, ...(path === '/api/ai' ? ['api-ai.json'] : [])];
    for (const file of files) {
      try {
        const body = await readFile(`${dist}${file}`);
        const type = file.endsWith('.md')
          ? 'text/markdown'
          : file.endsWith('.html')
            ? 'text/html'
            : file.startsWith('api/')
              ? 'application/json'
              : 'text/plain';
        return new Response(request.method === 'HEAD' ? null : body, {
          headers: { 'Content-Type': type },
        });
      } catch (error) {
        if (!['ENOENT', 'EISDIR'].includes(error.code)) throw error;
      }
    }
    return new Response('<h1>Not found</h1>', {
      status: 404,
      headers: { 'Content-Type': 'text/html' },
    });
  },
};
async function request(path, options = {}) {
  const req = new Request(origin + path, options);
  return onRequest({
    request: req,
    env: { ASSETS: assets },
    next: () => assets.fetch(req),
  });
}
const body = await (await request('/pricing.md')).text();
for (const [path, headers] of [
  ['/pricing.md', {}],
  ['/api/md/pricing', {}],
  ['/pricing', { Accept: 'text/markdown' }],
]) {
  const response = await request(path, { headers });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('Content-Type'), /text\/markdown/);
  assert.equal(response.headers.get('Content-Location'), `${origin}/pricing/`);
  assert.equal(response.headers.get('X-Robots-Tag'), 'noindex, follow');
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
  assert.equal(
    Number(response.headers.get('X-Markdown-Tokens')),
    Math.ceil(body.length / 4)
  );
  assert.equal(await response.text(), body);
  const head = await request(path, { method: 'HEAD', headers });
  assert.equal(head.body, null);
  assert.equal(
    head.headers.get('Content-Type'),
    response.headers.get('Content-Type')
  );
}
for (const accept of [
  '',
  '*/*',
  'text/markdown;q=0',
  'text/markdown;q=0.5,text/html;q=1',
  'text/markdown,text/html',
]) {
  const response = await request('/pricing', { headers: { Accept: accept } });
  assert.match(response.headers.get('Content-Type'), /text\/html/);
  assert.match(response.headers.get('Link'), /llms-full.txt/);
}
for (const path of [
  '/missing.md',
  '/api/md/admin',
  '/api/md/dashboard',
  '/api/md/not-published',
]) {
  const response = await request(path);
  assert.equal(response.status, 404);
  assert.match(response.headers.get('Content-Type'), /text\/markdown/);
}
assert.equal(
  (await request('/api/md/pricing', { method: 'OPTIONS' })).status,
  204
);
await request('/pricing?preview=secret', {
  headers: {
    Accept: 'text/markdown',
    Cookie: 'session=fixture',
    Authorization: 'Bearer fixture',
  },
});
assert.ok(
  requests.every(
    (req) =>
      !req.headers.has('Cookie') &&
      !req.headers.has('Authorization') &&
      !new URL(req.url).search
  )
);
for (const path of [
  '/llms.txt',
  '/llms-full.txt',
  '/ai.txt',
  '/api/md/_catalog',
])
  assert.equal((await request(path)).status, 200);
console.log(
  'PASS actual Pages middleware with emitted assets: suffix/direct/negotiation, quality, HEAD/CORS, private misses, credential stripping, discovery.'
);
