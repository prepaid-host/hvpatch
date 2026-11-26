# Unattended pipeline (Kubernetes)

`builder/run.sh` builds one kernel on one host with Docker or Podman. For
a repository that follows Proxmox's kernel releases on its own, the same
stages run as a Kubernetes CronJob. The project builds at
<https://mirror.prepaid-host.io/hvpatch/> are made this way.

## What it does

Every few minutes (5 in the project's setup) one pod runs these stages, each in its own container and
one after the other (`builder/pipeline.sh <stage>`):

| Stage | Does | Gets |
| --- | --- | --- |
| `prepare` | updates the repository checkout, fetches the published repository, decides what to build (`builder/plan.sh`) | upload key (read) |
| `fetch` | downloads the shipped kernel packages, records checksums of what Gate A and QEMU read | – |
| `build` | klp-build, Gate A, source bundle (`build.sh`) | checkout read-only, **no keys** |
| `sign` | checks the shipped artifacts, Gate A again, module signature | module key |
| `test` | checks the shipped artifacts, QEMU stage (TCG if there is no `/dev/kvm`) | – |
| `publish` | checks again, signs the manifest (`publish.sh`, ring canary), promotes and renews (`rings.sh`), uploads | manifest key, upload key |

`plan.sh` picks at most one kernel per run: the `NEWEST` releases of each
series in `SERIES` (from the Proxmox repository via apt, so the package
signatures are checked) that have no published level yet, or whose
published level was built from an older catalog. A kernel that failed, or
had nothing to livepatch, at a catalog commit is not tried again until the
catalog changes. Releases missing from `kernels.lock` are built with
`AUTO_LOCK=1` from the commit that released them (logged).

## Rings

Fresh builds go to `canary`. Every run, with or without a build, `publish`
also runs `builder/rings.sh`:

- a level moves from canary to early after `PROMOTE_EARLY_DAYS` (3) and
  from early to stable after `PROMOTE_STABLE_DAYS` (7) more, one ring per
  run;
- a level listed in `rings/holds` (by pull request) or revoked is not
  promoted;
- every ring manifest that expires within `RENEW_DAYS` (10) is re-signed
  with a new expiry `VALID_DAYS` (30) from now, same level and build time.
  Revoked levels are left to expire.
- the published repository is synced from the web server, so `rings.sh`
  trusts none of it: every manifest and `v1/revoked.json` must verify, and
  the time a level spent in a ring and the highest level each ring served
  are recorded in `state/rings` on the volume (only prepare and publish
  mount it). An older manifest put back on the server is neither renewed
  nor promoted, and an expired one never comes back.

Promotion goes by time only: the pipeline cannot tell whether canary nodes
had problems. Watch the canary nodes (contrib/prometheus) and add a hold or
revoke when they do. `PROMOTE=0` keeps everything in canary and only renews.

## Pull request test builds

With `PR_TESTS=1`, a run that finds nothing to build for main tests an
open pull request instead: the oldest one that changes `catalog/`, is
ready for review (a draft only with the label `test-build`), comes
from a branch of the repository itself (not a fork: the build stage runs
its patches) and still has a kernel without a result for its head commit
(`builder/pr-list.sh`). One kernel per run, as for main, which always
comes first. The stages differ in three places:

- lint lets `reviewed_by: ["pending-review"]` pass;
- sign uses a throwaway key and certificate made in the container, never
  the module key, so nothing of an unreviewed pull request is signed for
  real;
- publish uploads nothing and does no ring maintenance. It records the
  result in `state/pr` (a new push gets new builds) and reports it
  (`builder/github-report.sh`): a commit status `hvpatch/test-build <kernel>`
  and, unless nothing in the catalog applies to the kernel, a comment with
  Gate A, the patched functions and the QEMU result, or the end of the log
  of the failed stage.

Reporting needs a token in `GITHUB_TOKEN_FILE` (default `/gh/token`, mounted
into the publish container only) with write access to commit statuses and
pull requests of `GITHUB_REPO`; without one the result is only in the job
log. A pull request test holds the lock like any run, so a merge to main
waits for it to finish.

## Locking

Only one run works on the volume at a time: `prepare` takes a lock that
`publish` releases (or a failing stage). A run started by hand while another
one is active does nothing. A lock older than `LOCK_STALE_MIN` minutes (420)
comes from a killed pod and is taken over. The lock lives in `LOCK_DIR`,
which the build container does not mount.

## Trust

- The build stage runs kernel Makefiles and catalog patches. It never sees a
  key, it gets the repository checkout read-only, and the plan and the
  checksums of the shipped artifacts are on a volume it does not mount.
  Sign, test and publish check the shipped artifacts against those
  checksums before they rely on them.
- The manifest key is online in this setup (a Kubernetes secret, mounted
  only into the publish container). Whoever controls the cluster can sign
  for every node that trusts this key. Keep the key offline instead
  (`builder/run.sh` and `publish.sh` on a signing machine) if that is not
  acceptable, or trust such a key on canary nodes only.
- The publish container also gets the repository checkout read-only, for
  the public manifest key (`project-keys/manifest.pub`, which `rings.sh`
  checks every manifest against before promoting or renewing it) and
  `rings/holds`.
- The pod has no service account token. The QEMU stage runs without network
  (`-nic none`).

## Running it

You need: the builder image (`ghcr.io/prepaid-host/hvpatch-builder`, built by
`.github/workflows/builder-image.yml`, pin it by digest), a volume for the
build cache (about 55 GB per kernel tree; `KEEP_TREES` limits it), the two
keys and an SSH key for the repository host, which should accept it only
for `rrsync` on the repository directory.

The manifests of the project's own setup (Fleet, RKE2, Ceph) are in the
`k8s-ph-1` repository of Prepaid-Host (`apps/hvpatch-builder`,
`apps/mirror`); this repository does not depend on them.
