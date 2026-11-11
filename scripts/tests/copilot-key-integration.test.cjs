const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {spawn, spawnSync} = require('node:child_process');
const {test} = require('node:test');

const scripts = path.resolve(__dirname, '..');
const fakeKey = 'local-test-subscription-key-not-a-real-credential';

test('installed Copilot CLI sends the subscription header and consumes a completion', async t => {
  const root = fs.mkdtempSync(path.join(scripts, '.key-integration-'));
  const env = {
    PATH: [path.dirname(process.execPath), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin'].join(':'),
    HOME: root,
    XDG_CONFIG_HOME: path.join(root, 'config'),
    XDG_CACHE_HOME: path.join(root, 'cache'),
    COPILOT_OFFLINE: 'true'
  };
  const requests = [];
  const server = http.createServer((request, response) => {
    let body = '';
    request.setEncoding('utf8');
    request.on('data', chunk => { body += chunk; });
    request.on('end', () => {
      const key = request.headers['ocp-apim-subscription-key'];
      const valid = key === fakeKey;
      const status = valid ? 200 : 401;
      const parsed = JSON.parse(body);
      requests.push({
        path: request.url, status, model: parsed.model,
        hasHeader: Boolean(key), stream: parsed.stream
      });
      response.writeHead(status, {'Content-Type': 'application/json'});
      response.end(JSON.stringify(valid ? {
        id: 'chatcmpl-local-key-auth',
        object: 'chat.completion',
        created: Math.floor(Date.now() / 1000),
        model: 'gpt-5-mini',
        choices: [{
          index: 0,
          message: {role: 'assistant', content: 'APIM_KEY_AUTH_OK'},
          finish_reason: 'stop'
        }],
        usage: {prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
      } : {error: {message: 'Invalid subscription key', type: 'authentication_error'}}));
    });
  });
  try {
    const version = spawnSync('copilot', ['--version'], {env, cwd: root, encoding: 'utf8'});
    if (version.error?.code === 'ENOENT') {
      t.skip('Copilot CLI is not installed.');
      return;
    }
    assert.ifError(version.error);
    assert.equal(version.status, 0, version.stderr);
    fs.mkdirSync(path.join(root, 'scripts'));
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const port = server.address().port;
    const result = await new Promise((resolve, reject) => {
      const child = spawn('/bin/bash', ['-c', `
set +x
set -euo pipefail
source "$COMMON_SCRIPT"
ROOT_DIR="$HOME"
trap cleanup_apim_session EXIT
configure_apim_copilot
verify_apim_key_auth
cleanup_apim_session
APIM_KEY="$TEST_KEY"
configure_apim_copilot
exec copilot --no-auto-update --disable-client-telemetry --disable-builtin-mcps \\
  --trust-folder --available-tools --silent --stream off \\
  --secret-env-vars APIM_KEY,COPILOT_PROVIDER_API_KEY,COPILOT_PROVIDER_HEADERS \\
  -p "Return the local test marker without calling tools."
`], {
        cwd: root,
        env: {
          ...env,
          COMMON_SCRIPT: path.join(scripts, 'common.sh'),
          APIM_KEY: fakeKey,
          TEST_KEY: fakeKey,
          APIM_GATEWAY_URL: `http://127.0.0.1:${port}`,
          OPENAI_MODEL_NAME: 'gpt-5-mini',
          OPENAI_DEPLOYMENT_NAME: 'local-deployment'
        },
        timeout: 90000
      });
      let stdout = '';
      let stderr = '';
      child.stdout.on('data', chunk => { stdout += chunk; });
      child.stderr.on('data', chunk => { stderr += chunk; });
      child.once('error', reject);
      child.once('close', (status, signal) => resolve({status, signal, stdout, stderr}));
    });
    assert.ok(!result.stdout.includes(fakeKey), 'stdout must not contain the key');
    assert.ok(!result.stderr.includes(fakeKey), 'stderr must not contain the key');
    assert.equal(result.status, 0, `${result.signal || ''}\n${result.stderr}\n${result.stdout}`);
    assert.match(result.stdout, /APIM_KEY_AUTH_OK/);
    assert.match(result.stdout, /API_KEY_CHECK missing = HTTP 401/);
    assert.match(result.stdout, /API_KEY_CHECK invalid = HTTP 401/);
    assert.match(result.stdout, /API_KEY_CHECK valid\s+= HTTP 200/);
    assert.deepEqual(requests.slice(0, 3).map(request => request.status), [401, 401, 200]);
    assert.equal(requests[0].hasHeader, false);
    assert.ok(requests.length >= 4, 'the real CLI must make its own model request');
    for (const request of requests.slice(3)) {
      assert.equal(request.status, 200);
      assert.equal(request.path, '/openai/chat/completions');
      assert.equal(request.model, 'local-deployment');
      assert.ok(request.stream === undefined || request.stream === false,
        'omitted or false stream must request a non-streaming completion');
    }
    t.diagnostic(`CLI ${version.stdout.trim()}: loopback 401/401/200 and CLI completion verified`);
  } finally {
    server.closeAllConnections();
    if (server.listening) await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, {recursive: true, force: true});
  }
});
