const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {test} = require('node:test');

const scripts = path.resolve(__dirname, '..');
const apimId = '/subscriptions/test-sub/resourceGroups/actual-rg/providers/Microsoft.ApiManagement/service/test-apim';
const productId = `${apimId}/products/copilot-cli`;
const collection = `https://management.azure.com${apimId}/subscriptions`;

function run(t, {args = ['1', 'dev-04', 'Developer "Four"'], scenario = {}} = {}) {
  const root = fs.mkdtempSync(path.join(scripts, '.subscription-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const bin = path.join(root, 'bin');
  const copy = path.join(root, 'scripts');
  fs.mkdirSync(bin);
  fs.mkdirSync(copy);
  for (const name of ['common.sh', '2_create_subscription_key.sh']) {
    fs.copyFileSync(path.join(scripts, name), path.join(copy, name));
  }
  fs.writeFileSync(path.join(root, '.env'),
    'AZURE_SUBSCRIPTION_ID=test-sub\nAPIM_NAME=test-apim\nRESOURCE_GROUP_NAME=wrong-rg\n');
  const log = path.join(root, 'calls.jsonl');
  fs.writeFileSync(path.join(bin, 'az'), `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
const option = key => args[args.indexOf(key) + 1];
const scenario = ${JSON.stringify(scenario)};
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(args) + '\\n');
if (args[0] === 'apim') {
  console.log(scenario.missingApim ? '' : ${JSON.stringify(apimId)});
} else {
  const uri = option('--uri');
  const method = option('--method');
  const isSubscription = uri.startsWith(${JSON.stringify(collection + '/')});
  const writeCount = fs.readFileSync(${JSON.stringify(log)}, 'utf8')
    .trim().split('\\n').map(line => JSON.parse(line)).filter(call => call.includes('PUT')).length;
  if ((scenario.productError && uri.includes('/products/')) ||
      (scenario.listError && uri.startsWith(${JSON.stringify(collection + '?')})) ||
      (scenario.putError && method === 'PUT') ||
      (scenario.putFailAt === writeCount && method === 'PUT') ||
      (scenario.verifyError && method === 'GET' && isSubscription)) {
    console.error('APIM management request failed.');
    process.exit(17);
  }
  if (method === 'GET' && uri.startsWith(${JSON.stringify(collection + '?')})) {
    const second = uri.includes('skiptoken=');
    console.log(JSON.stringify({
      exists: scenario.existing || (scenario.existingOnSecondPage && second) ||
        (scenario.existingId && option('--query').includes("name=='" + scenario.existingId + "'")) ? 1 : 0,
      nextLink: !second && (scenario.paginated || scenario.existingOnSecondPage) ?
        ${JSON.stringify(collection + '?api-version=2024-05-01&$skiptoken=next')} :
        scenario.badNextLink ? 'https://unexpected.invalid/page' : null
    }));
  } else if (method === 'GET' && isSubscription) {
    console.log(JSON.stringify({
      state: scenario.wrongState ? 'suspended' : 'active',
      scope: scenario.wrongScope ? '/products/other' : ${JSON.stringify(productId)}
    }));
  }
}
`, {mode: 0o700});
  const result = spawnSync('/bin/bash', [path.join(copy, '2_create_subscription_key.sh'), ...args], {
    cwd: root,
    env: {PATH: `${bin}:${path.dirname(process.execPath)}:/usr/bin:/bin`, HOME: root},
    encoding: 'utf8',
    timeout: 20000
  });
  assert.ifError(result.error);
  const calls = fs.existsSync(log) ?
    fs.readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line)) : [];
  assert.ok(!calls.some(call => call.some(arg => arg.includes('listSecrets'))));
  return {...result, calls};
}

const writes = result => result.calls.filter(args => args.includes('PUT'));

test('creates an active Product subscription without retrieving or printing keys', t => {
  const result = run(t);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(writes(result).length, 1);
  const request = writes(result)[0];
  assert.ok(request.includes(`${collection}/dev-04?api-version=2024-05-01`));
  const body = JSON.parse(request[request.indexOf('--body') + 1]);
  assert.deepEqual(body, {properties: {
    displayName: 'Developer "Four"',
    scope: productId,
    state: 'active',
    allowTracing: false
  }});
  assert.equal(request[request.indexOf('--output') + 1], 'none');
  assert.match(result.stdout, /APIM_SUBSCRIPTION_ID=dev-04/);
  assert.match(result.stdout, /created and verified/);
  assert.match(result.stdout, /Key values are not printed/);
  for (const call of result.calls) {
    assert.ok(call.includes('test-sub'));
    assert.ok(!call.includes('wrong-rg'));
    if (call.includes('GET') && call.some(arg => arg.includes('/subscriptions'))) {
      assert.ok(call.includes('--query') || call.includes('none'));
    }
  }
});

test('supports the default display name and subscription pagination', t => {
  const result = run(t, {args: ['1', 'dev-05'], scenario: {paginated: true}});
  assert.equal(result.status, 0, result.stderr);
  const request = writes(result)[0];
  assert.equal(JSON.parse(request[request.indexOf('--body') + 1]).properties.displayName,
    'Copilot CLI dev-05');
  assert.ok(result.calls.some(args => args.some(arg => arg.includes('$skiptoken=next'))));
});

test('no arguments create exactly one subscription with a unique generated ID', t => {
  const result = run(t, {args: []});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(writes(result).length, 1);
  const match = result.stdout.match(/APIM_SUBSCRIPTION_ID=(copilot-cli-[0-9a-f-]{36})/);
  assert.ok(match, result.stdout);
  assert.ok(writes(result)[0].includes(`${collection}/${match[1]}?api-version=2024-05-01`));
  assert.match(result.stdout, /CREATED_SUBSCRIPTION_COUNT=1/);
});

test('requested count creates exactly that many distinct subscriptions', t => {
  for (const args of [['3'], ['3', 'team', 'Developer']]) {
    const result = run(t, {args});
    assert.equal(result.status, 0, result.stderr);
    const requests = writes(result);
    assert.equal(requests.length, 3);
    const ids = [...result.stdout.matchAll(/APIM_SUBSCRIPTION_ID=(.+)/g)].map(match => match[1]);
    assert.equal(new Set(ids).size, 3);
    const prefix = args[1] || ids[0].replace(/-1$/, '');
    assert.deepEqual(ids, [1, 2, 3].map(index => `${prefix}-${index}`));
    for (const [index, request] of requests.entries()) {
      assert.ok(request.includes(`${collection}/${ids[index]}?api-version=2024-05-01`));
      const body = JSON.parse(request[request.indexOf('--body') + 1]);
      assert.equal(body.properties.displayName, `${args[2] || `Copilot CLI ${prefix}`} ${index + 1}`);
      assert.equal(body.properties.scope, productId);
      assert.equal(body.properties.primaryKey, undefined);
      assert.equal(body.properties.secondaryKey, undefined);
    }
    assert.match(result.stdout, /CREATED_SUBSCRIPTION_COUNT=3/);
  }
});

test('refuses existing subscriptions including those on later pages', t => {
  for (const scenario of [{existing: true}, {existingOnSecondPage: true}]) {
    const result = run(t, {scenario});
    assert.notEqual(result.status, 0);
    assert.equal(writes(result).length, 0);
    assert.match(result.stderr, /already exists/);
  }
});

test('invalid input fails before any Azure call', t => {
  for (const args of [
    [''], ['0'], ['-1'], ['1.5'], ['abc'], ['9007199254740992'],
    ['1', ''], ['1', '../other'], ['1', "id'query"], ['1', 'dev-04', ''],
    ['1', 'dev-04', 'a', 'b'],
    ['2', 'a'.repeat(255), 'name'], ['2', 'dev', 'a'.repeat(99)]
  ]) {
    const result = run(t, {args});
    assert.notEqual(result.status, 0);
    assert.deepEqual(result.calls, []);
    assert.ok(result.stderr.trim());
  }
});

test('a later duplicate prevents every write in the requested batch', t => {
  const result = run(t, {args: ['3', 'team'], scenario: {existingId: 'team-3'}});
  assert.notEqual(result.status, 0);
  assert.equal(writes(result).length, 0);
  assert.match(result.stderr, /team-3 already exists/);
});

test('a partial batch failure stops immediately and reports only confirmed IDs', t => {
  const result = run(t, {args: ['3', 'team'], scenario: {putFailAt: 2}});
  assert.notEqual(result.status, 0);
  assert.equal(writes(result).length, 2);
  assert.match(result.stdout, /APIM_SUBSCRIPTION_ID=team-1/);
  assert.ok(!result.stdout.includes('APIM_SUBSCRIPTION_ID=team-2'));
  assert.ok(!result.stdout.includes('APIM_SUBSCRIPTION_ID=team-3'));
  assert.ok(!result.stdout.includes('CREATED_SUBSCRIPTION_COUNT='));
  assert.match(result.stderr, /APIM management request failed/);
});

test('lookup and pagination failures never create a subscription', t => {
  for (const scenario of [
    {missingApim: true}, {productError: true}, {listError: true}, {badNextLink: true}
  ]) {
    const result = run(t, {scenario});
    assert.notEqual(result.status, 0);
    assert.equal(writes(result).length, 0);
    assert.ok(result.stderr.trim());
    assert.ok(!result.stdout.includes('created and verified'));
  }
});

test('creation and post-creation verification failures never report success', t => {
  for (const scenario of [
    {putError: true}, {verifyError: true}, {wrongState: true}, {wrongScope: true}
  ]) {
    const result = run(t, {scenario});
    assert.notEqual(result.status, 0);
    assert.ok(result.stderr.trim());
    assert.ok(!result.stdout.includes('created and verified'));
  }
});
