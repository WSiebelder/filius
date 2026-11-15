# Repository instructions

## Scope and implementation boundaries

This repository is the central configuration and orchestration repository for
the finius self-hosted build/deployment server. The target host is headless,
Ubuntu-based Linux Mint with systemd and Bash 4+. Applications and runners use
the dedicated rootless Docker daemon on the same machine.

Distinguish implemented source from the approved target and verified host
operation. `STATE.md` records implementation/history; `BACKLOG.md` defines
remaining work and acceptance criteria.

Implemented now:

- Root `setup.sh` prepares rootless Docker, builds local runner images, and
  installs/enables/starts `filius-orchestrator.service`.
- The orchestration service maintains one worker registered to this repository
  by launching fresh one-job ephemeral runners after jobs/exits and at boot.
- `.github/workflows/dispatch_runner.yml` is manual-only (`workflow_dispatch`).
  It writes an empty run/attempt request, waits for a host result and reports
  no-op/enable/reuse/errors. Host-only Python scans this repository's queued
  jobs in queued/active runs and current attempts, with bounded pagination.
- `eligible-repositories.json` and installed validation currently allow only
  `WSiebelder/filius`, once, with one managed build worker. Additional targets,
  counts and control-repository URLs are rejected until support is implemented.
- `filius-dispatch.path/service` handles constrained scan requests;
  `filius-build-worker.service` cycles one-job build runners only while enabled
  by demand. Persistent enabled/identity/idle state survives ordinary restart.
  Never-enabled/expired workers do not revive on setup/reboot.
- Eight-hour idle retirement removes `docker-build`, waits at least 60 seconds,
  and rechecks API busy/labels plus local job evidence before targeted stop.
  Busy/uncertain work is never deliberately stopped. Operator drain uses the
  same gate and waits for active jobs instead of launching replacements.
- Orchestration uses `docker-orchestrate`, not `docker-build` or `docker-deploy`,
  and its container has no Docker socket or deployment-directory mount.
- `runner-pool.sh` remains a legacy foreground two-build/one-deploy pool for an
  explicitly supplied repository URL. It is not started by setup. The detached
  dashboard rewrite was discarded; do not assume start/status/stop commands,
  persisted worker state, or eight-hour expiry exist in this legacy script.
  Do not run it alongside the managed worker when expecting capacity one.

General multi-repository/capacity configuration, central deployment dispatch,
application delivery, registry publishing and monitoring remain unimplemented.
Local mocked/syntax checks do not verify host boot recovery, registration/job
execution or atomic assignment/drain behavior. Label removal plus observations
is not a documented atomic drain API; uncertainty defers destructive action.

## Approved target design

- Use repository-scoped registration for personal-account repositories. Do not
  require an organization, migrate repositories or imply account-wide runner
  registration exists. An account URL identifies configuration scope, not a
  runner-registration endpoint.
- Keep one always-available orchestration worker in this repository, exempt
  from workload idle expiry. "Permanent" means supervised availability, not a
  permanent non-ephemeral runner registration.
- This repository's target list is an eligibility allowlist. Configured worker
  counts are capacity limits, not instructions to start every configured worker.
- Extend the manually triggered `dispatch_runner` workflow to query account
  repositories for runnable queued jobs, intersect with the allowlist, and
  start only missing matching capacity. Reuse idle/busy/starting workers and
  prevent duplicate launches or capacity overruns across concurrent dispatches.
- Inspect jobs, not just workflow-run status: active runs can contain queued
  downstream jobs. Handle pagination and supported runner labels. Do not launch
  for completed/cancelled jobs, blocked work, unsupported labels, ineligible
  repositories, or repositories without runnable queued work. API errors are
  not permission to launch.
- Discovery occurs only on explicit dispatch. Do not add scheduled polling,
  automatic job-triggered revival, or a continuously running queue scheduler
  without a new design decision. Later-ready jobs require another dispatch
  unless a matching enabled worker can accept them.
- Workload workers expire after eight continuous idle hours. Job start cancels
  the idle deadline; a fresh runner after completion gets a new idle period.
  Never kill an active job because of this limit, including jobs longer than
  eight hours. Expired workers remain disabled until dispatch finds eligible
  work or an operator explicitly uses `--all`/`--service`; setup/reboot/retry
  must not silently undo expiry.
- Keep exactly one centrally registered deployment worker and execute
  deployment workflows in this repository, globally serialized. Dispatch
  starts it only when its central queue needs it. Application repositories
  submit verified successful release information through an explicitly
  authorized trigger. Calling a reusable workflow hosted here does not move
  execution out of the caller repository.
- Standardized reusable build workflows test proposed PR merge results before
  merge and build/test `master` again after merge. Applications define their
  Dockerfile/context, tests, image name/version and deployment settings.
- Prefer updating the selected Compose service's image reference and applying
  `docker compose up -d` on the same daemon. A plain restart does not apply a
  changed image. Preserve unrelated services/data. Image transport, release
  schema, submission authentication, settings, health checks and rollback
  remain explicit backlog decisions.

## Architecture and operational invariants

- `rootless-docker/setup.sh` manages the locked `filius-runner` account,
  subordinate IDs, linger, private home and rootless Docker user service.
  `rootless-docker/delegate-cgroups.sh` owns the idempotent delegation drop-in.
  Changed delegation can restart the user manager/daemon and affect jobs/apps.
- `build-runner/Dockerfile` builds `filius-builder:local`; jobs run as container
  UID 1001. `build-runner/runner-entrypoint.sh` registers and runs one job.
- `build-runner/run.sh` is the root-only launcher; `run-once.sh` is its
  compatibility shim. `--once` launches one removable Compose runner.
  `--all` uses foreground managed build supervision; `--service` reuses the
  existing background build unit. Both retain single-worker/eight-hour state.
  These explicit operator starts may wait for work; dispatch remains demand-only.
- `token-broker/` owns the host-only Unix token service. The launcher creates
  a five-minute root-authorized instance grant; image startup exchanges it
  once for a fresh registration token. Consume before GitHub calls, including
  failures; persist the ten-attempt/60-second global cooldown across restarts.
  Do not reset broker/worker state on setup reruns or log credential values.
- All runners mount only the broker socket directory read-only in addition to
  their role's existing mounts. No PAT, token ledger, privileged bootstrap or
  unmount capability enters the image. Jobs still run as UID 1001. Single-use
  authorization is an accidental-loop safeguard for trusted workflows, not an
  enterprise isolation mechanism or arbitrary URL/token-minting API.
- The image temporarily supports explicit legacy registration tokens for
  image-first upgrades; broker-authorized startups never fall back on failure.
- `orchestration-runner/run-once.sh` launches/stops the managed orchestration
  container. Its systemd unit uses root-owned runtime files installed beneath
  `/usr/local/lib/filius`, not mutable admin-owned checkout scripts.
- `/etc/filius/orchestration.env` contains only repository and host path/user
  settings, not token values. Unchanged setup reuses the services. Changed setup
  automatically pauses dispatch, stops orchestration/build supervision, safely
  drains managed build work, installs, and restarts required services. Do not
  restore manual-stop prerequisites or report deferred configuration as active.
  Orchestration restarts can cancel its own job; do not dispatch during setup.
- `deployment-runner/Dockerfile` extends the builder with Compose/rsync.
  Deployment bind mounts must use `/var/lib/filius-runner/deployments` (or its
  configured equivalent), mounted at the same path in container and daemon
  host. The ephemeral checkout is not a persistent daemon-visible host path.
- `compose.runners.yaml` separates orchestration/build/deployment roles.
  Match workflow labels to these roles. Labels guide routing; they are not
  security isolation against trusted workflows selecting default labels.
- `.github/workflows/build.yml` is a Docker smoke test.
  `.github/workflows/build-runner-image.yml` rebuilds both local images using an
  already available build runner. Neither runs on orchestration; the rebuild
  workflow does not install host runtime changes or discover new runner releases.
- `host-control/controller.py` is Python 3.8+ standard-library host logic.
  Install snapshots beneath `/usr/local/lib/filius`; root-owned eligibility
  remains authoritative. Requests cannot choose URLs, capacity or commands.
  Orchestration gets writable requests/read-only results and the read-only
  broker directory, not state, host code, PAT or Docker. Never write results through guest-controlled paths,
  follow request symlinks or source request payloads/service env as shell code.
- `/var/lib/filius-control` allows traversal only by root/the dedicated daemon
  group; its `state` directory is root-private. Locks serialize activation and
  supervision; durable state preserves idle budgets. Maintenance `pause` uses
  the installed service environment and existing idle/busy safety gate without
  launching replacements. Preserve enabled state and absolute idle deadlines;
  `resume` restarts only previously enabled supervision, not expired/new work.
  Stop the broker after draining, start/health-check it before new launches,
  and abort installation if a drain fails or a managed container remains live.
- Stopping build supervision leaves its launcher/container alone. The installed
  operator `host-control/drain.sh` waits for natural job completion or safely
  retires an idle listener. Do not use process-name kills, blind job timeouts or
  forced busy registration removal. Forced runner deletion follows verified
  idle container exit only.
- Runner versions remain pinned; startup warns about newer stable releases and
  ephemeral registration uses `--disableupdate`. Latest-stable setup/update
  resolution is future work, not an implemented feature.

## Credentials, privileges and isolation

Keep the host PAT outside the checkout, images and runner containers, normally
at `/etc/filius/github-token` with root-only permissions. Pass only a fresh
short-lived registration token at runner startup. Never put secrets in source,
image layers, logs, committed environment files or service configuration.
New launchers pass only an instance identifier in Compose environment; the
entrypoint fetches the short-lived token over the Unix socket before registration
and clears startup variables before running jobs.

Host registration/label management requires repository Administration read/write
for a fine-grained PAT; implemented queue discovery needs Actions read permission
for selected repositories. GitHub account changes, registration, workflow
dispatch and credential/permission changes require explicit user authorization.

Only build/deployment jobs receive the rootless socket. Keep the host endpoint
at `/run/user/<filius-runner-uid>/docker.sock`; do not substitute the host's
`/var/run/docker.sock` without an explicit security review. The conventional
`/var/run/docker.sock` container mount target still refers to that rootless
source. Relax socket mode only after verifying its host parent runtime directory
is private and owned by the runner account. Coordinate concurrent consumers
and restore the original mode after the last exits; crash/socket-replacement
recovery remains unfinished.

Rootless Docker and ephemeral jobs are not VM isolation. Build/deployment jobs
control the same daemon as applications. Run trusted workflows only. Keep
host discovery/launch control authenticated and constrained by installed
configuration; do not expose the PAT or arbitrary root execution to jobs.

## Editing and verification

- Keep root `setup.sh` the idempotent entry point that contains or orchestrates
  required host setup for future reference. Fail clearly on missing or
  incompatible prerequisites; preserve the current Ubuntu/Debian systemd target.
- Prefer small explicit scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
  Keep one-job behavior ephemeral and supervised retries bounded/backed off.
- Update README when installation, permissions, platforms or operations change.
  Keep STATE/BACKLOG consistent without presenting target work as implemented.
- Preserve unrelated worktree changes. Do not resurrect the discarded dashboard
  pool as the target design. Do not commit or push without a user request.
- Do not run tests, host setup, builds, containers, services or GitHub write operations
  unless the user authorizes the corresponding verification/execution scope.
  Authorization for local syntax/lint checks does not authorize host execution.
- Use available existing check tools. Do not treat macOS Bash 3.2 parsing as
  proof of Bash 4+ host behavior, or service active state as proof of online
  GitHub registration. State unavailable checks and unverified behavior plainly.
- Local mocked validation: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests`.
  This does not authorize real API calls, Docker, setup or services. The
  first-repo slice explicitly authorizes these local mocked/syntax checks only.
- Before suggesting host commands, distinguish root from `filius-runner` and
  identify effects on packages, accounts, services, jobs and applications.
