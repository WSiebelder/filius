# Repository instructions

## Project scope

This repository contains the self-hosted GitHub Actions runner setup for finius. The current implementation covers a rootless Docker build daemon and a script that starts one ephemeral runner for one repository job. Deployment, registry publishing, and monitoring are not implemented yet; do not describe them as working features.

## Architecture

- `rootless-docker/setup.sh` creates the locked `filius-runner` account, delegates cgroup controllers to its systemd user manager, and configures its rootless Docker daemon on Debian or Ubuntu with systemd. `rootless-docker/delegate-cgroups.sh` owns that idempotent delegation drop-in.
- `build-runner/Dockerfile` builds the GitHub Actions runner image. The runner process uses UID 1001 inside the container.
- `build-runner/runner-entrypoint.sh` registers an ephemeral runner and runs one job.
- `build-runner/run-once.sh` reads the host PAT from `/etc/filius/github-token`, requests a short-lived registration token from GitHub, and launches the runner through the rootless Docker socket.
- `.github/workflows/build.yml` is a smoke test. It targets `self-hosted` and `docker-build` labels and builds a small Docker image.

The GitHub PAT must stay outside the repository and runner container. The registration token is short-lived and should only be passed to the runner at startup. Do not add secrets to source files, image layers, command output, or committed environment files.

The runner container receives access to the rootless Docker socket. Keep it pointed at `/run/user/<filius-runner-uid>/docker.sock`; do not substitute `/var/run/docker.sock` without an explicit security review. If socket permissions must be relaxed for the container's UID/GID mapping, do so only while the host socket's parent runtime directory is verified private, and restore its original mode after the container exits. Rootless Docker reduces host privilege but is not VM isolation.

## Editing guidance

- Keep host setup scripts safe to rerun and fail clearly when prerequisites are missing.
- Preserve compatibility with the current Debian/Ubuntu systemd target unless the user asks to broaden it.
- Keep one-job runner behavior ephemeral. A supervisor that repeats jobs must request a fresh runner registration token each time.
- The runner image pins its runner version, checks for a newer stable release at startup, and uses `--disableupdate` for ephemeral operation. Update the pinned version and rebuild the image regularly so GitHub continues to accept jobs.
- `.github/workflows/build-runner-image.yml` rebuilds the local runner image when its Dockerfile or build inputs change. It runs on the current runner, so the updated image is used by the next ephemeral runner launch.
- Match workflow `runs-on` labels to the labels configured by the runner image.
- Update `README.md` when setup steps, required permissions, supported platforms, or operational behavior changes.
- Prefer small, explicit shell scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.

## Verification

Do not run tests or host setup commands unless the user asks for verification or execution. Before suggesting commands for finius, distinguish commands run as root from commands run as `filius-runner`, and state when a command can change host packages, accounts, or services.
