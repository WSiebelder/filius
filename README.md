# filius

Self-hosted GitHub Actions runner tools for finius. Setup builds the build/deployment runner images and starts one systemd-supervised orchestration worker for this repository. All runner containers are launched on finius's dedicated rootless Docker daemon; only build/deployment jobs receive its socket. Registry publishing, queue discovery and monitoring are future work.

## How it works

1. `rootless-docker/setup.sh` creates the locked `filius-runner` Linux account, its private home, and the persistent deployment directory, then configures a rootless Docker daemon for it.
2. `build-runner/build.sh` builds `filius-builder:local`; `deployment-runner/build.sh` adds Docker Compose and builds `filius-deployer:local` on the same daemon.
3. `setup.sh` installs a root-owned orchestration runtime and enables/starts `filius-orchestrator.service`. Each service cycle uses the host-only PAT to request a fresh, short-lived registration token, then starts one ephemeral orchestration runner. The service repeats after each job or failure and starts at boot.
4. Each runner waits for one matching job, executes it, deregisters, and exits. Compose removes its container afterward. The orchestration container receives neither a Docker socket nor the deployment directory.
5. The separate manual `runner-pool.sh` starts two build workers and one deployment worker. Setup does not start this legacy pool. Containers started by a deployment job remain running in the rootless daemon.

The orchestration runner has labels `self-hosted`, `linux`, `x64`, and `docker-orchestrate`, without `docker-build` or `docker-deploy`. The build runner uses `docker-build`; the deployment runner uses `docker-deploy`, with the same default platform labels. `.github/workflows/dispatch_runner.yml` manually prints `HelloWorld` on orchestration. The existing Docker smoke-test and runner-image rebuild workflows still require a separately started build runner; orchestration does not execute them.

`.github/workflows/build-runner-image.yml` rebuilds both images when their build inputs change; updated images are used by subsequent runner launches. It does not update the root-owned host runtime installed by setup.

## Requirements

- A Debian or Ubuntu server using systemd, with Docker Engine installed.
- Bash 4 or newer on the host (standard on supported Ubuntu/Debian releases).
- The rootless Docker setup tool that matches the installed Docker Engine. The setup script installs common prerequisites and attempts to install `docker-ce-rootless-extras` if the tool is missing.
- `curl`, `jq` and `timeout` on finius; the manual build/deployment launchers also require `flock`.
- A private GitHub repository for the runner to serve. Only run trusted workflows on a self-hosted runner.

Host launchers use the rootless daemon socket rather than the host's `/var/run/docker.sock`. Before mounting it into a build/deployment container, `run-once.sh` coordinates temporary socket accessibility and restoration across active consumers. Orchestration does not mount it or relax its mode. The socket remains under systemd's private `/run/user/<UID>` directory on the host. Rootless Docker is not a VM: jobs share finius's kernel and resources. Runner labels guide job selection, not isolation from trusted workflows intentionally using default self-hosted labels. Docker documents [rootless mode](https://docs.docker.com/engine/security/rootless/) and its [security model](https://docs.docker.com/engine/security/).

The deployment runner controls only this rootless daemon, so its containers are separate from anything started by finius's rootful Docker daemon. Rootless Docker also restricts binding privileged ports such as 80 and 443; publish an unprivileged host port (for example, 8080) and route traffic to it separately if needed. See [Docker's rootless mode](https://docs.docker.com/engine/security/rootless/).

## Install on finius

Clone this repository somewhere readable by your normal admin account, for example `/opt/filius`. Keep the Git checkout and application source owned by that account.

Run the top-level installer as root from the checkout. It can install host packages, change accounts/services, build images and register a GitHub runner:

```sh
cd /opt/filius
sudo ./setup.sh
```

The installer checks for `curl` and `jq`, then prompts for a fine-grained PAT if `/etc/filius/github-token` does not exist yet. Create a PAT for the repository that will use the runner, with **Repository permissions → Administration: Read and write**. The account creating the token must be an administrator of that repository. GitHub requires this permission for the API that creates runner registration tokens; those temporary registration tokens expire after one hour. See [GitHub's self-hosted runner API](https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-registration-token-for-a-repository).

Select this control repository's URL, such as `https://github.com/WSiebelder/filius`, not an account/organization URL. It is saved in `/etc/filius/repository-url`. On later setup runs, it appears as the prompt default; press Enter to keep it or enter a different control repository URL.

The PAT stays outside the checkout with root-only permissions. Setup checks GitHub access, prepares rootless Docker, builds `filius-builder:local` and `filius-deployer:local`, installs the orchestration service, and enables/starts it. It does not dispatch a workflow or start workload runners.

The service executes root-owned copies of its launcher and Compose configuration under `/usr/local/lib/filius`, not scripts from the admin-owned checkout. `/etc/filius/orchestration.env` stores the control repository URL and host paths/user settings with mode 0600; it contains no PAT value or registration token. Changing the saved legacy repository URL alone does not retarget the installed service.

The runner version is pinned in `build-runner/Dockerfile`, and self-updates are disabled so an ephemeral runner does not replace its registration while processing its one job. At startup, the container checks GitHub's latest stable release and warns if its baked-in version is older. Update `RUNNER_VERSION` and rebuild the image regularly; GitHub stops assigning jobs to runners that have not been updated within its supported update window. See [GitHub's runner update guidance](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).

The rootless Docker setup creates `filius-runner`, adds subordinate UID/GID ranges if needed, delegates the CPU, cpuset, I/O, memory, and PID cgroup controllers to that user's systemd manager, enables the daemon at boot, and leaves the host's existing Docker daemon running. If the delegation drop-in changes, the setup restarts the `filius-runner` user manager and its rootless Docker daemon; run it only when no runner job is active. The built image is available only in the rootless daemon, not in finius's rootful Docker daemon. Resource-controller warnings can remain if the host does not use unified cgroup v2 or lacks those controllers.

### Run the HelloWorld orchestration placeholder

These read-only status/log commands run as root on finius:

```sh
sudo systemctl status filius-orchestrator.service --no-pager
sudo journalctl -u filius-orchestrator.service -f
```

A running service is not proof of successful GitHub registration: confirm `Listening for Jobs` in the journal and an online `docker-orchestrate` runner under this repository's **Settings → Actions → Runners**.

Once `dispatch_runner.yml` exists on GitHub's default branch, open **Actions → Dispatch runner → Run workflow**. Its only step prints `HelloWorld`; it does not discover queued jobs, revive other runners or deploy anything. After that one job, systemd requests a new token and replaces the ephemeral runner. Orchestration has no eight-hour idle limit. Those workload controls remain in [BACKLOG.md](BACKLOG.md).

Unchanged setup reruns reuse the service. If runtime/configuration changes are detected while it is active, setup refuses to overwrite them and explains the explicit update procedure. When no orchestration job is active, run the following as root; stopping the service can cancel its job, and rerunning setup can change host packages/accounts/services and rebuild images:

```sh
sudo systemctl stop filius-orchestrator.service
sudo /opt/filius/setup.sh
```

To restart the already installed runtime, use `sudo systemctl restart filius-orchestrator.service`; this changes service/job state but does not install checkout changes. Stop/recovery targets only the managed `filius-orchestrator` container, not deployed applications. Existing rootless setup may still restart the daemon when cgroup delegation changes; schedule setup with no active jobs.

### Start the legacy runner pool manually

If build/deployment jobs are needed before on-demand orchestration is implemented, start the legacy pool as root on finius. This starts runner containers and registers them with GitHub:

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

`run-once.sh` registers against one repository URL at a time. The fine-grained PAT must include that repository and have **Administration: Read and write** permission. For repositories under your personal account, run a one-job runner for each repository. To share runners across multiple repositories, GitHub supports organization-level runners for repositories in an organization; this setup script currently uses repository-level registration. See [GitHub's runner concepts](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners).

## Troubleshooting

- **Rootless Docker socket missing:** rerun `sudo ./rootless-docker/setup.sh`; check the printed systemd status command and the `filius-runner` user service.
- **Runner image not found:** build it with the rootless daemon as shown above. Images in the rootful daemon are not visible to rootless Docker.
- **GitHub API returns 403:** confirm the PAT is fine-grained, includes this repository, has **Administration: Read and write**, and belongs to a repository administrator.
- **Job stays queued:** check that the runner is online and that the workflow's `runs-on` labels include `self-hosted` and `docker-build`.
- **HelloWorld stays queued:** check `filius-orchestrator.service` and the online `docker-orchestrate` runner; a `docker-build` runner cannot accept this job.
- **Orchestration keeps restarting:** inspect its journal for unavailable rootless Docker, PAT/registration failures, or a conflicting container. Setup's service-state check alone does not verify registration.
- **Runner waits without a job:** this is expected. Push a matching workflow run or dispatch one manually; the launcher exits only after one job completes.
- **Compose bind mount path not found:** use a path beneath `FILIUS_DEPLOYMENTS_DIR`; paths in the runner's temporary checkout are not visible to the rootless daemon on finius.

## Repository layout

```text
rootless-docker/setup.sh       Host account and rootless Docker setup
rootless-docker/delegate-cgroups.sh  Idempotent systemd cgroup delegation
setup.sh                      Build images and install/start orchestration
orchestration-runner/run-once.sh  Launch/stop the managed orchestration container
orchestration-runner/filius-orchestrator.service  Boot-persistent worker supervision
build-runner/Dockerfile        GitHub Actions runner image
build-runner/runner-entrypoint.sh  Runner registration and execution
build-runner/build.sh          Build the runner image
build-runner/run-once.sh       Request a token and run one ephemeral job
deployment-runner/Dockerfile   Runner image with Docker Compose
deployment-runner/build.sh     Build the deployment runner image
deployment-runner/run-once.sh  Start one ephemeral deployment job
.github/workflows/build.yml    Runner smoke-test workflow
.github/workflows/dispatch_runner.yml  Manual HelloWorld orchestration placeholder
.github/workflows/build-runner-image.yml  Rebuild runner image when its inputs change
compose.runners.yaml           Compose definitions for one-job runner containers
runner-pool.sh                 Legacy manual 2-build/1-deploy supervisor
```
