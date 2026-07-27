const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  distributionSource,
  getOrCreateInstallationId,
  postJson,
  reportSuccessfulInstall,
  reportingDisabled,
} = require('../telemetry');

test('distinguishes npm packages from GitHub checkouts', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vibing-source-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  assert.equal(distributionSource(root), 'github');
  fs.writeFileSync(
    path.join(root, 'distribution.json'),
    JSON.stringify({ source: 'npm' }),
  );
  assert.equal(distributionSource(root), 'npm');
});

test('reuses one anonymous installation id', (t) => {
  const configRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), 'vibing-config-'),
  );
  t.after(() => fs.rmSync(configRoot, { recursive: true, force: true }));

  const env = { XDG_CONFIG_HOME: configRoot };
  const first = getOrCreateInstallationId(env);
  const second = getOrCreateInstallationId(env);

  assert.equal(first, second);
  assert.match(first, /^[0-9a-f-]{36}$/i);
});

test('allows telemetry to be disabled', () => {
  assert.equal(reportingDisabled({ VIBING_SUPPLY_TELEMETRY: '0' }), true);
  assert.equal(reportingDisabled({ VIBING_SUPPLY_TELEMETRY: 'off' }), true);
  assert.equal(reportingDisabled({}), false);
});

test('treats an unusable endpoint as a skipped report', async () => {
  const ok = await postJson('ftp://example.com/install', {
    version: '0.1.5',
  });
  assert.equal(ok, false);
});

test('reports a successful install without machine details', async (t) => {
  const packageRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), 'vibing-package-'),
  );
  const configRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), 'vibing-config-'),
  );
  t.after(() => fs.rmSync(packageRoot, { recursive: true, force: true }));
  t.after(() => fs.rmSync(configRoot, { recursive: true, force: true }));

  let received;
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      received = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      response.writeHead(202);
      response.end();
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());

  const address = server.address();
  const endpoint = `http://127.0.0.1:${address.port}/api/install`;
  const ok = await reportSuccessfulInstall({
    packageRoot,
    version: '0.1.5',
    endpoint,
    env: { XDG_CONFIG_HOME: configRoot },
  });

  assert.equal(ok, true);
  assert.deepEqual(Object.keys(received).sort(), [
    'eventId',
    'installationId',
    'source',
    'version',
  ]);
  assert.equal(received.source, 'github');
  assert.equal(received.version, '0.1.5');
});
