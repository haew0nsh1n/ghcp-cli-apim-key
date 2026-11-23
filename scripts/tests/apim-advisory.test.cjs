const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {test} = require('node:test');

const scripts = path.resolve(__dirname, '..');
const resourceId = (sub, name = 'apim-one') =>
  `/subscriptions/${sub}/resourceGroups/test-rg/providers/Microsoft.ApiManagement/service/${name}`;

function run(t, {args = [], scenario = {}, json = true} = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'apim-advisory-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  const log = path.join(root, 'calls.jsonl');
  fs.writeFileSync(path.join(bin, 'az'), `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
const option = key => args[args.indexOf(key) + 1];
const scenario = ${JSON.stringify(scenario)};
const resourceId = ${resourceId.toString()};
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(args) + '\\n');
const account = id => ({id, name: id, tenantId: 'tenant', state: scenario.disabled ? 'Disabled' : 'Enabled'});
if (args[0] === 'account') {
  if (scenario.accountFailure) { console.error('Login required'); process.exit(1); }
  if (args[1] === 'list') console.log(JSON.stringify([account('sub-a'), account('sub-b')]));
  else console.log(JSON.stringify(account(args.includes('--subscription') ? option('--subscription') : 'sub-a')));
  process.exit(0);
}
const sub = option('--subscription');
const uri = option('--uri');
const advisory = uri.includes('/listSecurityAdvisoryImpactedResources');
const named = uri.includes('/namedValues');
const metadata = /\\/(subscriptions|backends|authorizationServers|openidConnectProviders|identityProviders|authorizationProviders|loggers|policies|apis)\\?/.test(uri);
if ((scenario.advisoryFailure && advisory && sub === 'sub-a') ||
    (scenario.laterPageFailure && advisory && uri.includes('page=2')) ||
    (scenario.inventoryFailure && !advisory && !named) ||
    (scenario.namedFailure && named)) {
  console.error(advisory ? (scenario.advisoryError || 'AuthorizationFailed') : 'AuthorizationFailed');
  process.exit(17);
}
if (scenario.metadataFailure && uri.includes('/backends?')) {
  console.error('ERROR: MetadataAccessDenied'); process.exit(17);
}
if (scenario.invalidJson && advisory) { console.log('not json'); process.exit(0); }
if (scenario.invalidShape && advisory) { console.log('{}'); process.exit(0); }
const second = uri.includes('page=2');
let value;
if (advisory) {
  value = scenario.invalidAdvisory ? [{targetResourceId: 42, infoResourceIds: 'invalid'}] :
    scenario.targetId ? [{targetResourceId: resourceId(sub), infoResourceIds: null}] :
    scenario.lookalike ? [{targetResourceId: resourceId(sub) + '-other', infoResourceIds: []}] :
    scenario.unmapped ? [{targetResourceId: null, infoResourceIds: []}] :
    scenario.notListed || (scenario.pagination && !second) ? [] :
    [{targetResourceId: null, infoResourceIds: [resourceId(sub).toUpperCase(), resourceId(sub) + '-other']}];
} else if (named) {
  value = scenario.invalidNamed ? [{name: 'invalid', secret: null}] : [
    {name: 'direct', secret: true, keyVaultSecretIdentifier: null},
    {name: 'vault', secret: true, keyVaultSecretIdentifier: 'https://vault.vault.azure.net/secrets/key'},
    {name: 'plain', secret: false, keyVaultSecretIdentifier: null}
  ];
} else if (metadata) {
  value = [{name: uri.includes('/apis?') ? 'example-api' : 'metadata-item'}];
} else {
  value = scenario.noApim ? [] : [{
    id: resourceId(sub), name: 'apim-one', location: 'koreacentral',
    sku: 'Developer', virtualNetworkType: 'None', publicNetworkAccess: 'Enabled', privateEndpointCount: 0
  }];
  if (scenario.multipleApim) value.push({...value[0], id: resourceId(sub, 'apim-two'), name: 'apim-two'});
}
const nextLink = scenario.badNextLink && advisory ? 'https://unexpected.invalid/page' :
  scenario.repeatedNextLink && advisory ? uri :
  scenario.pagination && !second ? uri + '&page=2' : null;
console.log(JSON.stringify({value, nextLink}));
`, {mode: 0o700});
  const result = spawnSync('/bin/bash', [
    path.join(scripts, 'check_apim_advisory.sh'), ...(json ? ['--json'] : []), ...args
  ], {
    cwd: root,
    env: {...process.env, PATH: `${bin}:${process.env.PATH}`, TMPDIR: root},
    encoding: 'utf8',
    timeout: 20000
  });
  assert.ifError(result.error);
  const calls = fs.existsSync(log) ?
    fs.readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line)) : [];
  for (const call of calls) {
    assert.ok(!call.includes('set'), 'must not change default subscription');
    assert.ok(!call.some(arg => /listSecrets|listValue|PUT|DELETE|PATCH/.test(arg)));
    if (call[0] === 'rest') {
      assert.ok(call.includes('--subscription'));
      assert.ok(call.includes('--query'));
      const method = call[call.indexOf('--method') + 1];
      if (method === 'POST') {
        assert.match(call[call.indexOf('--uri') + 1], /listSecurityAdvisoryImpactedResources/);
      } else {
        assert.equal(method, 'GET');
      }
      const query = call[call.indexOf('--query') + 1];
      assert.ok(!query.includes('properties.value'));
      if (call.some(arg => arg.includes('/namedValues?'))) {
        assert.equal(query,
          '{nextLink:nextLink, value:value[].{name:name, secret:properties.secret, keyVaultSecretIdentifier:properties.keyVault.secretIdentifier}}');
      }
    }
  }
  assert.deepEqual(fs.readdirSync(root).filter(name => name.startsWith('apim-advisory.')), []);
  return {...result, calls, report: json && result.stdout.trim() ? JSON.parse(result.stdout) : null};
}

function tableRows(output) {
  return output.split('\n').filter(line => /^apim-/.test(line))
    .map(line => line.trim().split(/\s{2,}/));
}

function checkOutput(output) {
  return output.split('\n키 회전 작업 흐름 (조회만 실행:')[0];
}

test('rotation workflow reads metadata but never executes secret reads or credential changes', t => {
  for (const scenario of [{}, {advisoryFailure: true}]) {
    const result = run(t, {json: false, scenario});
    assert.equal(result.status, scenario.advisoryFailure ? 2 : 0, result.stderr);
    assert.ok(result.stdout.indexOf('키 회전 작업 흐름 (조회만 실행:') >
      result.stdout.indexOf('apim-one'));
    assert.match(result.stdout, /재발급·갱신·삭제는 실행하지 않음/);
    assert.match(result.stdout, /발급처에서 새 자격 증명 생성 → APIM 반영 → API 테스트 → 기존 자격 증명 폐기/);
    for (const step of [
      'APIM 구독 키', 'Named Values', 'Backend 자격 증명',
      'OAuth 2.0', 'Logger 연결 문자열', '정책에 직접 작성한 자격 증명',
      'Legacy Direct Management API 키', '최종 검증'
    ]) {
      assert.ok(result.stdout.includes(step), step);
    }
    assert.ok(!result.stdout.includes('az rest --method'));
    assert.ok(!result.calls.some(call => call.some(arg =>
      /regenerate|refreshSecret|show-secret|credential|listSecrets|listValue/.test(arg))));
    for (const collection of [
      'subscriptions', 'backends', 'authorizationServers', 'openidConnectProviders',
      'identityProviders', 'authorizationProviders', 'loggers', 'policies', 'apis',
      'apis/example-api/policies'
    ]) {
      assert.ok(result.calls.some(call => call.some(arg =>
        arg.includes(resourceId('sub-a') + '/' + collection + '?'))), collection);
    }
  }
});

test('metadata query failures preserve their errors and do not prevent later reads', t => {
  const result = run(t, {json: false, scenario: {metadataFailure: true}});
  assert.equal(result.status, 2);
  assert.match(result.stdout, /ERROR: MetadataAccessDenied/);
  assert.ok(result.calls.some(call => call.some(arg => arg.includes('/loggers?'))));
});

test('default output tables include every APIM with metadata and advisory status', t => {
  const listed = run(t, {json: false});
  assert.equal(listed.status, 0, listed.stderr);
  assert.match(listed.stdout, /Name +ResourceGroup +SubscriptionId +Location +SKU +Advisory\n/);
  assert.deepEqual(tableRows(listed.stdout), [
    ['apim-one', 'test-rg', 'sub-a', 'koreacentral', 'Developer', 'LISTED']
  ]);
  assert.match(checkOutput(listed.stdout).trim().split('\n').at(-1), /^apim-one /);
  assert.equal(listed.stderr, '');
  const multiple = run(t, {json: false, scenario: {multipleApim: true}});
  assert.equal(multiple.status, 0, multiple.stderr);
  assert.deepEqual(tableRows(multiple.stdout), [
    ['apim-one', 'test-rg', 'sub-a', 'koreacentral', 'Developer', 'LISTED'],
    ['apim-two', 'test-rg', 'sub-a', 'koreacentral', 'Developer', 'NOT_LISTED']
  ]);
  const starts = multiple.stdout.split('\n').filter(line => /^apim-/.test(line))
    .map(line => line.indexOf('test-rg'));
  assert.equal(starts[0], starts[1], 'columns must align across rows');
  for (const scenario of [{notListed: true}, {lookalike: true}]) {
    const absent = run(t, {json: false, scenario});
    assert.equal(absent.status, 0, absent.stderr);
    assert.equal(tableRows(absent.stdout)[0][5], 'NOT_LISTED');
    assert.match(checkOutput(absent.stdout).trim().split('\n').at(-1), /^apim-one /);
    assert.equal(absent.stderr, '');
  }
  const empty = run(t, {json: false, scenario: {noApim: true}});
  assert.equal(empty.status, 0, empty.stderr);
  assert.equal(checkOutput(empty.stdout), '공지: MZK9-GH0\n\n[구독: sub-a]\nAPIM 없음\n');
  assert.deepEqual(tableRows(empty.stdout), []);
});

test('text output distinguishes failed or unmappable checks from absence by subscription', t => {
  const mixed = run(t, {json: false, args: ['--all'], scenario: {advisoryFailure: true}});
  assert.equal(mixed.status, 2);
  assert.deepEqual(tableRows(mixed.stdout), [
    ['apim-one', 'test-rg', 'sub-a', 'koreacentral', 'Developer', 'AuthorizationFailed'],
    ['apim-one', 'test-rg', 'sub-b', 'koreacentral', 'Developer', 'LISTED']
  ]);
  for (const scenario of [{inventoryFailure: true}, {unmapped: true}, {disabled: true}]) {
    const unknown = run(t, {json: false, scenario});
    assert.equal(unknown.status, 2);
    assert.ok(!unknown.stdout.includes('APIM 없음'));
    if (scenario.unmapped) assert.equal(tableRows(unknown.stdout)[0][5], 'UNKNOWN');
    else assert.match(unknown.stdout, scenario.inventoryFailure ? /AuthorizationFailed/ : /APIM 목록 확인 불가/);
  }
});

test('table and JSON preserve the original advisory API error instead of replacing it with UNKNOWN', t => {
  for (const error of [
    'ERROR: Not Found({"code":"TrackingIdNotFound"})',
    'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"Access denied"}})',
    'ERROR: Request failed\nAdditional server detail'
  ]) {
    const scenario = {advisoryFailure: true, advisoryError: error};
    const text = run(t, {json: false, scenario});
    assert.equal(text.status, 2);
    assert.equal(tableRows(text.stdout)[0][5], error.replaceAll('\n', '\\n'));
    assert.match(checkOutput(text.stdout).trim().split('\n').at(-1), /^apim-one /);
    assert.ok(text.stderr.includes(error));
    const json = run(t, {scenario});
    assert.equal(json.status, 2);
    assert.equal(json.report.subscriptions[0].advisory.error, error);
    assert.equal(json.report.subscriptions[0].apim[0].advisory.error, error);
    assert.equal(json.report.subscriptions[0].advisory.totalReturned, null);
  }
});

test('text output still lists affected APIM when additional configuration checks fail', t => {
  const result = run(t, {json: false, scenario: {namedFailure: true}});
  assert.equal(result.status, 2);
  assert.equal(tableRows(result.stdout)[0][5], 'LISTED');
  assert.match(result.stdout, /추가 구성 점검 불완전/);
});

test('checks current subscription, matches exact IDs and emits only credential metadata', t => {
  const result = run(t);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.report.trackingId, 'MZK9-GH0');
  const sub = result.report.subscriptions[0];
  assert.equal(sub.subscription.id, 'sub-a');
  assert.equal(sub.apimCount, 1);
  assert.equal(sub.apim[0].resourceGroup, 'test-rg');
  assert.equal(sub.apim[0].advisory.status, 'LISTED');
  assert.equal(sub.apim[0].advisory.matchingRecordCount, 1);
  assert.deepEqual(sub.apim[0].namedValues.items, [
    {name: 'direct', secret: true, keyVaultReferenced: false, directSecret: true},
    {name: 'vault', secret: true, keyVaultReferenced: true, directSecret: false},
    {name: 'plain', secret: false, keyVaultReferenced: false, directSecret: false}
  ]);
  assert.ok(!result.stdout.includes('https://vault'));
});

test('supports all and repeated explicit subscriptions without changing Azure context', t => {
  for (const args of [['--all'], ['--subscription', 'sub-a', '--subscription', 'sub-b', '--subscription', 'sub-a']]) {
    const result = run(t, {args});
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.report.subscriptions.map(sub => sub.subscription.id), ['sub-a', 'sub-b']);
  }
});

test('follows every collection page with GET and honors the tracking ID override', t => {
  const result = run(t, {args: ['--tracking-id', 'OTHER-123'], scenario: {pagination: true}});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.report.trackingId, 'OTHER-123');
  assert.equal(result.report.subscriptions[0].apim[0].advisory.status, 'LISTED');
  const nextCalls = result.calls.filter(call => call.some(arg => arg.includes('page=2')));
  assert.equal(nextCalls.length, 4);
  assert.ok(nextCalls.every(call => call.includes('GET')));
});

test('a complete empty advisory is not a safety finding and empty inventory is explicit', t => {
  const result = run(t, {scenario: {notListed: true}});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.report.subscriptions[0].apim[0].advisory.status, 'NOT_LISTED_IN_RETURNED_RECORDS');
  assert.match(result.report.warnings.join(' '), /not proof/);
  const empty = run(t, {scenario: {noApim: true}});
  assert.equal(empty.status, 0, empty.stderr);
  assert.equal(empty.report.subscriptions[0].apimCount, 0);
});

test('matches targetResourceId but never matches a longer resource name', t => {
  const target = run(t, {scenario: {targetId: true}});
  assert.equal(target.status, 0, target.stderr);
  assert.equal(target.report.subscriptions[0].apim[0].advisory.status, 'LISTED');
  const lookalike = run(t, {scenario: {lookalike: true}});
  assert.equal(lookalike.status, 0, lookalike.stderr);
  assert.equal(lookalike.report.subscriptions[0].apim[0].advisory.status, 'NOT_LISTED_IN_RETURNED_RECORDS');
});

test('advisory failure remains UNKNOWN and does not stop other subscriptions', t => {
  const result = run(t, {args: ['--all'], scenario: {advisoryFailure: true}});
  assert.equal(result.status, 2);
  assert.equal(result.report.status, 'INCOMPLETE');
  const [first, second] = result.report.subscriptions;
  assert.equal(first.advisory.totalReturned, null);
  assert.equal(first.apim[0].advisory.status, 'UNKNOWN');
  assert.equal(first.apim[0].advisory.matchingRecordCount, null);
  assert.equal(second.apim[0].advisory.status, 'LISTED');
  assert.match(result.stderr, /AuthorizationFailed/);
});

test('failed inventory and named value queries are never represented as successful empty lists', t => {
  const inventory = run(t, {scenario: {inventoryFailure: true}});
  assert.equal(inventory.status, 2);
  assert.equal(inventory.report.subscriptions[0].inventoryStatus, 'UNKNOWN');
  assert.equal(inventory.report.subscriptions[0].apimCount, null);
  const named = run(t, {scenario: {namedFailure: true}});
  assert.equal(named.status, 2);
  assert.deepEqual(named.report.subscriptions[0].apim[0].namedValues, {status: 'UNKNOWN', items: null});
  const invalid = run(t, {scenario: {invalidNamed: true}});
  assert.equal(invalid.status, 2);
  assert.deepEqual(invalid.report.subscriptions[0].apim[0].namedValues, {status: 'UNKNOWN', items: null});
});

test('unmappable advisory records do not become NOT_LISTED', t => {
  const result = run(t, {scenario: {unmapped: true}});
  assert.equal(result.status, 2);
  assert.equal(result.report.subscriptions[0].advisory.unmappedRecordCount, 1);
  assert.equal(result.report.subscriptions[0].apim[0].advisory.status, 'UNKNOWN_RESOURCE_MAPPING');
});

test('malformed responses and unsafe or looping pagination are explicit failures', t => {
  for (const scenario of [
    {invalidJson: true}, {invalidShape: true}, {invalidAdvisory: true},
    {badNextLink: true}, {repeatedNextLink: true}, {pagination: true, laterPageFailure: true}
  ]) {
    const result = run(t, {scenario});
    assert.equal(result.status, 2);
    assert.equal(result.report.subscriptions[0].apim[0].advisory.status, 'UNKNOWN');
    assert.ok(result.stderr.trim());
    assert.ok(!result.calls.some(call => call.includes('https://unexpected.invalid/page')));
  }
});

test('disabled subscriptions are skipped and invalid inputs never call Azure', t => {
  const disabled = run(t, {scenario: {disabled: true}});
  assert.equal(disabled.status, 2);
  assert.equal(disabled.report.subscriptions[0].apimCount, null);
  assert.ok(!disabled.calls.some(call => call[0] === 'rest'));
  for (const args of [['--all', '--subscription', 'sub-a'], ['--tracking-id', '../id'], ['--subscription'], ['--unknown']]) {
    const result = run(t, {args});
    assert.equal(result.status, 1);
    assert.deepEqual(result.calls, []);
  }
  const login = run(t, {scenario: {accountFailure: true}});
  assert.equal(login.status, 1);
  assert.match(login.stderr, /Login required/);
});
