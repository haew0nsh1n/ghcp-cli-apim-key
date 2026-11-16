const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {test} = require('node:test');

const scripts = path.resolve(__dirname, '..');

function run(t, scenario = {}) {
  const root = fs.mkdtempSync(path.join(scripts, '.pii-image-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  fs.mkdirSync(path.join(root, 'scripts'));
  fs.mkdirSync(path.join(root, 'pii-filter'));
  for (const name of ['common.sh', '1_build_pii_image.sh']) {
    fs.copyFileSync(path.join(scripts, name), path.join(root, 'scripts', name));
  }
  fs.writeFileSync(path.join(root, '.env'), 'AZURE_SUBSCRIPTION_ID=test-sub\nACR_NAME=testacr\n');
  const log = path.join(root, 'calls.jsonl');
  const mock = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const tool = path.basename(process.argv[1]);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({tool, args}) + '\\n');
if (tool === 'az') {
  if (args[1] === 'show') console.log('testacr.azurecr.io');
  if (args[1] === 'build' && ${Boolean(scenario.buildFails)}) process.exit(17);
  if (args[1] === 'repository') console.log(${JSON.stringify(scenario.badDigest ? '' : `sha256:${'b'.repeat(64)}`)});
}
`;
  for (const name of ['az', 'azd']) {
    fs.writeFileSync(path.join(bin, name), mock, {mode: 0o700});
  }
  const result = spawnSync('/bin/bash', [path.join(root, 'scripts', '1_build_pii_image.sh')], {
    cwd: root,
    env: {PATH: `${bin}:${path.dirname(process.execPath)}:/usr/bin:/bin`, HOME: root},
    encoding: 'utf8', timeout: 10000
  });
  assert.ifError(result.error);
  const calls = fs.readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  return {...result, calls, root};
}

test('builds only the PII context for amd64 and persists a digest-pinned image', t => {
  const result = run(t);
  assert.equal(result.status, 0, result.stderr);
  const build = result.calls.find(call => call.args[1] === 'build');
  assert.equal(build.args[build.args.indexOf('--platform') + 1], 'linux/amd64');
  assert.equal(build.args.at(-1), path.join(result.root, 'pii-filter'));
  assert.ok(build.args.includes('--subscription'));
  const image = build.args[build.args.indexOf('--image') + 1];
  assert.match(image, /^pii-filter:[0-9]{14}-[a-f0-9]{8}$/);
  assert.ok(!image.includes('latest'));
  const saved = result.calls.find(call => call.tool === 'azd');
  assert.deepEqual(saved.args, [
    'env', 'set', 'PII_FILTER_IMAGE', `testacr.azurecr.io/pii-filter@sha256:${'b'.repeat(64)}`
  ]);
});

test('build and digest failures never persist a successful image', t => {
  for (const scenario of [{buildFails: true}, {badDigest: true}]) {
    const result = run(t, scenario);
    assert.notEqual(result.status, 0);
    assert.ok(!result.calls.some(call => call.tool === 'azd'));
    assert.ok(!result.stdout.includes('Image build completed'));
  }
});
