const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {test} = require('node:test');

const scripts = path.resolve(__dirname, '..');
const apiKey = 'fake-apim-subscription-key-not-a-real-credential';
const apimId = '/subscriptions/test-sub/resourceGroups/actual-rg/providers/Microsoft.ApiManagement/service/test-apim';

function run(t, {scenario = {}, args = []} = {}) {
  const root = fs.mkdtempSync(path.join(scripts, '.cli-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const bin = path.join(root, 'bin');
  const copiedScripts = path.join(root, 'scripts');
  for (const dir of [bin, copiedScripts]) {
    fs.mkdirSync(dir, {recursive: true});
  }
  for (const name of ['common.sh', '3_copilot_cli.sh']) {
    fs.copyFileSync(path.join(scripts, name), path.join(copiedScripts, name));
  }
  fs.writeFileSync(path.join(root, '.env'), [
    'AZURE_SUBSCRIPTION_ID=test-sub',
    'APIM_SUBSCRIPTION_ID=copilot-cli', 'APIM_NAME=test-apim', 'RESOURCE_GROUP_NAME=wrong-rg',
    'OPENAI_ACCOUNT_NAME=test-openai', 'OPENAI_DEPLOYMENT_NAME=deployed-model',
    'OPENAI_MODEL_NAME=stale-configured-model', 'APIM_GATEWAY_URL=https://stale.example.invalid',
    ...(scenario.customNames ? [
      'SELF_HOSTED_GATEWAY_APP_NAME=custom-app',
      'SELF_HOSTED_GATEWAY_NAME=custom-gateway'
    ] : [])
  ].join('\n') + '\n');
  const log = path.join(root, 'calls.jsonl');
  const mock = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const scenario = ${JSON.stringify(scenario)};
const option = key => args[args.indexOf(key) + 1];
const call = {tool: path.basename(process.argv[1]), args};
if (call.tool === 'copilot' && !['--version', 'help'].includes(args[0])) {
  call.env = Object.fromEntries(Object.entries(process.env)
    .filter(([key]) => key.startsWith('COPILOT_')));
}
if (call.tool === 'curl') call.config = fs.readFileSync(0, 'utf8');
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(call) + '\\n');
if (call.tool === 'copilot') {
  if (args[0] === '--version') console.log('1.0.87-test');
  else if (args[0] === 'help') console.log(scenario.oldCli ? 'old CLI help' : 'COPILOT_PROVIDER_HEADERS');
  else process.exit(scenario.cliExit || 0);
} else if (call.tool === 'curl') {
  if (args.includes('--write-out')) {
    const config = call.config;
    const valid = config.includes(${JSON.stringify(apiKey)});
    fs.writeFileSync(option('--output'), JSON.stringify(
      scenario.badResponse ? {error: 'unexpected response'} :
        {choices: [{message: {role: 'assistant', content: 'OK'}}], usage: {total_tokens: 3}}
    ));
    process.stdout.write(scenario.badStatus ? '200' : valid ? '200' : '401');
  }
} else if (args[0] === 'apim') {
  console.log(scenario.missingApim ? '' : ${JSON.stringify(apimId)});
} else if (args[0] === 'rest') {
  const uri = option('--uri');
  if (uri.includes('/gateways/')) {
    if (option('--method') !== 'HEAD') {
      console.error("Method Not Allowed: gateway API association does not support " + option('--method'));
      process.exit(17);
    }
    if (scenario.missingGateway) {
      console.error('Gateway API association was not found.');
      process.exit(4);
    }
  } else if (uri.includes('/listSecrets')) {
    if (scenario.keyError) {
      console.error('Subscription key retrieval failed.');
      process.exit(17);
    }
    console.log(scenario.emptyKey ? '' : ${JSON.stringify(apiKey)});
  } else if (uri.includes('/subscriptions/copilot-cli?')) {
    console.log(scenario.suspended ? 'suspended' : 'active');
  }
} else if (args[0] === 'containerapp') {
  if (!args.includes('--only-show-errors')) console.error('WARNING: containerapp extension override');
  if (scenario.appLookupError) {
    console.error('Container App lookup failed.');
    process.exit(17);
  }
  const query = option('--query');
  if (query === 'properties.provisioningState') console.log(scenario.failedApp ? 'Failed' : 'Succeeded');
  else if (query === 'properties.configuration.ingress.fqdn') console.log(scenario.emptyFqdn ? '' : 'gateway.example.invalid');
  else if (query.includes('config.service.endpoint')) console.log(scenario.wrongApim ? 'https://other.configuration.azure-api.net' : 'https://test-apim.configuration.azure-api.net');
  else if (query.includes('GATEWAY_TOKEN_EXPIRES_AT')) {
    console.error('CLI must not query operator-managed gateway token expiry.');
    process.exit(17);
  }
  else console.log('mcr.microsoft.com/azure-api-management/gateway:test-version');
} else if (args[0] === 'cognitiveservices') {
  if (!args.includes('--only-show-errors')) console.error('WARNING: cognitiveservices preview');
  console.log(scenario.emptyModel ? '' : option('--query').endsWith('.name') ?
    'actual-deployed-model' : '2025-08-07');
}
`;
  for (const name of ['az', 'copilot', 'curl']) {
    fs.writeFileSync(path.join(bin, name), mock, {mode: 0o700});
  }
  const script = path.join(copiedScripts, '3_copilot_cli.sh');
  const result = spawnSync('/bin/bash', [script, ...args], {
    cwd: root,
    env: {
      PATH: `${bin}:${path.dirname(process.execPath)}:/usr/bin:/bin`,
      HOME: root,
      COPILOT_PROVIDER_API_KEY: 'fake-stale-api-key',
      COPILOT_PROVIDER_BEARER_TOKEN: 'fake-stale-bearer',
      COPILOT_PROVIDER_API_KEY_COMMAND: 'fake-stale-key-command',
      COPILOT_PROVIDER_HEADERS: 'Authorization: fake-stale-header',
      COPILOT_PROVIDER_AZURE_API_VERSION: 'stale-version'
    },
    encoding: 'utf8',
    timeout: 20000
  });
  assert.ifError(result.error);
  const calls = fs.existsSync(log) ?
    fs.readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line)) : [];
  for (const secret of [apiKey, 'fake-stale-api-key', 'fake-stale-bearer']) {
    assert.ok(!result.stdout.includes(secret));
    assert.ok(!result.stderr.includes(secret));
    assert.ok(!calls.some(call => call.args.some(arg => arg.includes(secret))));
  }
  assert.ok(!fs.readdirSync(copiedScripts).some(name => name.startsWith('.api-key-check.')));
  return {...result, calls};
}

const invocation = result => result.calls.find(call =>
  call.tool === 'copilot' && !['--version', 'help'].includes(call.args[0]));

test('resolves actual resources, logs the same provider fields, and launches offline BYOK', t => {
  const result = run(t, {args: ['--verbose', '-p', 'prompt with spaces']});
  assert.equal(result.status, 0, result.stderr);
  const association = result.calls.find(call =>
    call.tool === 'az' && call.args.some(arg => arg.includes('/gateways/')));
  assert.equal(association.args[association.args.indexOf('--method') + 1], 'HEAD');
  const cli = invocation(result);
  assert.deepEqual(cli.args, ['-p', 'prompt with spaces', '--stream', 'off']);
  assert.equal(cli.env.COPILOT_OFFLINE, 'true');
  assert.equal(cli.env.COPILOT_PROVIDER_BASE_URL, 'https://gateway.example.invalid/self-hosted/openai');
  assert.equal(cli.env.COPILOT_PROVIDER_TYPE, 'openai');
  assert.equal(cli.env.COPILOT_PROVIDER_WIRE_API, 'completions');
  assert.equal(cli.env.COPILOT_MODEL, 'actual-deployed-model');
  assert.equal(cli.env.COPILOT_PROVIDER_MODEL_ID, 'actual-deployed-model');
  assert.equal(cli.env.COPILOT_PROVIDER_WIRE_MODEL, 'deployed-model');
  assert.equal(cli.env.COPILOT_PROVIDER_BEARER_TOKEN, undefined);
  assert.equal(cli.env.COPILOT_PROVIDER_API_KEY_COMMAND, undefined);
  assert.equal(cli.env.COPILOT_PROVIDER_API_KEY, apiKey);
  assert.equal(cli.env.COPILOT_PROVIDER_HEADERS, `Ocp-Apim-Subscription-Key: ${apiKey}`);
  assert.equal(cli.env.COPILOT_PROVIDER_AZURE_API_VERSION, undefined);
  assert.match(result.stdout, /AUTH\s+= API Key \(APIM subscription\)/);
  assert.match(result.stdout, /APIM_SUBSCRIPTION_ID\s+= copilot-cli/);
  assert.match(result.stdout, /API_KEY_HEADER\s+= Ocp-Apim-Subscription-Key \(value redacted\)/);
  assert.match(result.stdout, /COPILOT_PROVIDER_BASE_URL\s+= https:\/\/gateway.example.invalid\/self-hosted\/openai/);
  assert.match(result.stdout, /GATEWAY_IMAGE\s+= mcr.microsoft.com\/azure-api-management\/gateway:test-version/);
  assert.match(result.stdout, /ROUTE\s+= ACA self-hosted gateway -> Azure OpenAI \(backend API key\)/);
  assert.match(result.stdout, /COPILOT_EXIT_CODE\s+= 0/);
  assert.match(result.stdout, /STARTED_AT_UTC\s+= \d{4}-\d{2}-\d{2}T/);
  assert.ok(!result.stdout.includes('stale-configured-model'));
  assert.ok(!result.calls.some(call => call.args[1] === 'get-access-token'));
  for (const call of result.calls.filter(call => call.tool === 'az')) {
    assert.ok(call.args.includes('test-sub'));
    assert.ok(!call.args.includes('wrong-rg'));
  }
});

test('keeps interactive invocation, explicit streaming, and custom gateway names', t => {
  const interactive = run(t);
  assert.equal(interactive.status, 0, interactive.stderr);
  assert.deepEqual(invocation(interactive).args, ['--stream', 'off']);
  assert.equal(interactive.stderr, '');
  for (const field of ['STARTED_AT_UTC', 'APIM_RESOURCE_ID', 'GATEWAY_IMAGE', 'FINISHED_AT_UTC', 'COPILOT_EXIT_CODE']) {
    assert.ok(!interactive.stdout.includes(field));
  }
  for (const call of interactive.calls.filter(call =>
    call.tool === 'az' && ['containerapp', 'cognitiveservices'].includes(call.args[0]))) {
    assert.ok(call.args.includes('--only-show-errors'));
  }
  const streaming = run(t, {args: ['--stream=on', '-p', 'test'], scenario: {customNames: true}});
  assert.equal(streaming.status, 0, streaming.stderr);
  assert.deepEqual(invocation(streaming).args, ['--stream=on', '-p', 'test']);
  assert.ok(streaming.calls.some(call => call.args.includes('custom-app')));
  assert.ok(streaming.calls.some(call => call.args.some(arg => arg.includes('/gateways/custom-gateway/'))));
});

test('propagates CLI failures while emitting the final status', t => {
  const result = run(t, {args: ['--verbose'], scenario: {cliExit: 23}});
  assert.equal(result.status, 23);
  assert.match(result.stdout, /COPILOT_EXIT_CODE\s+= 23/);
  assert.match(result.stdout, /FINISHED_AT_UTC/);
});

test('quiet output preserves Azure errors and CLI exit codes', t => {
  const lookup = run(t, {scenario: {appLookupError: true}});
  assert.equal(lookup.status, 17);
  assert.match(lookup.stderr, /Container App lookup failed/);
  assert.equal(invocation(lookup), undefined);
  const cli = run(t, {scenario: {cliExit: 23}});
  assert.equal(cli.status, 23);
  assert.ok(!cli.stdout.includes('COPILOT_EXIT_CODE'));
});

test('resource, subscription, key, or unsupported CLI failures never fall back', t => {
  for (const scenario of [
    {missingApim: true}, {missingGateway: true}, {failedApp: true},
    {emptyFqdn: true}, {wrongApim: true}, {emptyModel: true},
    {keyError: true}, {emptyKey: true}, {suspended: true}, {oldCli: true}
  ]) {
    const result = run(t, {scenario});
    assert.notEqual(result.status, 0);
    assert.equal(invocation(result), undefined);
    assert.ok(result.stderr.trim());
    assert.ok(!result.stdout.includes('구성 완료'));
  }
});

test('verification checks missing, invalid, and valid keys without launching the CLI', t => {
  const result = run(t, {args: ['--verify-only']});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(invocation(result), undefined);
  const requests = result.calls.filter(call => call.tool === 'curl');
  assert.equal(requests.length, 3);
  for (const request of requests) {
    const body = JSON.parse(request.args[request.args.indexOf('--data') + 1]);
    assert.ok(Number.isInteger(body.max_completion_tokens) && body.max_completion_tokens > 0);
    assert.ok(!Object.hasOwn(body, 'max_tokens'));
  }
  assert.equal(requests[0].config, '');
  assert.match(requests[1].config, /invalid-subscription-key/);
  assert.ok(requests[2].config.includes(apiKey));
  assert.match(result.stdout, /API_KEY_CHECK missing = HTTP 401/);
  assert.match(result.stdout, /API_KEY_CHECK invalid = HTTP 401/);
  assert.match(result.stdout, /API_KEY_CHECK valid\s+= HTTP 200/);
  assert.match(result.stdout, /API_KEY_VERIFY_EXIT_CODE\s+= 0/);
});

test('verification fails explicitly on incorrect status or malformed completion', t => {
  for (const scenario of [{badStatus: true}, {badResponse: true}]) {
    const result = run(t, {args: ['--verify-only'], scenario});
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /API key check failed/);
    assert.match(result.stdout, /API_KEY_VERIFY_EXIT_CODE\s+= 1/);
  }
});

