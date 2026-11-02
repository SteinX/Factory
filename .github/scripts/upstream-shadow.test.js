const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { assessEvidence, classify, pendingReleases, validatePolicy, REQUIRED_GATES } = require('./upstream-shadow');
const policy = JSON.parse(fs.readFileSync(path.join(__dirname, '../upstream-shadow.json'), 'utf8'));

test('only stable semver releases, sorted by version, not GitHub latest or publication order', () => {
  const releases = ['v2.4.13', '3.4.2', '3.4.1', '3.4.0', '4.0.0-rc.1'].map((tag_name) =>
    ({ tag_name, draft: false, prerelease: false }));
  releases.push({ tag_name: '3.4.3', draft: true, prerelease: false });
  releases.push({ tag_name: '3.4.4', draft: false, prerelease: true });
  releases.push({ tag_name: 'nightly', draft: false, prerelease: false });
  assert.deepEqual(pendingReleases(releases, '3.4.0').map((r) => r.tag_name), ['3.4.1', '3.4.2']);
});

test('baseline approval and policy changes cannot silently activate writes', () => {
  validatePolicy(policy);
  assert(classify(policy, '3.4.1', ['README.md']).reasons.includes('BASELINE_NOT_APPROVED'));
  assert.throws(() => validatePolicy({ ...policy, mode: 'live' }));
  assert.throws(() => validatePolicy({ ...policy, allowedPaths: ['Sources/'] }));
});

test('sensitive, unknown, moved paths and major/minor updates fail closed', () => {
  const approved = { ...policy, baseline: { ...policy.baseline, approved: true } };
  assert.equal(classify(approved, '3.4.1', ['README.md']).decision, 'READY_FOR_VALIDATION');
  for (const file of ['Sources/FactoryKit/FactoryKit/Factory.swift', '.github/workflows/swift.yml',
    'CLAUDE.md', 'Package.swift', 'Factory.podspec', 'unknown.txt', 'CHANGELOG/../Sources/Factory.swift']) {
    assert.equal(classify(approved, '3.4.1', [file, 'README.md']).decision, 'NEEDS_HUMAN');
  }
  assert.equal(classify(approved, '3.5.0', ['README.md']).decision, 'NEEDS_HUMAN');
  assert.equal(classify(approved, '3.4.1', []).decision, 'NEEDS_HUMAN');
});

test('missing, skipped, duplicate and stale evidence fails; even complete JSON cannot authorize a merge', () => {
  const snapshot = { batchId: 'batch', decision: 'READY_FOR_VALIDATION',
    sources: { upstreamBaseline: 'a'.repeat(40), upstreamCandidate: 'b'.repeat(40), fork: 'c'.repeat(40) } };
  const evidence = { batchId: 'batch', sources: snapshot.sources,
    gates: REQUIRED_GATES.map((name) => ({ name, status: 'success', tests: 1, skipped: 0,
      runUrl: 'https://github.com/SteinX/Factory/actions/runs/123' })) };
  assert.equal(assessEvidence(snapshot, evidence).wouldPassLocalShapeChecks, true);
  assert.equal(assessEvidence(snapshot, evidence).mergeAllowed, false);
  assert.equal(assessEvidence(snapshot, evidence).publishAllowed, false);
  const reordered = { ...evidence, sources: Object.fromEntries(Object.entries(snapshot.sources).reverse()) };
  assert.notEqual(JSON.stringify(reordered.sources), JSON.stringify(snapshot.sources));
  assert.equal(assessEvidence(snapshot, reordered).wouldPassLocalShapeChecks, true);
  for (const changed of [
    { ...evidence, batchId: 'old' }, { ...evidence, sources: { ...snapshot.sources, fork: 'd'.repeat(40) } },
    { ...evidence, sources: { fork: snapshot.sources.fork } },
    { ...evidence, gates: [] }, { ...evidence, gates: [...evidence.gates, evidence.gates[0]] },
    { ...evidence, gates: evidence.gates.map((g) => ({ ...g, skipped: 1 })) },
    { ...evidence, gates: evidence.gates.map((g) => ({ ...g, status: 'cancelled' })) },
  ]) assert.equal(assessEvidence(snapshot, changed).wouldPassLocalShapeChecks, false);
});

test('monitor workflow has read-only permissions, no candidate execution, and no mutation commands', () => {
  const workflow = fs.readFileSync(path.join(__dirname, '../workflows/upstream-shadow.yml'), 'utf8');
  assert.match(workflow, /contents: read/);
  assert.doesNotMatch(workflow, /: write|pull_request_target|secrets: inherit/);
  assert.doesNotMatch(workflow, /gh (pr merge|release create|workflow run)|git push/);
});
