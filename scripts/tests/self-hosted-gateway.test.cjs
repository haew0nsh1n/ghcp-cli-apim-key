const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {test} = require('node:test');

const scripts = path.resolve(__dirname, '..');
const apimId = '/subscriptions/test-sub/resourceGroups/actual-rg/providers/Microsoft.ApiManagement/service/test-apim';
const fakeToken = 'test-gateway-token-not-a-real-credential';
const fakeFilterKey = 'test-pii-filter-key-not-a-real-credential';
const pullIdentity = '/subscriptions/test-sub/resourceGroups/actual-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pii-pull';
const piiImage = `testacr.azurecr.io/pii-filter@sha256:${'a'.repeat(64)}`;

function run(t, scenario = {}) {
  const root = fs.mkdtempSync(path.join(scripts, '.gateway-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const bin = path.join(root, 'bin');
  const copy = path.join(root, 'scripts');
  fs.mkdirSync(bin);
  fs.mkdirSync(copy);
  for (const name of ['common.sh', '2_create_self_hosted_gateway.sh']) {
    fs.copyFileSync(path.join(scripts, name), path.join(copy, name));
  }
  fs.mkdirSync(path.join(root, 'pii-filter'));
  const rules = fs.readFileSync(path.join(scripts, '..', 'pii-filter', 'rules.json'), 'utf8');
  fs.writeFileSync(path.join(root, 'pii-filter', 'rules.json'), scenario.invalidRules ?
    '{"version":"bad","rules":[]}' : rules);
  fs.writeFileSync(path.join(root, '.env'),
    `AZURE_SUBSCRIPTION_ID=test-sub\nAPIM_NAME=test-apim\nRESOURCE_GROUP_NAME=wrong-rg\n` +
    `ACR_NAME=testacr\nACR_PULL_IDENTITY_ID=${pullIdentity}\nPII_FILTER_IMAGE=${scenario.badImage ? 'wrong.azurecr.io/pii-filter:latest' : piiImage}\n`);
  const log = path.join(root, 'calls.jsonl');
  const mock = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const scenario = ${JSON.stringify(scenario)};
const option = key => args[args.indexOf(key) + 1];
const call = {tool: path.basename(process.argv[1]), args};
for (const key of ['--body']) {
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
      .trim().split('\\n').map(line => JSON.parse(line))
      .find(item => item['--body']?.type === 'Microsoft.App/containerApps');
    const readiness = deployment['--body'].properties.template.containers[0].probes
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
} else if (args[0] === 'acr') {
  console.log('testacr.azurecr.io');
} else if (args[0] === 'apim') {
  if (args[1] === 'list') console.log(scenario.missingApim ? '' : ${JSON.stringify(apimId)});
  else {
    const query = option('--query');
    console.log(query === 'sku.name' ? (scenario.sku || 'Developer') :
      query === 'location' ? 'eastus2' : 'https://test-apim.azure-api.net');
  }
} else if (args[0] === 'rest') {
  if (option('--method') === 'PUT' &&
      option('--uri').includes('/providers/Microsoft.App/containerApps/') &&
      scenario.deploymentFailure) {
    console.error('Container App deployment request failed.');
    process.exit(17);
  }
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
  if (option('--uri').includes('/namedValues/pii-filter-key/listValue?')) {
    console.log(scenario.emptyFilterKey ? '' : ${JSON.stringify(fakeFilterKey)});
  }
} else if (args[0] === 'containerapp') {
  if (args[1] === 'create' || args[1] === 'update') {
    console.error('Use ARM REST to preserve empty identity mappings.');
    process.exit(17);
  }
  if (args[1] === 'list' || args[2] === 'list') console.log(scenario.existing ? '1' : '0');
  else if (args[1] === 'env' && args[2] === 'show') {
    if (option('--query') === 'properties.workloadProfiles') {
      console.log(JSON.stringify(scenario.workloadProfiles === undefined ?
        [{name: 'Consumption', workloadProfileType: 'Consumption'}] : scenario.workloadProfiles));
    } else console.log('/subscriptions/test-sub/resourceGroups/actual-rg/providers/Microsoft.App/managedEnvironments/shg-test-apim-env');
  }
  else if (args[1] === 'show') {
    const query = option('--query');
    if (query === 'properties.provisioningState') {
      const polls = fs.readFileSync(${JSON.stringify(log)}, 'utf8')
        .trim().split('\\n').map(line => JSON.parse(line))
        .filter(item => item.args.includes('properties.provisioningState')).length;
      console.log(scenario.provisioningState ||
        (scenario.provisioningPending && polls === 1 ? 'InProgress' : 'Succeeded'));
    } else console.log(query === 'properties.latestRevisionName' ? 'shg-test-apim--rev1' :
      query === 'properties.latestReadyRevisionName' ?
        (scenario.sidecarNotReady ? 'old-revision' : 'shg-test-apim--rev1') : 'gateway.example.invalid');
  }
}
`;
  for (const name of ['az', 'curl', 'sleep']) {
    fs.writeFileSync(path.join(bin, name), mock, {mode: 0o700});
  }
  const result = spawnSync('/bin/bash', [path.join(copy, '2_create_self_hosted_gateway.sh')], {
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
  assert.ok(!result.stdout.includes(fakeFilterKey));
  assert.ok(!result.stderr.includes(fakeFilterKey));
  assert.ok(!calls.some(call => call.args.some(arg => arg.includes(fakeFilterKey))));
  assert.deepEqual(fs.readdirSync(copy).sort(), ['2_create_self_hosted_gateway.sh', 'common.sh']);
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
  const app = azureCalls.find(call => call['--body']?.type === 'Microsoft.App/containerApps');
  assert.equal(app.args[0], 'rest');
  assert.equal(app.args[app.args.indexOf('--method') + 1], 'PUT');
  assert.equal(app.args[app.args.indexOf('--uri') + 1],
    'https://management.azure.com/subscriptions/test-sub/resourceGroups/actual-rg/providers/Microsoft.App/containerApps/shg-test-apim?api-version=2024-03-01');
  assert.ok(!azureCalls.some(call => call.args.includes('--yaml')));
  assert.equal(app.mode, 0o600);
  const properties = app['--body'].properties;
  assert.equal(properties.workloadProfileName, 'Consumption');
  const environment = azureCalls.find(call =>
    call.args.slice(0, 3).join(' ') === 'containerapp env create');
  assert.equal(environment.args[environment.args.indexOf('--enable-workload-profiles') + 1], 'true');
  assert.equal(environment.args[environment.args.indexOf('--logs-destination') + 1], 'none');
  assert.equal(properties.configuration.secrets[0].value, `GatewayKey ${fakeToken}`);
  assert.equal(properties.configuration.ingress.allowInsecure, false);
  assert.equal(properties.template.scale.minReplicas, 1);
  assert.equal(properties.template.containers.length, 2);
  const filter = properties.template.containers[1];
  assert.equal(filter.name, 'pii-filter');
  assert.equal(filter.image, piiImage);
  assert.deepEqual(filter.resources, {cpu: 0.5, memory: '1Gi'});
  assert.ok(filter.probes.some(probe => probe.type === 'Readiness' &&
    probe.httpGet.path === '/healthz' && probe.httpGet.port === 8000));
  assert.deepEqual(properties.configuration.registries, [
    {server: 'testacr.azurecr.io', identity: pullIdentity}
  ]);
  assert.equal(properties.configuration.ingress.targetPort, 8080);
  assert.equal(properties.configuration.secrets.find(secret =>
    secret.name === 'pii-filter-key').value, fakeFilterKey);
  assert.deepEqual(JSON.parse(properties.configuration.secrets.find(secret =>
    secret.name === 'pii-rules').value),
  JSON.parse(fs.readFileSync(path.join(scripts, '..', 'pii-filter', 'rules.json'), 'utf8')));
  assert.ok(!filter.env.some(variable => Object.hasOwn(variable, 'value')),
    'key and rules must be injected through secretRef');
  assert.deepEqual(app['--body'].identity,
    {type: 'UserAssigned', userAssignedIdentities: {[pullIdentity]: {}}});
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
  const deployment = result.calls.find(call => call['--body']?.type === 'Microsoft.App/containerApps');
  assert.equal(deployment.args[deployment.args.indexOf('--method') + 1], 'PUT');
  assert.equal(deployment['--body'].properties.workloadProfileName, 'Consumption');
  assert.deepEqual(deployment['--body'].identity,
    {type: 'UserAssigned', userAssignedIdentities: {[pullIdentity]: {}}});
  assert.ok(result.calls.some(call => call.args.slice(0, 3).join(' ') === 'containerapp revision restart'));
});

test('preserves legacy Consumption-only environments without naming a workload profile', t => {
  for (const workloadProfiles of [null, []]) {
    const result = run(t, {existing: true, workloadProfiles});
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Using existing Consumption-only environment/);
    assert.ok(!Object.hasOwn(result.calls.find(call =>
      call['--body']?.type === 'Microsoft.App/containerApps')['--body'].properties,
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
    assert.ok(!result.calls.some(call => call['--body']?.type === 'Microsoft.App/containerApps'));
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
    assert.ok(!result.calls.some(call => call['--body']?.type === 'Microsoft.App/containerApps'));
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

test('invalid image, rules or filter key prevent gateway writes', t => {
  for (const scenario of [{badImage: true}, {invalidRules: true}, {emptyFilterKey: true}]) {
    const result = run(t, scenario);
    assert.notEqual(result.status, 0);
    assert.ok(!result.calls.some(call => call.args.includes('PUT')));
    assert.ok(!result.calls.some(call => call['--body']?.type === 'Microsoft.App/containerApps'));
  }
});

test('an unready PII sidecar fails deployment rather than reporting gateway success', t => {
  const result = run(t, {sidecarNotReady: true});
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Gateway\/PII sidecar revision did not become ready/);
  assert.ok(!result.stdout.includes('Gateway is healthy'));
  assert.ok(!result.calls.some(call => call.tool === 'curl'));
});

test('waits for ARM provisioning before restarting an existing app', t => {
  const result = run(t, {existing: true, provisioningPending: true});
  assert.equal(result.status, 0, result.stderr);
  const polls = result.calls.map((call, index) =>
    call.args.includes('properties.provisioningState') ? index : -1).filter(index => index >= 0);
  assert.equal(polls.length, 2);
  const restart = result.calls.findIndex(call =>
    call.args.slice(0, 3).join(' ') === 'containerapp revision restart');
  assert.ok(restart > polls[1]);
  assert.equal(result.calls.filter(call => call.tool === 'sleep').length, 1);
});

test('deployment errors stop before revision restart and health checks', t => {
  for (const scenario of [
    {deploymentFailure: true}, {provisioningState: 'Failed'}, {provisioningState: 'Canceled'}
  ]) {
    const result = run(t, {existing: true, ...scenario});
    assert.notEqual(result.status, 0);
    assert.ok(!result.calls.some(call =>
      call.args.slice(0, 3).join(' ') === 'containerapp revision restart'));
    assert.ok(!result.calls.some(call => call.tool === 'curl'));
    assert.ok(!result.stdout.includes('Gateway is healthy'));
  }
});
