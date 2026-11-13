# filius

Self-hosted GitHub Actions runner tools for finius. The setup builds an ephemeral build runner and an ephemeral deployment runner. Both use finius's dedicated rootless Docker daemon. Registry publishing and monitoring are future work.

## How it works

1. `rootless-docker/setup.sh` creates the locked `filius-runner` Linux account, its private home, and the persistent deployment directory, then configures a rootless Docker daemon for it.
2. `build-runner/build.sh` builds `filius-builder:local`; `deployment-runner/build.sh` adds Docker Compose and builds `filius-deployer:local` on the same daemon.
3. `runner-pool.sh` supervises two build workers and one deployment worker. Each worker uses the GitHub fine-grained personal access token stored on finius to request a fresh, short-lived runner registration token for each job.
4. Each ephemeral runner container is started through `compose.runners.yaml`, waits for one matching job, executes it, deregisters, and exits. Compose removes the runner container afterward. Containers started by a deployment job remain running in the rootless daemon.

The build runner has labels `self-hosted`, `linux`, `x64`, and `docker-build`; the deployment runner uses `self-hosted`, `linux`, `x64`, and `docker-deploy`. The example workflow in `.github/workflows/build.yml` tests Docker access. `.github/workflows/build-runner-image.yml` rebuilds both runner images when their Dockerfiles or build inputs change; updated images are used the next time a runner starts.

## Requirements

- A Debian or Ubuntu server using systemd, with Docker Engine installed.
- The rootless Docker setup tool that matches the installed Docker Engine. The setup script installs common prerequisites and attempts to install `docker-ce-rootless-extras` if the tool is missing.
- `curl` and `jq` on finius for the one-job launcher.
- A private GitHub repository for the runner to serve. Only run trusted workflows on a self-hosted runner.

The runner uses the rootless daemon socket rather than `/var/run/docker.sock`. Before mounting the socket into the runner container, `run-once.sh` temporarily makes the socket file accessible and restores its original mode after the container exits. The socket remains under systemd's private `/run/user/<UID>` directory on the host. This limits Docker control to the `filius-runner` account and its rootless daemon. It is not a VM: runner jobs still share finius's kernel and resources. Docker documents [rootless mode](https://docs.docker.com/engine/security/rootless/) and its [security model](https://docs.docker.com/engine/security/).

The deployment runner controls only this rootless daemon, so its containers are separate from anything started by finius's rootful Docker daemon. Rootless Docker also restricts binding privileged ports such as 80 and 443; publish an unprivileged host port (for example, 8080) and route traffic to it separately if needed. See [Docker's rootless mode](https://docs.docker.com/engine/security/rootless/).

## Install on finius

Clone this repository somewhere readable by your normal admin account, for example `/opt/filius`. Keep the Git checkout and application source owned by that account.

Run the top-level installer from the checkout:

```sh
cd /opt/filius
sudo ./setup.sh
```

The installer checks for `curl` and `jq`, then prompts for a fine-grained PAT if `/etc/filius/github-token` does not exist yet. Create a PAT for the repository that will use the runner, with **Repository permissions → Administration: Read and write**. The account creating the token must be an administrator of that repository. GitHub requires this permission for the API that creates runner registration tokens; those temporary registration tokens expire after one hour. See [GitHub's self-hosted runner API](https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-registration-token-for-a-repository).

The selected repository URL is saved in `/etc/filius/repository-url`. On later setup runs, it appears as the prompt default; press Enter to keep it or enter a different repository URL.

The PAT is saved outside the checkout with root-only permissions. The installer then asks for a repository URL, checks that GitHub accepts the PAT, sets up rootless Docker, and builds `filius-builder:local` and `filius-deployer:local`. It does not start a runner or run a workflow.

The runner version is pinned in `build-runner/Dockerfile`, and self-updates are disabled so an ephemeral runner does not replace its registration while processing its one job. At startup, the container checks GitHub's latest stable release and warns if its baked-in version is older. Update `RUNNER_VERSION` and rebuild the image regularly; GitHub stops assigning jobs to runners that have not been updated within its supported update window. See [GitHub's runner update guidance](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).

The rootless Docker setup creates `filius-runner`, adds subordinate UID/GID ranges if needed, delegates the CPU, cpuset, I/O, memory, and PID cgroup controllers to that user's systemd manager, enables the daemon at boot, and leaves the host's existing Docker daemon running. If the delegation drop-in changes, the setup restarts the `filius-runner` user manager and its rootless Docker daemon; run it only when no runner job is active. The built image is available only in the rootless daemon, not in finius's rootful Docker daemon. Resource-controller warnings can remain if the host does not use unified cgroup v2 or lacks those controllers.

### Start the runner pool

After setup, start the pool on finius with:

```sh
sudo /opt/filius/runner-pool.sh https://github.com/OWNER/REPOSITORY
```

This foreground host script keeps two build workers and one deployment worker available. Each worker repeatedly starts a fresh one-job runner container with Docker Compose, so it requests a new registration token for every job. Press Ctrl-C to stop the pool. Check **Repository → Settings → Actions → Runners** to see online ephemeral runners while they wait.

The example workflow targets `runs-on: [self-hosted, docker-build]`. A workflow with different labels will remain queued until a matching runner is available. See [GitHub's runner selection docs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).

### Deploy one job

To run only one ephemeral deployment runner instead of the pool:

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
- **Runner waits without a job:** this is expected. Push a matching workflow run or dispatch one manually; the launcher exits only after one job completes.
- **Compose bind mount path not found:** use a path beneath `FILIUS_DEPLOYMENTS_DIR`; paths in the runner's temporary checkout are not visible to the rootless daemon on finius.

## Repository layout

```text
rootless-docker/setup.sh       Host account and rootless Docker setup
rootless-docker/delegate-cgroups.sh  Idempotent systemd cgroup delegation
build-runner/Dockerfile        GitHub Actions runner image
build-runner/runner-entrypoint.sh  Runner registration and execution
build-runner/build.sh          Build the runner image
build-runner/run-once.sh       Request a token and run one ephemeral job
deployment-runner/Dockerfile   Runner image with Docker Compose
deployment-runner/build.sh     Build the deployment runner image
deployment-runner/run-once.sh  Start one ephemeral deployment job
.github/workflows/build.yml    Runner smoke-test workflow
.github/workflows/build-runner-image.yml  Rebuild runner image when its inputs change
compose.runners.yaml           Compose definitions for one-job runner containers
runner-pool.sh                 Host supervisor for 2 build and 1 deploy worker
```
