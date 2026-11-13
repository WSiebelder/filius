# filius

Self-hosted GitHub Actions runner tools for finius. The current setup is a first working slice: it builds a rootless-Docker runner image and starts one ephemeral runner for one repository job. Deployment, registry publishing, and monitoring are future work.

## How it works

1. `rootless-docker/setup.sh` creates the locked `filius-runner` Linux account and configures a rootless Docker daemon for it.
2. `build-runner/build.sh` builds `filius-builder:local` using that rootless daemon.
3. `build-runner/run-once.sh` uses a GitHub fine-grained personal access token stored on finius to request a short-lived runner registration token.
4. The script starts the runner container. It registers with GitHub, waits for one matching job, runs it, deregisters, and exits. Docker removes the container afterward.

The runner currently has the labels `self-hosted`, `linux`, `x64`, and `docker-build`. The example workflow in `.github/workflows/build.yml` runs on every branch push or by manual dispatch. It checks the Docker connection and builds a tiny test image.

## Requirements

- A Debian or Ubuntu server using systemd, with Docker Engine installed.
- The rootless Docker setup tool that matches the installed Docker Engine. The setup script installs common prerequisites and attempts to install `docker-ce-rootless-extras` if the tool is missing.
- `curl` and `jq` on finius for the one-job launcher.
- A private GitHub repository for the runner to serve. Only run trusted workflows on a self-hosted runner.

The runner uses the rootless daemon socket rather than `/var/run/docker.sock`. This limits Docker control to the `filius-runner` account and its rootless daemon. It is not a VM: runner jobs still share finius's kernel and resources. Docker documents [rootless mode](https://docs.docker.com/engine/security/rootless/) and its [security model](https://docs.docker.com/engine/security/).

## Install on finius

Clone this repository somewhere readable by your normal admin account, for example `/opt/filius`. Keep the Git checkout and application source owned by that account.

Run the top-level installer from the checkout:

```sh
cd /opt/filius
sudo ./setup.sh
```

The installer checks for `curl` and `jq`, then prompts for a fine-grained PAT if `/etc/filius/github-token` does not exist yet. Create a PAT for the repository that will use the runner, with **Repository permissions → Administration: Read and write**. The account creating the token must be an administrator of that repository. GitHub requires this permission for the API that creates runner registration tokens; those temporary registration tokens expire after one hour. See [GitHub's self-hosted runner API](https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-registration-token-for-a-repository).

The PAT is saved outside the checkout with root-only permissions. The installer then asks for a repository URL, checks that GitHub accepts the PAT, sets up rootless Docker, and builds `filius-builder:local` using the rootless daemon. It does not start a runner or run a workflow.

The rootless Docker setup creates `filius-runner`, adds subordinate UID/GID ranges if needed, enables that user's daemon at boot, and leaves the host's existing Docker daemon running. The built image is available only in the rootless daemon, not in finius's rootful Docker daemon.

### Start one runner

Start the runner before pushing the workflow if you want that push to be picked up immediately. Pass the repository URL:

```sh
sudo /opt/filius/build-runner/run-once.sh https://github.com/OWNER/REPOSITORY
```

The command stays open while the runner waits for a matching job. When one job finishes, the runner deregisters, the container is removed, and the command exits. Check **Repository → Settings → Actions → Runners** to see whether GitHub reports it as online while it waits.

The example workflow targets `runs-on: [self-hosted, docker-build]`. A workflow with different labels will remain queued until a matching runner is available. See [GitHub's runner selection docs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).

## Using more repositories

`run-once.sh` registers against one repository URL at a time. The fine-grained PAT must include that repository and have **Administration: Read and write** permission. For repositories under your personal account, run a one-job runner for each repository. To share runners across multiple repositories, GitHub supports organization-level runners for repositories in an organization; this setup script currently uses repository-level registration. See [GitHub's runner concepts](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners).

## Troubleshooting

- **Rootless Docker socket missing:** rerun `sudo ./rootless-docker/setup.sh`; check the printed systemd status command and the `filius-runner` user service.
- **Runner image not found:** build it with the rootless daemon as shown above. Images in the rootful daemon are not visible to rootless Docker.
- **GitHub API returns 403:** confirm the PAT is fine-grained, includes this repository, has **Administration: Read and write**, and belongs to a repository administrator.
- **Job stays queued:** check that the runner is online and that the workflow's `runs-on` labels include `self-hosted` and `docker-build`.
- **Runner waits without a job:** this is expected. Push a matching workflow run or dispatch one manually; the launcher exits only after one job completes.

## Repository layout

```text
rootless-docker/setup.sh       Host account and rootless Docker setup
build-runner/Dockerfile        GitHub Actions runner image
build-runner/runner-entrypoint.sh  Runner registration and execution
build-runner/build.sh          Build the runner image
build-runner/run-once.sh       Request a token and run one ephemeral job
.github/workflows/build.yml    Runner smoke-test workflow
```
