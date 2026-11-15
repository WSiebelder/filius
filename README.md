# filius

Self-hosted GitHub Actions runner tools for finius. Setup builds local images and starts permanent orchestration. Manual dispatch discovers pending build work for `WSiebelder/filius` and starts/reuses one ephemeral-cycling build worker. All runners use finius's dedicated rootless Docker daemon; only build/deployment jobs receive its socket. Multi-repository scheduling, automated deployment, registry publishing and monitoring remain future work.

## How it works

1. `rootless-docker/setup.sh` creates the locked `filius-runner` Linux account, its private home, and the persistent deployment directory, then configures a rootless Docker daemon for it.
2. `build-runner/build.sh` builds `filius-builder:local`; `deployment-runner/build.sh` adds Docker Compose and builds `filius-deployer:local` on the same daemon.
3. `setup.sh` installs root-owned runtime, starts the local token broker and enables/starts `filius-orchestrator.service`. Each launch authorizes a one-shot startup grant; the container requests its short-lived registration token from the host broker. Orchestration repeats after jobs/failures and starts at boot.
4. Manual `dispatch_runner` writes an empty run/attempt-specific request. A systemd path/oneshot host service uses the host-only PAT to inspect queued jobs in queued and active runs. Only installed eligible targets and supported build labels qualify; no work is a successful no-op.
5. Matching work enables one managed build worker. It requests a fresh registration token per ephemeral runner and cycles after each job. Eight continuous idle hours trigger safety-gated retirement; busy/uncertain runners are left alone. Orchestration never expires.
6. The separate legacy `runner-pool.sh` starts two build workers and one deployment worker. Setup does not start it; do not run it alongside the managed build worker if you want a one-worker limit. Applications started by deployment jobs outlive the runner.

The orchestration runner has labels `self-hosted`, `linux`, `x64`, and `docker-orchestrate`, without `docker-build` or `docker-deploy`. Build/deployment runners use their corresponding labels with the same platform labels. The existing Docker smoke-test and runner-image rebuild workflows execute sequentially on the separate build worker, not orchestration.

`eligible-repositories.json` is an allowlist, not a startup list. This slice accepts only `https://github.com/WSiebelder/filius`, with capacity fixed at one. Other entries, duplicates, extra settings and a different control URL are rejected. Additional repositories/counts and central deployment dispatch remain backlog work.

`.github/workflows/build-runner-image.yml` rebuilds both images when their build inputs change; updated images are used by subsequent runner launches. It does not update the root-owned host runtime installed by setup.

## Requirements

- A Debian or Ubuntu server using systemd, with Docker Engine installed.
- Bash 4 or newer on the host (standard on supported Ubuntu/Debian releases).
- The rootless Docker setup tool that matches the installed Docker Engine. The setup script installs common prerequisites and attempts to install `docker-ce-rootless-extras` if the tool is missing.
- `curl`, `jq`, Python 3.8+, `timeout` and `flock` on finius. Setup installs missing curl/jq/Python; Python host logic uses only the standard library.
- A private GitHub repository for the runner to serve. Only run trusted workflows on a self-hosted runner.

Host launchers use the rootless daemon socket rather than the host's `/var/run/docker.sock`. Before mounting it into a build/deployment container, `build-runner/run.sh` coordinates temporary socket accessibility and restoration across active consumers. Orchestration does not mount the Docker socket or relax its mode. The socket remains under systemd's private `/run/user/<UID>` directory on the host. Rootless Docker is not a VM: jobs share finius's kernel and resources. Runner labels guide job selection, not isolation from trusted workflows intentionally using default self-hosted labels. Docker documents [rootless mode](https://docs.docker.com/engine/security/rootless/) and its [security model](https://docs.docker.com/engine/security/).

The deployment runner controls only this rootless daemon, so its containers are separate from anything started by finius's rootful Docker daemon. Rootless Docker also restricts binding privileged ports such as 80 and 443; publish an unprivileged host port (for example, 8080) and route traffic to it separately if needed. See [Docker's rootless mode](https://docs.docker.com/engine/security/rootless/).

## Install on finius

Clone this repository somewhere readable by your normal admin account, for example `/opt/filius`. Keep the Git checkout and application source owned by that account.

Run the top-level installer as root from the checkout. It can install host packages, change accounts/services, build images and register a GitHub runner:

```sh
cd /opt/filius
sudo ./setup.sh
```

The installer checks prerequisites, then prompts for a fine-grained PAT if `/etc/filius/github-token` does not exist yet. Select `WSiebelder/filius` and grant **Repository permissions → Administration: Read and write** (registration/label management) and **Actions: Read** (run/job discovery). Existing PATs need the additional Actions permission. The token owner must administer the repository. Temporary runner registration tokens expire after one hour. See [GitHub's self-hosted runner API](https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-registration-token-for-a-repository).

Select `https://github.com/WSiebelder/filius`, not an account/organization URL. It is saved in `/etc/filius/repository-url` and offered on reruns. This first-use-case implementation rejects other control repositories.

The PAT stays outside the checkout with root-only permissions. Setup checks registration and Actions access, prepares rootless Docker, builds both images, installs the runtime and enables/starts the token broker, orchestration and request path. It enables build supervision for boot recovery and resumes previously enabled build work after upgrades. It does not enable new work: never-enabled/expired workers stay disabled, and existing idle deadlines are retained.

Services execute root-owned runtime snapshots under `/usr/local/lib/filius`, not mutable checkout scripts. `/etc/filius/orchestration.env` and installed eligibility are mode 0600; neither contains tokens. `/var/lib/filius-control/state` is root-private and holds locks, lifecycle and broker guard state. Its parent permits traversal only by root and the dedicated daemon account. Orchestration mounts requests writable, results read-only, and the token-broker directory read-only; it gets no PAT, host scripts, deployment files or Docker socket. Scan requests cannot choose URLs, capacity or commands.

### One-shot host token broker

`token-broker/` contains the Python standard-library broker and its
`filius-token-broker.service`. It listens only on
`/var/lib/filius-control/token-broker/broker.sock`, mounted into runners as
`/filius-token/broker.sock`; there is no TCP endpoint.

The root launcher preauthorizes a random runner instance for the installed
repository, name and role. `runner-token.sh`, included in the image, exchanges
that instance for a registration token once at startup. The broker reads the
host PAT; neither the PAT nor the registration token is put in the new Compose
container environment. Only the instance identifier is passed there.

Each startup grant expires after five minutes and is consumed **before**
contacting GitHub, even if the request fails or its response is lost. No
automatic client retry occurs. The host launcher revokes the grant when its
container exits. Failed startup needs a fresh launch, not a second request from
the same container. A persisted limit of ten GitHub registration attempts per
60 seconds, shared across launches/roles, curbs accidental restart loops.
Restarting the broker or rerunning setup does not reset that counter.

The socket stays mounted; no unmount privileges, certificates or privileged
bootstrap are required. This is a practical loop guard for trusted workflows,
not isolation from jobs that already control the shared Docker daemon.

For image-first upgrades only, the entrypoint still accepts a legacy
`RUNNER_TOKEN` when no broker instance was supplied and emits a warning. A
broker-authorized startup never falls back to an inherited token on failure.
Install the host runtime to use the one-shot guard; rebuilding the image alone
does not enable it.

### Runner command modes

After installation, run these as **root**; they can register/start workers:

```sh
sudo bash /opt/filius/build-runner/run.sh --once https://github.com/WSiebelder/filius
sudo bash /opt/filius/build-runner/run.sh --all https://github.com/WSiebelder/filius
sudo bash /opt/filius/build-runner/run.sh --service https://github.com/WSiebelder/filius
```

| Mode | Behavior |
| --- | --- |
| `--once` | Wait for/run one job in a fresh removable Compose container, then exit. |
| `--all` | Run the managed build worker in the foreground, cycling fresh containers until eight continuous idle hours; Ctrl-C begins a drain rather than cancelling the active job. |
| `--service` | Enable/start or reuse the same installed build worker in the background through `filius-build-worker.service`. |

`--all`/`--service` are explicit operator starts: they can wait for work even if
none is queued. They share the installed one-worker state and eight-hour idle
policy; they do not create a second pool. `--all` refuses an already active
supervisor. Manual dispatch remains demand-only. `--once` is a separate manual
one-job launch, so avoid combining it/the legacy pool with managed supervision
when expecting capacity one. All broker-backed modes currently require this
installed eligible repository.

`--service` deliberately reuses host lifecycle supervision, not a Compose
restart policy: restarting the same container would reuse its consumed startup
grant and filesystem. The token broker replaces host-side token injection, not
the existing idle/drain machinery. No persistent multi-job runner is introduced.
`build-runner/run-once.sh` remains a compatibility wrapper for `run.sh --once`.

The runner version is pinned in `build-runner/Dockerfile`, and self-updates are disabled so an ephemeral runner does not replace its registration while processing its one job. At startup, the container checks GitHub's latest stable release and warns if its baked-in version is older. Update `RUNNER_VERSION` and rebuild the image regularly; GitHub stops assigning jobs to runners that have not been updated within its supported update window. See [GitHub's runner update guidance](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).

The rootless Docker setup creates `filius-runner`, adds subordinate UID/GID ranges if needed, delegates the CPU, cpuset, I/O, memory, and PID cgroup controllers to that user's systemd manager, enables the daemon at boot, and leaves the host's existing Docker daemon running. If the delegation drop-in changes, setup restarts the `filius-runner` user manager and its rootless Docker daemon, affecting applications too. Changed rootless setup inputs trigger managed build draining first. Stop unmanaged runners and schedule application downtime before delegation repairs; invoking `rootless-docker/setup.sh` directly bypasses the top-level maintenance transition. The built image is available only in the rootless daemon, not in finius's rootful Docker daemon. Resource-controller warnings can remain if the host does not use unified cgroup v2 or lacks those controllers.

### First use case: build this repository on demand

These read-only status/log commands run as root on finius:

```sh
sudo systemctl status filius-orchestrator.service --no-pager
sudo journalctl -u filius-orchestrator.service -f
```

A running service is not proof of successful GitHub registration: confirm `Listening for Jobs` in the journal and an online `docker-orchestrate` runner under this repository's **Settings → Actions → Runners**.

Commit/push the changes yourself so `dispatch_runner.yml` is on the default branch. Update the server checkout as your normal admin account, and install the new runtime as root; push alone does not upgrade installed host files. Setup automatically stops/replaces existing services, including upgrades from the HelloWorld installation:

```sh
sudo /opt/filius/setup.sh
```

Once orchestration is online and build workflows are queued, open **Actions → Dispatch runner → Run workflow**. It waits up to eight minutes for a host result: `enabled`, `reused`, or `no-op`, with a queued-job count. `enabled` confirms a start request, not online registration; check the build journal and GitHub runner status. API/host failures fail dispatch rather than masquerading as an empty queue.

The worker handles `.github/workflows/build.yml` and `build-runner-image.yml` sequentially. No push/schedule trigger starts workers; later-ready jobs require another manual dispatch unless an enabled worker is available. Discovery reads only this eligible repository, not unrelated account repositories.

Read-only host diagnostics (root):

```sh
sudo systemctl status filius-dispatch.path filius-build-worker.service --no-pager
sudo journalctl -u filius-dispatch.service -u filius-build-worker.service -f
```

Confirm `Listening for Jobs` and an online `docker-build` runner. Worker state retains the idle deadline across supervisor restart/ordinary idle failure; a completed job gets a fresh token/idle period. A missing runner with an already elapsed idle budget stays expired until dispatch revives it.

Expiry first removes `docker-build`, waits at least 60 seconds, and rechecks GitHub busy/label state plus local job output before stopping only the managed container. Busy jobs, including long jobs, finish naturally. API/readiness uncertainty defers retirement, so the eight-hour limit can be exceeded safely. Forced registration deletion is attempted only after the idle container has exited. Failed cleanup can leave a quarantined/offline registration requiring operator review.

**Verification limit:** mocked tests do not prove Linux/systemd integration or atomic GitHub assignment/drain behavior. Label removal plus observation is not a documented atomic drain API. Validate near-deadline job pickup on the target host before relying on unattended expiry. Rootless/socket crash recovery and result/quarantine retention are still backlog work.

### Update an installed dispatch runtime

Update the checkout as your normal admin account, then run setup as **root**. It can change packages/accounts/services and rebuild images; no separate service-stop commands are needed:

```sh
sudo /opt/filius/setup.sh
```

When runtime, installed settings or rootless setup inputs differ, setup pauses dispatch, waits for an in-flight host scan, stops orchestration/build supervision, and drains managed build work. Busy build jobs finish naturally; idle listeners use the existing label quarantine and busy checks. Setup waits rather than force-stopping uncertain/busy work. The broker stops only after draining. New runtime is installed, systemd reloaded, and the broker health-checked before orchestration/request handling and previously enabled build supervision resume. The original idle deadline is preserved; expired/never-enabled workers remain disabled.

Unchanged runtime/settings reuse running services and persisted state; broker grants/cooldowns are never reset by installation. Missing units on older installations need no manual handling. If installation fails, services may remain paused: fix the reported error and rerun setup. Drain progress is available through this read-only command as root:

```sh
sudo journalctl -u filius-setup-drain.service -f
```

Stop any foreground `--all` worker with Ctrl-C and let its drain finish first; setup does not kill a separately owned foreground process. Separate `--once` launches and the legacy pool are not managed by the upgrade drain. The operator `host-control/drain.sh` remains available for deliberately disabling a worker; unlike maintenance pause, it does not preserve enablement.

**Do not dispatch during setup:** stopping orchestration can cancel its own active workflow. Cgroup-delegation repairs can restart the daemon and affect deployed applications; schedule those separately. `sudo systemctl restart filius-orchestrator.service` restarts only installed runtime, not checkout changes. Actual Linux/systemd upgrade operation still requires target-host verification.

### Start the legacy runner pool manually

For legacy/manual operation instead of the managed worker, start the pool as root on finius. This registers runners and starts containers:

```sh
sudo /opt/filius/runner-pool.sh https://github.com/OWNER/REPOSITORY
```

This foreground host script keeps two build workers and one deployment worker available indefinitely, not only when work is pending; it has no eight-hour idle expiry or boot-enabled service. Pass the repository URL explicitly. Each worker requests a fresh registration token for every job. Press Ctrl-C to stop the pool; logs appear in its terminal output.

The example workflow targets `runs-on: [self-hosted, docker-build]`. A workflow with different labels will remain queued until a matching runner is available. See [GitHub's runner selection docs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).

### Deploy one job

To launch one ephemeral deployment runner instead of the pool, run as root (registers a runner and starts its container):

```sh
sudo /opt/filius/deployment-runner/run-once.sh https://github.com/OWNER/REPOSITORY
```

The workflow must target `runs-on: [self-hosted, docker-deploy]`. It can use `docker run` or `docker compose`. To let Compose use bind mounts, keep the Compose project under the persistent `FILIUS_DEPLOYMENTS_DIR` mounted at the same path on finius and in the runner. The runner workspace is temporary and is not a valid host path for Compose bind mounts.

For example, a trusted deployment workflow can stage a project from its checkout and bring it up:

```yaml
on:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  deploy:
    runs-on: [self-hosted, docker-deploy]
    steps:
      - uses: actions/checkout@v7
      - name: Stage compose project
        run: |
          mkdir -p "$FILIUS_DEPLOYMENTS_DIR/myapp"
          rsync -a --delete deploy/ "$FILIUS_DEPLOYMENTS_DIR/myapp/"
      - name: Deploy
        run: docker compose -p myapp -f "$FILIUS_DEPLOYMENTS_DIR/myapp/compose.yaml" up -d --remove-orphans
```

The persistent deployment directory is writable by the deployment job and private on the host under `/var/lib/filius-runner`. Treat deployment workflows as trusted code. Named volumes remain in the rootless Docker daemon after the one-job runner exits.

## Using more repositories

The installed dispatch and broker currently support only this repository.
Adding allowlist entries is rejected until multi-repository support is
implemented. Manual launchers now use the same installed broker eligibility.
A personal account has no account-wide shared runner registration.
Organization-scoped sharing is a separate GitHub feature, not required here.

## Troubleshooting

- **Rootless Docker socket missing:** rerun `sudo ./rootless-docker/setup.sh`; check the printed systemd status command and the `filius-runner` user service.
- **Runner image not found:** build it with the rootless daemon as shown above. Images in the rootful daemon are not visible to rootless Docker.
- **GitHub API returns 403:** confirm repository access, **Administration: Read and write**, **Actions: Read**, token expiration and API rate limits. Errors never authorize launches or destructive expiry.
- **Token startup fails/409/429:** inspect `sudo journalctl -u filius-token-broker.service --no-pager` as root. A grant is single-use even after failure; use a fresh launch. Repeated launches share the ten-attempt/60-second cooldown; wait rather than restarting the broker. These logs do not include token values.
- **Job stays queued:** check that the runner is online and that the workflow's `runs-on` labels include `self-hosted` and `docker-build`.
- **Dispatch stays queued:** check orchestration and its online `docker-orchestrate` runner; a `docker-build` runner cannot accept dispatch.
- **Dispatch reports missing `/filius-control` directories:** it failed before host queue discovery. The orchestration container lacks the installed control mounts, usually because the server still uses the older runtime snapshot. Update the server checkout and follow the installation/upgrade procedure above; a push or image rebuild alone does not install the host Compose snapshot. Do not create directories inside the container: they would not connect to the host request service.
- **Dispatch times out:** verify that checkout changes were installed on the host; inspect `filius-dispatch.path/service`. Excess requests can trip the systemd start limit; investigate before a root `systemctl reset-failed filius-dispatch.path filius-dispatch.service` and `systemctl start filius-dispatch.path` (changes service state).
- **Orchestration keeps restarting:** inspect its journal for unavailable rootless Docker, PAT/registration failures, or a conflicting container. Setup's service-state check alone does not verify registration.
- **Build runner waits without a job:** expected until its idle deadline; managed expiry may defer when GitHub/local observations are uncertain. Legacy launchers have no idle limit.
- **Compose bind mount path not found:** use a path beneath `FILIUS_DEPLOYMENTS_DIR`; paths in the runner's temporary checkout are not visible to the rootless daemon on finius.

## Repository layout

```text
rootless-docker/setup.sh       Host account and rootless Docker setup
rootless-docker/delegate-cgroups.sh  Idempotent systemd cgroup delegation
setup.sh                      Install images, orchestration and demand controls
eligible-repositories.json    Single-repository eligibility, not automatic startup
host-control/controller.py   Host-only discovery, requests, worker state and expiry
host-control/drain.sh         Operator drain via installed systemd environment
host-control/filius-dispatch.path  Manual request activation
host-control/filius-dispatch.service  Serialized host queue scan
host-control/filius-build-worker.service  Demand-enabled build supervision
orchestration-runner/run-once.sh  Launch/stop the managed orchestration container
orchestration-runner/filius-orchestrator.service  Boot-persistent worker supervision
build-runner/Dockerfile        GitHub Actions runner image
build-runner/runner-entrypoint.sh  Runner registration and execution
build-runner/build.sh          Build the runner image
build-runner/run-once.sh       Compatibility wrapper for run.sh --once
build-runner/run.sh            --once, --all and --service host launcher
build-runner/runner-token.sh   Startup client for the local one-shot token broker
token-broker/broker.py         Host token service and root-only grant management
token-broker/filius-token-broker.service  Boot-persistent local broker
deployment-runner/Dockerfile   Runner image with Docker Compose
deployment-runner/build.sh     Build the deployment runner image
deployment-runner/run-once.sh  Start one ephemeral deployment job
.github/workflows/build.yml    Runner smoke-test workflow
.github/workflows/dispatch_runner.yml  Manual scan request and bounded reporting
.github/workflows/build-runner-image.yml  Rebuild runner image when its inputs change
compose.runners.yaml           Compose definitions for one-job runner containers
runner-pool.sh                 Legacy manual 2-build/1-deploy supervisor
tests/test_host_control.py     Local mocked standard-library behavior tests
```
