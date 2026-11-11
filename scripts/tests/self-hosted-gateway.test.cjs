const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {test} = require('node:test');

const scripts = path.resolve(__dirname, '..');
const apimId = '/subscriptions/test-sub/resourceGroups/actual-rg/providers/Microsoft.ApiManagement/service/test-apim';
const fakeToken = 'test-gateway-token-not-a-real-credential';

function run(t, scenario = {}) {
  const root = fs.mkdtempSync(path.join(scripts, '.gateway-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const bin = path.join(root, 'bin');
  const copy = path.join(root, 'scripts');
  fs.mkdirSync(bin);
  fs.mkdirSync(copy);
  for (const name of ['common.sh', '1_create_self_hosted_gateway.sh']) {
    fs.copyFileSync(path.join(scripts, name), path.join(copy, name));
  }
  fs.writeFileSync(path.join(root, '.env'),
    'AZURE_SUBSCRIPTION_ID=test-sub\nAPIM_NAME=test-apim\nRESOURCE_GROUP_NAME=wrong-rg\n');
  const log = path.join(root, 'calls.jsonl');
  const mock = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const scenario = ${JSON.stringify(scenario)};
const option = key => args[args.indexOf(key) + 1];
const call = {tool: path.basename(process.argv[1]), args};
for (const key of ['--body', '--yaml']) {
  if (args.includes(key) && option(key) !== '{}') {
    const file = option(key).replace(/^@/, '');
    call[key] = JSON.parse(fs.readFileSync(file, 'utf8'));
    call.mode = fs.statSync(file).mode & 0o777;
  }
}
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(call) + '\\n');
if (call.tool === 'curl') {
  if (args.includes('--write-out')) {
    const requests = fs.readFileSync(${JSON.stringify(log)}, 'utf8')
      .split('\\n').filter(line => line.includes('--write-out')).length;
    process.stdout.write(scenario.badRoute || (scenario.delayedRoute && requests === 1) ?
      '404' : '401');
  } else {
    const deployment = fs.readFileSync(${JSON.stringify(log)}, 'utf8')
      .trim().split('\\n').map(line => JSON.parse(line)).find(item => item['--yaml']);
    const readiness = deployment['--yaml'].properties.template.containers[0].probes
      .find(probe => probe.type === 'Readiness');
    if (scenario.healthTimeout || readiness.httpGet.path !== '/status-0123456789abcdef' ||
        readiness.httpGet.port !== 8080) {
      console.error('curl: (28) Gateway has no ready replica');
      process.exit(28);
    }
    if (!args.includes('https://gateway.example.invalid/status-0123456789abcdef')) {
      console.error('curl: (22) Health endpoint returned 404');
      process.exit(22);
    }
  }
} else if (args[0] === 'apim') {
  if (args[1] === 'list') console.log(scenario.missingApim ? '' : ${JSON.stringify(apimId)});
  else {
    const query = option('--query');
    console.log(query === 'sku.name' ? (scenario.sku || 'Developer') :
      query === 'location' ? 'eastus2' : 'https://test-apim.azure-api.net');
  }
} else if (args[0] === 'rest') {
  if (scenario.missingBackendKey && option('--method') === 'GET' &&
      option('--uri').includes('/namedValues/openai-backend-key?')) {
    console.error('Deploy the Bicep-managed backend key first.');
    process.exit(17);
  }
  if (scenario.missingApi && option('--method') === 'GET' &&
      option('--uri').includes('/apis/self-hosted-openai?')) {
    console.error('Deploy the Bicep-managed self-hosted-openai API first.');
    process.exit(17);
  }
  if (option('--uri').includes('generateToken')) {
    if (scenario.tokenFailure) process.exit(17);
    console.log(scenario.emptyToken ? '' : ${JSON.stringify(fakeToken)});
  }
} else if (args[0] === 'containerapp') {
  if (args[1] === 'list' || args[2] === 'list') console.log(scenario.existing ? '1' : '0');
  else if (args[1] === 'env' && args[2] === 'show') {
    if (option('--query') === 'properties.workloadProfiles') {
      console.log(JSON.stringify(scenario.workloadProfiles === undefined ?
        [{name: 'Consumption', workloadProfileType: 'Consumption'}] : scenario.workloadProfiles));
    } else console.log('/subscriptions/test-sub/resourceGroups/actual-rg/providers/Microsoft.App/managedEnvironments/shg-test-apim-env');
  }
  else if (args[1] === 'show') console.log(option('--query') === 'properties.latestRevisionName' ? 'shg-test-apim--rev1' : 'gateway.example.invalid');
}
`;
  for (const name of ['az', 'curl', 'sleep']) {
    fs.writeFileSync(path.join(bin, name), mock, {mode: 0o700});
  }
  const result = spawnSync('/bin/bash', [path.join(copy, '1_create_self_hosted_gateway.sh')], {
    cwd: root,
    env: {PATH: `${bin}:${path.dirname(process.execPath)}:/usr/bin:/bin`, HOME: root},
    encoding: 'utf8',
    timeout: 20000
  });
  assert.ifError(result.error);
  const calls = fs.existsSync(log) ?
    fs.readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line)) : [];
  assert.ok(!result.stdout.includes(fakeToken));
  assert.ok(!result.stderr.includes(fakeToken));
  assert.ok(!calls.some(call => call.args.some(arg => arg.includes(fakeToken))));
  assert.deepEqual(fs.readdirSync(copy).sort(), ['1_create_self_hosted_gateway.sh', 'common.sh']);
  return {...result, calls};
}

test('creates a secret-backed ACA gateway using Bicep-managed backend credentials', t => {
  const result = run(t);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /SELF_HOSTED_GATEWAY_URL=https:\/\/gateway.example.invalid\/self-hosted/);
  const azureCalls = result.calls.filter(call => call.tool === 'az');
  for (const call of azureCalls) {
    assert.ok(call.args.includes('--subscription'));
    assert.ok(!call.args.includes('wrong-rg'));
  }
  assert.ok(azureCalls.some(call => call.args.includes('GET') && call.args.some(arg =>
    arg.endsWith('/apis/self-hosted-openai?api-version=2024-05-01'))));
  assert.ok(azureCalls.some(call => call.args.includes('GET') &&
    call.args.includes('none') && call.args.some(arg =>
      arg.includes('/namedValues/openai-backend-key?'))));
  assert.ok(!azureCalls.some(call => call.args.includes('listKeys')));
  assert.ok(!azureCalls.some(call => call.args.includes('PUT') && call.args.some(arg =>
    arg.includes('/apis/') && !arg.includes('/gateways/'))),
  'gateway provisioning must not overwrite the Bicep-managed API or policy');
  assert.ok(azureCalls.some(call => call.args.some(arg => arg.includes('/apis/self-hosted-openai?')) &&
    call.args.some(arg => arg.includes('/gateways/'))));
  const app = azureCalls.find(call => call['--yaml']);
  assert.equal(app.args[1], 'create');
  assert.equal(app.mode, 0o600);
  const properties = app['--yaml'].properties;
  assert.equal(properties.workloadProfileName, 'Consumption');
  const environment = azureCalls.find(call =>
    call.args.slice(0, 3).join(' ') === 'containerapp env create');
  assert.equal(environment.args[environment.args.indexOf('--enable-workload-profiles') + 1], 'true');
  assert.equal(environment.args[environment.args.indexOf('--logs-destination') + 1], 'none');
  assert.equal(properties.configuration.secrets[0].value, `GatewayKey ${fakeToken}`);
  assert.equal(properties.configuration.ingress.allowInsecure, false);
  assert.equal(properties.template.scale.minReplicas, 1);
  const auth = properties.template.containers[0].env.find(item => item.name === 'config.service.auth');
  assert.deepEqual(auth, {name: 'config.service.auth', secretRef: 'gateway-token'});
  const expiry = azureCalls.find(call => call['--body']?.expiry)['--body'].expiry;
  assert.equal(properties.template.containers[0].env.find(item =>
    item.name === 'GATEWAY_TOKEN_EXPIRES_AT').value, expiry);
  const remaining = Date.parse(expiry) - Date.now();
  assert.ok(remaining > 28 * 86400000 && remaining <= 29 * 86400000);
  assert.equal(result.calls.filter(call => call.tool === 'curl').length, 2);
});

test('reuses the environment and updates and restarts the existing app', t => {
  const result = run(t, {
    existing: true, sku: 'Premium',
    workloadProfiles: [
      {name: 'Consumption', workloadProfileType: 'Consumption'},
      {name: 'dedicated', workloadProfileType: 'D4'}
    ]
  });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.calls.some(call => call.args.slice(0, 3).join(' ') === 'containerapp env create'));
  assert.equal(result.calls.find(call => call['--yaml']).args[1], 'update');
  assert.equal(result.calls.find(call => call['--yaml'])['--yaml'].properties.workloadProfileName,
    'Consumption');
  assert.ok(result.calls.some(call => call.args.slice(0, 3).join(' ') === 'containerapp revision restart'));
});

test('preserves legacy Consumption-only environments without naming a workload profile', t => {
  for (const workloadProfiles of [null, []]) {
    const result = run(t, {existing: true, workloadProfiles});
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Using existing Consumption-only environment/);
    assert.ok(!Object.hasOwn(result.calls.find(call => call['--yaml'])['--yaml'].properties,
      'workloadProfileName'));
  }
});

test('rejects environments without a matching Consumption profile before deploying the app', t => {
  for (const workloadProfiles of [
    [{name: 'dedicated', workloadProfileType: 'D4'}],
    [{name: 'Consumption', workloadProfileType: 'D4'}]
  ]) {
    const result = run(t, {existing: true, workloadProfiles});
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Environment has no Consumption workload profile/);
    assert.ok(!result.calls.some(call => call['--yaml']));
    assert.ok(!result.stdout.includes('Gateway is healthy'));
  }
});

test('rejects unsupported SKUs and missing Bicep resources before any writes', t => {
  for (const scenario of [
    {sku: 'PremiumV2'}, {missingApim: true}, {missingApi: true}, {missingBackendKey: true}
  ]) {
    const result = run(t, scenario);
    assert.notEqual(result.status, 0);
    assert.ok(!result.calls.some(call => call.args.includes('PUT')));
  }
});

test('token errors stop deployment and remove temporary credential files', t => {
  for (const scenario of [{emptyToken: true}, {tokenFailure: true}]) {
    const result = run(t, scenario);
    assert.notEqual(result.status, 0);
    assert.ok(!result.calls.some(call => call['--yaml']));
    assert.ok(!result.stdout.includes('Gateway is healthy'));
  }
});

test('a missing proxy route fails instead of reporting deployment success', t => {
  const result = run(t, {badRoute: true});
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Expected unauthenticated proxy response 401, got 404/);
  assert.ok(!result.stdout.includes('Gateway is healthy'));
});

test('health timeouts fail without checking the API or reporting success', t => {
  const result = run(t, {healthTimeout: true});
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Gateway health check failed/);
  assert.ok(!result.calls.some(call => call.tool === 'curl' && call.args.includes('--write-out')));
  assert.ok(!result.stdout.includes('Gateway is healthy'));
});

test('waits for the initial gateway API configuration to synchronize', t => {
  const result = run(t, {delayedRoute: true});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls.filter(call => call.tool === 'curl').length, 3);
  assert.equal(result.calls.filter(call => call.tool === 'sleep').length, 1);
});
