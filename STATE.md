# Current state

## Snapshot and verification boundary

This document describes source inspected at HEAD `4679a0a` (`fix setup user
group syntax`), including the pending staged changes listed below. Those changes
are not part of HEAD. There were no unstaged changes or untracked files before
adding `STATE.md` and `BACKLOG.md`.

This is a read-only source assessment, not verification of the server. No
scripts, tests, Docker builds, or host setup were run; no GitHub configuration
was changed. Actual runner availability, deployed applications, and Linux Mint
compatibility are unverified. Authenticated GitHub CLI access was unavailable;
the account type behind `https://github.com/WSiebelder` was not verified.

## Intended destination

The target is a headless Ubuntu-based Linux Mint server with an idempotent
root-level `setup.sh` that prepares the host, builds current stable Actions
runner images, and keeps an orchestration worker registered to this repository
available through boot-persistent host supervision.

The locked target uses repository-scoped registrations, not an organization
pool. The manually triggered `runner_dispatch` workflow here queries account
repositories for runnable queued jobs and starts workers only for eligible
repositories with matching demand. The configured repository list is an
allowlist, not a blanket startup list; configured counts cap worker capacity.
Existing workers are reused. The scan also starts the single deployment worker
registered here only when its central queue needs it. Workload workers
expire after eight continuous idle hours and remain stopped until manually
revived; active jobs are never killed by that idle limit. The orchestration
worker is exempt and is replaced after each ephemeral job. Discovery is
on-demand only; no periodic polling or continuously running scheduler is planned.
Jobs becoming ready after the scan need another dispatch unless an already
enabled matching worker can accept them.

Reusable build workflows should test proposed PR merge results, build/test
`master` after merges and produce repository-defined image names/versions.
Deployment requests execute centrally in this repository, globally serialized
on its single deployment worker, to update Compose applications on the same
machine. A reusable workflow called from another repository does not itself
transfer execution here. Requests can remain queued until manual revival.
Updating a Compose service's image reference remains the preferred direction;
release handoff and deployment details remain undecided.

These are goals, not completed features. See the locked target and B01-B11 in
[BACKLOG.md](BACKLOG.md); the original organization-wide proposal is superseded.

## Architecture in the current worktree

```text
root/admin: setup.sh
  -> rootless-docker/setup.sh + delegate-cgroups.sh
  -> filius-runner's rootless Docker daemon
  -> build-runner/build.sh -> filius-builder:local
  -> deployment-runner/build.sh -> filius-deployer:local

root/admin: manually start runner-pool.sh
  -> 2 build loops + 1 deployment loop, for one repository
  -> host PAT -> GitHub repository registration API -> fresh runner token
  -> docker compose run --rm -> ephemeral runner -> one matching job
  -> repeat with a new registration token

deployment job -> persistent Compose project -> same rootless daemon
```

The staged pool can run detached from its dashboard. This does not provide
boot-time supervision. The rootless Docker daemon has an enabled user service;
the runner pool does not.

### File responsibilities

References below describe the inspected worktree, including staged content.

| File / source location | Implemented responsibility |
| --- | --- |
| `setup.sh:10-32` | Requires root, Debian/Ubuntu-family identification, systemd and apt; installs missing curl/jq. |
| `setup.sh:34-82` | Prompts for a host PAT and one repository URL, persists them, and requests/discards a registration token to check access. Accepts `https://github.com/OWNER/REPOSITORY`, not an organization URL. |
| `setup.sh:84-138` | Runs rootless setup, builds both local images as `filius-runner`, checks Compose configuration/image existence, then prints a manual pool-start command. |
| `rootless-docker/setup.sh:23-44,70-106,120-153` | Manages the locked service account, deployment directory, rootless prerequisites and subordinate IDs; enables linger and Docker's user service. Docker CLI/Engine and matching rootless tooling remain prerequisites or conditional package installs. |
| `rootless-docker/delegate-cgroups.sh:19-49` | Idempotently writes the CPU/cpuset/I/O/memory/PID delegation drop-in. Changes can restart the user manager and its rootless daemon. |
| `build-runner/Dockerfile:1-39` | Ubuntu-based x64 runner image, pinned Actions runner `2.338.2`, container UID 1001, `docker-build` labels, ephemeral operation. |
| `build-runner/build.sh:1-7` | Builds `filius-builder:local`; does not discover the latest runner release. |
| `build-runner/runner-entrypoint.sh:4-35` | Warns about newer stable runner releases; registers with `--unattended`, `--disableupdate`, ephemeral mode and `--replace`, then runs the job listener. |
| `build-runner/run-once.sh:22-126` | Root-only one-job launcher: checks the rootless socket, coordinates socket permissions, requests a repository registration token, and launches a removable runner container. |
| `deployment-runner/Dockerfile:1-12` | Extends the builder with Compose v2 and rsync, retaining the non-root runner user and using `docker-deploy` labels. |
| `deployment-runner/build.sh:1-5`, `deployment-runner/run-once.sh:1-8` | Builds `filius-deployer:local` and selects deployment mode in the shared launcher. |
| `compose.runners.yaml:1-26` | Defines one-job runner containers and their socket/environment mounts; deploy runners also receive the persistent deployment directory. |
| `runner-pool.sh:5-7,25-193` | Staged host supervisor: fixed two-build/one-deploy worker list, retry loops, detached workers, PID checks, dashboard, and start/status/stop commands. |
| `.github/workflows/build.yml:3-39` | Push/manual Docker smoke test using `self-hosted` and `docker-build`; no PR trigger or application release pipeline. |
| `.github/workflows/build-runner-image.yml:3-34` | Push-on-input-change/manual rebuild of both local images using an already available build runner. Not automatic runner-release discovery or pool bootstrap. |
| `README.md`, `AGENTS.md` | Usage, architecture, operational constraints, and contributor guidance. The README deployment snippet is an example, not a shipped deployment workflow. |

### Identity, configuration and persistence

| Item | Current location or behavior |
| --- | --- |
| Host administrative work | `setup.sh`, pool management and one-job launchers run as root. They can install packages, change accounts/services, or start/stop workers. |
| Docker service identity | Locked `filius-runner`; default home `/var/lib/filius-runner`, mode 0700. Image builds during setup run as this user. |
| Runner container identity | UID 1001 (`runner`), distinct from host/rootless UID mapping. |
| Long-lived credential | `/etc/filius/github-token`, outside checkout and containers, mode 0600; current setup requests repository Administration read/write permission. Organization permissions are not implemented. |
| Saved target | `/etc/filius/repository-url`, one repository, mode 0600. Setup still prompts on reruns. |
| Registration credential | Fresh short-lived token requested by the host for each launch and passed at container startup; the host PAT is not mounted into the runner. |
| Host Docker endpoint | `/run/user/<filius-runner-uid>/docker.sock`; socket owner and private parent permissions are checked before temporary mode relaxation. |
| Container Docker endpoint | The rootless host socket is mounted at `/var/run/docker.sock` inside the runner. This does **not** mount the host rootful socket. |
| Job labels | Build: `self-hosted,linux,x64,docker-build`; deploy: `self-hosted,linux,x64,docker-deploy`. |
| Job workspace | `/home/runner/_work`, inside the removable runner; not a durable daemon-visible application bind-mount path. |
| Deployment projects | `/var/lib/filius-runner/deployments`, mounted at the same path in deploy runners. Setup leaves this directory mode 0777 behind the private parent, to accommodate container UID mapping. |
| Pool state/logs | `/var/lib/filius-runner/pool`, root-only directory containing worker PID/state/log files in the staged implementation. |

Source: `setup.sh:5-8,34-82`; `rootless-docker/setup.sh:23-44`;
`build-runner/Dockerfile:22-39`; `build-runner/run-once.sh:6-14,26-65,99-125`;
`compose.runners.yaml:1-26`; `runner-pool.sh:5-7,25-27,114-146`.

Deployment containers and named volumes can outlive a runner container in the
rootless daemon. They are not shown to be deployed by this repository.
Rootless port binding and host networking/exposure still need application-level
decisions.

## Pending staged changes

| File | Committed baseline | Pending staged behavior |
| --- | --- | --- |
| `runner-pool.sh` | Foreground loops for two build workers and one deployment worker, explicit repository URL, parent/child shutdown handling. | Detached `setsid` workers; saved URL default; PID identity checks; persisted worker state/logs; numbered dashboard; `start`, `status`, `stop`. Leaving with `q` leaves workers running; Ctrl-C during log following returns to the dashboard. |
| `build-runner/run-once.sh` | Each launcher saves/restores the socket mode independently. | Adds `flock` plus shared original-mode/reference-count state to coordinate overlapping launchers; last exiting participant attempts mode restoration. |
| `setup.sh` | Prints foreground pool-start/shutdown instructions. | Prints new `runner-pool.sh start` and dashboard/stop instructions. It still does not start workers. |
| `README.md` | Describes a foreground pool and Ctrl-C shutdown. | Documents detached workers, dashboard interaction, saved target, status/stop, and state/log directory. |

These changes are staged intent, not committed, tested, or verified on the
server. This documentation addition leaves them untouched.

## Gaps and operational caveats

- **Multi-repository orchestration absent:** all host launchers still use
  repository registration.
  GitHub [organization-level runners](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners)
  can serve organization repositories; repository-level runners serve one
  repository. A personal account does not automatically supply organization
  runner scope. The new target retains repository registration, with central
  configuration, per-repository builds and centrally executed deployments;
  no organization or repository migration is required. Owner URLs are
  configuration aids, not account-wide registration scopes. The supplied
  account's type is unresolved but no longer a blocker for this design.
  See B01, B11.
- **Incomplete unattended lifecycle:** Docker starts at boot, but runner workers
  require a separate manual start. There is no runner systemd service, capacity
  configuration, boot recovery, orchestration workflow or eight-hour idle expiry.
  See B03-B04, B11.
- **Not latest-version bootstrap:** image builds use the pinned runner version;
  startup only warns about updates. The self-hosted rebuild workflow requires
  a working runner and an input change/manual dispatch. See B05.
- **Concurrency concerns from inspection:** same-kind workers can produce the
  same hostname/second-based name (`build-runner/run-once.sh:99`) while runner
  registration uses `--replace` (`build-runner/runner-entrypoint.sh:32`). Starting an
  incomplete pool returns when any worker is alive, rather than repairing it;
  pool start/stop has no shared transition lock (`runner-pool.sh:125-157`).
  These are not reproduced failures. See B03.
- **Recovery boundaries:** socket reference-count correctness after forced
  termination or socket replacement, runner-container cleanup on cancellation,
  and stop completion are unverified. State/PID/log files and a dashboard are
  not implemented monitoring. See B03, B09-B10.
- **Shared privilege and resources:** both job types control the same rootless
  daemon. Labels do not isolate builds from deployed applications; ephemeral
  runners do not make untrusted jobs safe. Keep workflow code trusted, the PAT
  host-only, and the socket parent private. Cgroup-delegation changes can
  restart the daemon, affecting both jobs and applications. See B02-B04, B09.
- **Application delivery absent:** no reusable merge-result CI, master release
  naming/version contract, image publishing/handoff, or deployment workflow.
  Registry publishing and monitoring are future work. See B06-B09.
- **Validation absent:** no tracked automated test suite/lint configuration was
  found. Mint-specific prerequisites and repeated-setup/boot/job/deploy behavior
  need explicitly authorized host verification. See B10.
