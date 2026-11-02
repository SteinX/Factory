# Upstream synchronization: shadow mode

This first infrastructure increment observes and validates. **It cannot merge,
approve, publish, push tags, update `latest`, or deploy.** Passing local JSON
validation is not an authorization.

## Monitoring

`upstream-shadow.yml` runs at 01:17 UTC (09:17 Asia/Shanghai) after this PR is
merged, or manually. It has only `contents: read`, uses no persisted checkout
credential, never checks out or executes upstream candidate code, and uploads a
snapshot to the run. It does not open duplicate PRs or start paid Devin sessions.
GitHub scheduled runs are best effort, not a guaranteed delivery time.

The collector paginates all `hmlongco/Factory` releases, ignores drafts,
prereleases and non-semver names, and selects the oldest pending stable tag.
Upstream tags are bare semver (`3.4.1`) with an older `v2.4.x` prefix series;
both forms are accepted, but a version must be strictly newer than the baseline.
Do not use GitHub's `releases/latest`: it is a publication-time ordering, not a
version ordering. API/fetch failures fail the job, not `NO_UPDATE`.

The proposed upstream baseline is `3.4.0` at
`b02457db582b6773c578f407e43350a15bf79cb6` — the upstream commit the fork's
`main` last merged. The collector checks its current tag resolution and
ancestry in the fork. **`approved: false` is deliberate**: a maintainer must
review the baseline and policy before any new candidate may progress to
advisory agent analysis. No update does not mean approval.

Classification is fail-closed: only README/CHANGELOG-only patch changes can
progress after baseline approval. Library source (`Sources/`), tests,
`Package.swift`, `Factory.podspec`, workflow/agent instructions, unknown
paths and major/minor upgrades require human review. This conservative starter
allowlist intentionally blocks most real upgrades; extending it needs a
reviewed controller change. The full Git diff (no API file-count truncation;
both sides of renames) is used.

Each report binds policy digest, upstream baseline/candidate and the fork main
SHA into a stable batch ID. This is an input identity, not a durable processing
ledger. Later implementation must persist completion state before enabling
repeated mutation-capable runs.

## Local / Devin shadow run

Prerequisites: Node 22, Git and authenticated `gh` with read access to both
repositories. Run from this repository:

```sh
mkdir -p "$HOME/.devin-files"
node .github/scripts/upstream-shadow.js collect .github/upstream-shadow.json \
  "$HOME/.devin-files/factory-upstream-shadow.json"
node .github/scripts/upstream-shadow.test.js
```

For Devin orchestration, invoke the `dynamic-workflows` skill then `run_workflow`
with `script_path` pointing to `.github/scripts/upstream-shadow-workflow.py`.
The script reads the frozen snapshot above (`FACTORY_SHADOW_SNAPSHOT` overrides
the path). Do not recollect it while resuming the same workflow run.

`NO_UPDATE` and `NEEDS_HUMAN` deliberately exit before spawning any agents.
Otherwise two read-only stages pass structured findings from synchronization to
independent review. A failed agent aborts the pipeline; resume the same run
only if its frozen inputs remain valid. These stages produce plans, not
candidate commits or test passes. They have no write authorization.

## Evidence contract

`upstream-shadow.js assess SNAPSHOT EVIDENCE OUTPUT` checks a local aggregate:

```json
{
  "batchId": "<snapshot batchId>",
  "sources": {"<all keys>": "<copy snapshot.sources exactly>"},
  "gates": [
    {"name": "fork-ci", "status": "success", "tests": 1, "skipped": 0,
     "runUrl": "https://github.com/SteinX/Factory/actions/runs/123"}
  ]
}
```

All names in the snapshot's `requiredGates` must appear once. Missing,
duplicate, skipped, cancelled or stale results fail. The sample is
intentionally incomplete and must not pass. A URL or local JSON cannot
authenticate the check issuer: even a complete aggregate always returns
`mergeAllowed: false` and `publishAllowed: false`. Do not configure this as a
production release gate.

## Releasing the fork

`release-check.yml` runs on every published fork release (or manually) and
verifies the release tag matches `s.version` in `Factory.podspec` and that
`swift test` passes at the tagged SHA. It is verification only; it does not
publish anything.

Fork releases use `<upstream-version>-fork.<N>` suffix tags (e.g.
`3.5.2-fork.1`), which never collide with upstream's bare-semver tag names.
`release-check.yml` accepts exactly this suffix on top of `X.Y.Z`. The fork's
older bare `3.2.x` tags predating this scheme remain as-is; do not tag bare
semver releases going forward — `3.5.2`-style names are upstream's namespace.

## Required before live automation (not implemented in this increment)

- Approved baseline, expanded reviewed risk policy, tracked conflict
  resolutions and three-way analysis of fork-only paths (`FactoryLists.swift`,
  podspec source, DocC additions); never blindly choose ours/theirs.
- Candidate PR implementation, durable batch state, deduplication, bounded
  retries and a global pause switch; retain merge ancestry or an explicit
  replay baseline if squash-only rules apply.
- ~~A decided, non-colliding fork release version scheme~~ — decided:
  `<upstream-version>-fork.<N>` (see above).
- Trusted check issuer/run verification, expected test inventory,
  authenticated evidence and exact head/base checks at merge time. Candidate
  scripts cannot certify themselves. Source changes invalidate evidence.
- Independent review satisfying actual GitHub rules. Administrators enable
  auto-merge and required checks without bypass/weakening existing
  protections.
- Failure drills: moved tag, stale source, all-skipped tests, missing
  artifact, duplicate events and interrupted retry.

Do not enable live merging by merely flipping a JSON flag: no such mode exists.
Keep existing release practices untouched until these follow-ups are
separately reviewed and verified.
