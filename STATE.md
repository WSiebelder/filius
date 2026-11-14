# Current state

## Snapshot and verification boundary

Baseline for this slice is `b943a5d` (`update the design parameters`). The
worktree now implements this repository as the first eligible, demand-driven
build target. These changes are intentionally uncommitted: the user will
commit/push and install the runtime on the server.

This describes source, not verified server operation. Local standard-library
mocked tests cover discovery, request isolation, singleton activation, restart
state, idle expiry and operator drain. Shell/YAML/embedded workflow syntax and
diff whitespace are checked locally. No real GitHub requests, Docker operations,
host setup, services, workflow execution or account changes were performed.
macOS Bash 3.2 parsing is not Bash 4+ Linux runtime verification. ShellCheck,
actionlint and newer Bash were unavailable.

Linux Mint/systemd integration, online registration, actual build pickup,
reboot recovery and near-deadline assignment/drain behavior remain unverified.
Mocks do not establish an atomic GitHub drain guarantee.

## Implemented first-repository path

- Root `setup.sh` prepares the dedicated rootless daemon, builds the pinned
  runner images and installs root-owned runtime/configuration/systemd units.
  It starts permanent orchestration and request handling, not workload workers.
- `eligible-repositories.json` lists only `https://github.com/WSiebelder/filius`.
  Capacity is fixed at one managed build worker. Other repositories, duplicates,
  extra settings and a different control URL fail validation.
- Manual-only `dispatch_runner.yml` runs on `docker-orchestrate`. It writes an
  empty run/attempt-specific request and waits up to eight minutes for its
  read-only result. No account token or Docker access is given to orchestration.
- `filius-dispatch.path` activates a serialized host scan. The host-only PAT
  reads queued and active runs and their current-attempt jobs, with bounded API
  requests and pagination. Resolved queued jobs requiring `self-hosted` and
  `docker-build`, with no unsupported labels, qualify. Waiting runs, unresolved
  labels, cancelled/completed work and other roles do not.
- Matching demand enables/reuses one `filius-build-worker.service`; no demand
  is a successful no-op. Activation is serialized and demand is rechecked
  before enabling absent capacity. `enabled`/`reused` acknowledge host activation,
  not proof of online registration. API failures fail the request.
- Build supervision launches fresh, collision-resistant one-job runners using
  the existing shared launcher and a fresh registration token on every cycle.
  The smoke test and image rebuild workflows keep their existing triggers and
  `docker-build` labels and can run sequentially.
- Persistent enabled state, managed identity, job evidence and idle deadline
  survive ordinary supervisor restart. Restart adopts an existing live managed
  container rather than replacing it. Eight hours of continuous idle triggers
  retirement; missing capacity whose idle budget already elapsed is disabled
  without launching a replacement. Setup/reboot does not revive expired or
  never-enabled workers. Manual demand can renew an overdue/quarantined listener.
- Idle retirement removes `docker-build`, waits at least 60 seconds, then
  rechecks busy/label state and local job output before targeted container stop.
  A racing/busy job is allowed to finish; API/readiness uncertainty defers
  cleanup. The registration is force-deleted only after the idle container
  exited. Cleanup failure can leave a quarantined/offline registration.
- Operator drain supports installation updates: stopping build supervision
  leaves the shared launcher/container running; drain waits for a busy job or
  uses the same idle safety gate, then disables the worker without replacements.

The eight-hour deadline is a safety-first goal, not justification to kill
uncertain work. GitHub label removal and subsequent observations are not a
documented atomic drain operation; live assignment races need target-host
acceptance. Default-label workflows can bypass role labels, so only trusted,
explicitly role-labelled workflows belong here.

## Architecture and isolation

```text
root setup -> rootless account/daemon + images + installed runtime
  -> boot-persistent filius-orchestrator.service
     -> fresh token -> one socket-free docker-orchestrate runner
     -> manual dispatch writes request, reads result, exits
  -> filius-dispatch.path -> host-only filius-dispatch.service
     -> installed allowlist + host PAT -> this repository's runs/jobs
     -> no-op / reuse / enable one build worker -> non-secret result
  -> demand-enabled filius-build-worker.service
     -> fresh token -> docker-build runner -> one job -> replacement
     -> continuous idle deadline -> label quarantine -> safe retirement

legacy/manual pool -> 2 build loops + 1 deploy loop for an explicit repository
deployment job -> persistent Compose project -> same rootless daemon
```

| Item | Location or behavior |
| --- | --- |
| Host administrative identity | Root installs/manages runtime and registration; image builds run as `filius-runner`, jobs as container UID 1001. |
| Daemon account | Locked `filius-runner`, private `/var/lib/filius-runner` home. |
| PAT | `/etc/filius/github-token`, root-owned mode 0600; fine-grained repository Administration read/write and Actions read. Never mounted/passed to jobs. |
| Saved control URL | `/etc/filius/repository-url`; changing it alone does not update installed runtime. |
| Installed configuration | `/etc/filius/orchestration.env` and `/etc/filius/eligible-repositories.json`, root-owned mode 0600, no token values. |
| Installed runtime | `/usr/local/lib/filius`; systemd units/drop-ins under `/etc/systemd/system`. Active runtime or a live managed build container prevents changed installation. |
| Control parent | `/var/lib/filius-control`, root-owned, mode 0710 with dedicated daemon group traversal; no other-user access. |
| Requests/results | Separate root-owned directories; requests mode 1733 accommodates mapped job UID; results mode 0755 with read-only container bind mount and host-written summaries. |
| Lifecycle/locks | `/var/lib/filius-control/state`, root-private mode 0700, atomic durable JSON and file locks. Invalid request directories are quarantined here without traversing contents. |
| Host Docker socket | `/run/user/<filius-runner-uid>/docker.sock`, never the rootful host socket. |
| Container Docker socket | Only build/deploy mount that rootless source at container `/var/run/docker.sock`. Orchestration gets only request/result mounts. |
| Deployment projects | `/var/lib/filius-runner/deployments`, same path in deployment container and daemon host. No shipped automated deployment workflow. |

Root-owned installed configuration is authoritative. Request names/payloads
cannot select URLs, capacity, credentials or executables. Symlinks/nonempty
requests fail; invalid filenames are consumed without scanning. Results use
separate host-owned paths and run/attempt identifiers, preventing guest-directed
privileged writes or stale-attempt results. Each service activation consumes
one request; `DirectoryNotEmpty` retriggers for requests arriving during scans.
Systemd start limits bound request floods; workflow timeout reports a blocked
or failed bridge.

Build/deploy jobs control the same daemon as applications. Rootless/ephemeral
runners are not VM isolation. Shared launcher socket permissions are relaxed
only behind the verified private runtime parent and restored after the last
normal consumer exits. Forced termination/socket replacement recovery remains
unfinished. Cgroup-delegation changes during setup can restart the user manager
and daemon, affecting jobs/apps.

## Pending worktree changes

| Files | Change |
| --- | --- |
| `eligible-repositories.json` | First eligible target, one-worker boundary enforced by host logic. |
| `host-control/controller.py`, `host-control/*.service`, `host-control/*.path`, `host-control/drain.sh` | Constrained request processing, GitHub discovery, persisted build supervision/expiry and operator drain. |
| `setup.sh` | Python prerequisite, eligibility/Actions checks, root-owned runtime/control installation, active-update guards, path/orchestration enablement and workload boot recovery. |
| `compose.runners.yaml` | Narrow writable request and read-only result mounts for orchestration; existing build/deploy socket/mount behavior retained. |
| `.github/workflows/dispatch_runner.yml` | Replaces HelloWorld with manual request/bounded result reporting; no push/schedule trigger or extra token permissions. |
| `tests/test_host_control.py` | Focused mocked tests; no live API/Docker/systemd access. |
| `README.md`, `STATE.md`, `BACKLOG.md`, `AGENTS.md` | Current implementation, installation sequence, safety constraints and remaining scope. |

`runner-pool.sh`, the two build workflows, runner images/entrypoint and shared
launcher are unchanged in this slice. Do not combine the managed worker with
the legacy fixed pool if expecting capacity one.

## History and remaining destination

Initial assessment inspected `4679a0a` and four staged changes. Documentation
was committed at `bff793e`; orchestration/HelloWorld and shared launcher support
were committed at `f6d79c4`. The unrelated detached dashboard/pool rewrite and
matching README edits were discarded at the user's request. `b943a5d` committed
the revised design documentation. This slice builds on that clean baseline.

Remaining goals include general eligible repository/capacity configuration,
one centrally executed deployment worker, release submission/authorization,
reusable PR merge-result and master CI, immutable image handoff, Compose update/
health/rollback, latest-stable runner selection, resource limits, retention and
monitoring. Personal-account repositories continue to use repository-scoped
registration; no organization or account-wide runner scope is required.

The image remains pinned to runner `2.338.2`; startup only warns about newer
stable versions and uses `--disableupdate`. The self-hosted image rebuild
workflow needs a healthy build runner, so root setup/manual rebuild is still
the independent recovery path. See [BACKLOG.md](BACKLOG.md), especially B03,
B05, B09-B11, for incomplete recovery, live acceptance and delivery work.
