const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {test} = require('node:test');
const {reportGatewayError} = require('../copilot-provider.cjs');

const fakeKey = 'synthetic-relay-key-not-a-real-credential';
const requestId = '12345678-1234-1234-1234-123456789abc';
const blocked = {error: {
  code: 'PII_DETECTED', categories: ['EMAIL', 'KOR_PHONE'], matchCount: 2,
  requestId, ruleVersion: 'test.1', message: 'private-value-not-for-diagnostics'
}};

test('diagnostics print only safe metadata and distinguish inspection outages from PII blocks', () => {
  const messages = [];
  assert.equal(reportGatewayError(403, JSON.stringify(blocked), message => messages.push(message)), true);
  assert.match(messages[0], /PII_DETECTED.*not an API key authentication failure/);
  assert.match(messages[0], /categories=EMAIL,KOR_PHONE; matchCount=2; requestId=/);
  assert.ok(!messages[0].includes(blocked.error.message));
  assert.equal(reportGatewayError(503, '{"error":{"code":"PII_INSPECTION_UNAVAILABLE"}}',
    message => messages.push(message)), true);
  assert.match(messages[1], /PII inspection unavailable/);
  for (const body of ['null', '{', '{"error":{"code":"other","message":"private"}}']) {
    assert.equal(reportGatewayError(403, body, () => assert.fail('must not print unknown responses')), false);
  }
  assert.equal(reportGatewayError(401, JSON.stringify(blocked),
    () => assert.fail('401 is not a PII rejection')), false);
  const unsafe = {error: {...blocked.error,
    categories: ['EMAIL\nprivate'], requestId: 'private', matchCount: 'private'}};
  reportGatewayError(403, JSON.stringify(unsafe), message => {
    assert.ok(!message.includes('private'));
    assert.ok(!message.includes('categories='));
  });
});

test('relay preserves requests, streaming responses and rejection status/body while printing live diagnostics', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-provider-test-'));
  const received = [];
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      received.push({url: request.url, key: request.headers['ocp-apim-subscription-key'],
        body: Buffer.concat(chunks).toString()});
      const status = Number(request.headers['x-test-status']);
      response.writeHead(status, {'Content-Type': status === 200 ? 'text/event-stream' : 'application/json',
        'x-test-preserved': 'yes'});
      if (status === 200) {
        response.write('data: first\n\n');
        setTimeout(() => response.end('data: [DONE]\n\n'), 50);
      } else {
        response.end(JSON.stringify(blocked));
      }
    });
  });
  try {
    fs.writeFileSync(path.join(root, 'copilot'), `#!${process.execPath}
const http = require('node:http');
const fs = require('node:fs');
const key = process.env.COPILOT_PROVIDER_API_KEY;
const body = '{"messages":[{"role":"user","content":"synthetic body"}]}';
const url = process.env.COPILOT_PROVIDER_BASE_URL + '/chat/completions';
const auth = process.env.TEST_UNAUTHORIZED ? 'wrong-key' : key;
const request = http.request(url, {method: 'POST', headers: {
  'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body),
  'Ocp-Apim-Subscription-Key': auth, 'x-test-status': process.env.TEST_STATUS
}}, response => {
  const chunks = [];
  response.on('data', chunk => chunks.push(chunk));
  response.on('end', () => {
    fs.writeFileSync(process.env.TEST_RESULT, JSON.stringify({
      status: response.statusCode, headers: response.headers,
      body: Buffer.concat(chunks).toString(), chunks: chunks.length
    }));
    if (process.env.TEST_WAIT) {
      setInterval(() => {}, 1000);
      console.log(process.env.COPILOT_PROVIDER_BASE_URL);
    }
    process.exitCode = Number(process.env.TEST_EXIT);
  });
});
request.on('error', () => process.exitCode = 70);
request.end(body);
`, {mode: 0o700});
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    for (const scenario of [
      {status: 200, exit: 0}, {status: 403, exit: 23}, {status: 401, exit: 24},
      {status: 403, exit: 25, unauthorized: true}, {status: 200, exit: 143, interrupt: true}
    ]) {
      const file = path.join(root, 'response.json');
      const result = await new Promise((resolve, reject) => {
        const child = spawn(process.execPath, [path.resolve(__dirname, '../copilot-provider.cjs')], {
          env: {...process.env, PATH: `${root}:${process.env.PATH}`,
            COPILOT_PROVIDER_BASE_URL: `http://127.0.0.1:${server.address().port}/self-hosted/openai`,
            COPILOT_PROVIDER_API_KEY: fakeKey, TEST_STATUS: String(scenario.status),
            TEST_RESULT: file, TEST_EXIT: String(scenario.exit),
            TEST_UNAUTHORIZED: scenario.unauthorized ? 'true' : '',
            TEST_WAIT: scenario.interrupt ? 'true' : ''},
          timeout: 10000
        });
        let stderr = '';
        child.stderr.on('data', chunk => { stderr += chunk; });
        child.stdout.once('data', () => {
          if (scenario.interrupt) child.kill('SIGTERM');
        });
        child.on('error', reject);
        child.on('close', (code, signal) => resolve({code, signal, stderr}));
      });
      assert.equal(result.code, scenario.exit, `${result.signal || ''} ${result.stderr}`);
      const response = JSON.parse(fs.readFileSync(file, 'utf8'));
      assert.equal(response.status, scenario.unauthorized ? 401 : scenario.status);
      assert.ok(!result.stderr.includes(fakeKey));
      assert.ok(!result.stderr.includes(blocked.error.message));
      if (scenario.status === 200) {
        assert.equal(response.body, 'data: first\n\ndata: [DONE]\n\n');
        assert.ok(response.chunks >= 2, 'successful responses must not be buffered');
      } else if (scenario.status === 403 && !scenario.unauthorized) {
        assert.match(result.stderr, /PII_DETECTED.*categories=EMAIL,KOR_PHONE/);
        assert.equal(response.body, JSON.stringify(blocked));
      } else {
        assert.equal(result.stderr, '');
      }
      if (!scenario.unauthorized) assert.equal(response.headers['x-test-preserved'], 'yes');
    }
    assert.equal(received.length, 4, 'unauthenticated loopback calls must not reach APIM');
    for (const request of received) {
      assert.equal(request.url, '/self-hosted/openai/chat/completions');
      assert.equal(request.key, fakeKey);
      assert.equal(request.body, '{"messages":[{"role":"user","content":"synthetic body"}]}');
    }
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, {recursive: true, force: true});
  }
});
