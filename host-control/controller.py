#!/usr/bin/env python3
"""Host-only, single-repository dispatch and build-worker supervision."""

import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


REPOSITORY = "https://github.com/WSiebelder/filius"
BUILD_LABELS = {"self-hosted", "linux", "x64", "docker-build"}
IDLE_SECONDS = 8 * 60 * 60
DRAIN_SECONDS = 60
START_SECONDS = 180
WORKER_UNIT = "filius-build-worker.service"
REQUEST_ID = re.compile(r"[1-9][0-9]{0,19}-[1-9][0-9]{0,5}")
RUNNER_NAME = re.compile(r"filius-build-[a-f0-9]{32}")


class ControlError(Exception):
    pass


def eligibility(path, repository):
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        raise ControlError("Cannot read valid installed eligibility configuration")
    if value != {"build_repositories": [REPOSITORY]} or repository != REPOSITORY:
        raise ControlError("This slice supports only WSiebelder/filius, once, with one build worker")
    return REPOSITORY


def atomic_json(path, value, mode=0o600):
    temporary = path.parent / (".tmp-" + uuid.uuid4().hex)
    try:
        with temporary.open("x") as stream:
            os.chmod(temporary, mode)
            json.dump(value, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, token):
        self.token = token
        self.deadline = time.monotonic() + 180
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, path, method="GET", data=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ControlError("GitHub scan exceeded its time budget")
        request = urllib.request.Request(
            "https://api.github.com/repos/WSiebelder/filius" + path,
            data=None if data is None else json.dumps(data).encode(),
            headers={
                "Authorization": "Bearer " + self.token,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
            },
            method=method,
        )
        try:
            with self.opener.open(request, timeout=min(20, remaining)) as response:
                raw = response.read(8 * 1024 * 1024 + 1)
                if len(raw) > 8 * 1024 * 1024:
                    raise ControlError("GitHub response exceeds the size limit")
                value = json.loads(raw) if raw else {}
                if not isinstance(value, dict):
                    raise ControlError("GitHub response is not an object")
                return value
        except urllib.error.HTTPError as error:
            raise ControlError(
                "GitHub HTTP {}: check repository access, Administration write, "
                "Actions read and rate limits".format(error.code)
            ) from None
        except (OSError, ValueError):
            raise ControlError("GitHub request failed or returned invalid JSON") from None

    def pages(self, path, key):
        separator = "&" if "?" in path else "?"
        for page in range(1, 101):
            value = self.request(path + separator + "per_page=100&page=" + str(page))
            items = value.get(key)
            if not isinstance(items, list):
                raise ControlError("GitHub response is missing " + key)
            yield from items
            if len(items) < 100:
                return
        raise ControlError("GitHub pagination limit exceeded; scan was not completed")

    def demand(self):
        found = set()
        runs = set()
        for status in ("queued", "in_progress"):
            for run in self.pages("/actions/runs?status=" + status, "workflow_runs"):
                if run.get("status") not in ("queued", "in_progress"):
                    continue
                run_id, attempt = run.get("id"), run.get("run_attempt")
                if not isinstance(run_id, int) or not isinstance(attempt, int):
                    raise ControlError("GitHub run has no current attempt")
                if (run_id, attempt) in runs:
                    continue
                runs.add((run_id, attempt))
                path = "/actions/runs/{}/attempts/{}/jobs".format(run_id, attempt)
                for job in self.pages(path, "jobs"):
                    labels = job.get("labels", [])
                    if (
                        job.get("status") == "queued"
                        and job.get("conclusion") is None
                        and isinstance(labels, list)
                        and all(isinstance(label, str) for label in labels)
                        and {"self-hosted", "docker-build"} <= {label.lower() for label in labels}
                        and {label.lower() for label in labels} <= BUILD_LABELS
                    ):
                        if type(job.get("id")) is not int:
                            raise ControlError("GitHub queued job has no valid identity")
                        found.add(job["id"])
        return len(found)

    def runner(self, name):
        matches = [runner for runner in self.pages("/actions/runners", "runners")
                   if runner.get("name") == name]
        if len(matches) > 1:
            raise ControlError("Multiple registrations for the managed runner")
        return matches[0] if matches else None


def idle_runner(runner, name):
    return (
        isinstance(runner, dict)
        and runner.get("name") == name
        and type(runner.get("id")) is int
        and runner.get("status") == "online"
        and runner.get("busy") is False
        and isinstance(runner.get("labels"), list)
        and all(isinstance(label, dict) and isinstance(label.get("name"), str)
                for label in runner["labels"])
    )


class Host:
    def __init__(self):
        self.root = Path(os.environ.get("FILIUS_CONTROL_DIR", "/var/lib/filius-control"))
        self.state_dir = self.root / "state"
        self.state_path = self.state_dir / "worker.json"
        self.repository = eligibility(
            os.environ.get("FILIUS_ELIGIBILITY_FILE", "/etc/filius/eligible-repositories.json"),
            os.environ.get("GITHUB_URL", ""),
        )

    @contextlib.contextmanager
    def lock(self, name, blocking=True):
        with (self.state_dir / (name + ".lock")).open("a") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            except BlockingIOError:
                raise ControlError("Build supervision is already active; use --service to reuse it") from None
            yield

    def load(self):
        if not self.state_path.exists():
            return {"enabled": False, "name": None, "idle_deadline": None,
                    "seen_job": False, "quarantine": None, "starting": None}
        try:
            value = json.loads(self.state_path.read_text())
            if (
                type(value["enabled"]) is not bool
                or type(value["seen_job"]) is not bool
                or (value["name"] is not None and not RUNNER_NAME.fullmatch(value["name"]))
                or any(value[key] is not None and type(value[key]) not in (int, float)
                       for key in ("idle_deadline", "quarantine", "starting"))
            ):
                raise ValueError()
            return value
        except (OSError, ValueError, KeyError, TypeError):
            raise ControlError("Invalid worker state; refusing an unsafe recovery")

    def save(self, state):
        atomic_json(self.state_path, state)

    def api(self):
        token_path = Path(os.environ.get("GITHUB_PAT_FILE", "/etc/filius/github-token"))
        try:
            with token_path.open() as stream:
                info = os.fstat(stream.fileno())
                if info.st_uid != 0 or info.st_mode & 0o077 or not stat.S_ISREG(info.st_mode):
                    raise ControlError("The PAT must be a root-owned private regular file")
                token = stream.read().strip()
        except OSError:
            raise ControlError("Cannot read the host-only PAT") from None
        if not token:
            raise ControlError("The host-only PAT is empty")
        return GitHub(token)

    def command(self, args):
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=45)
        except (OSError, subprocess.TimeoutExpired):
            raise ControlError("Host command unavailable or timed out: " + args[0]) from None
        if result.returncode:
            # Never include command output: it may contain credentials or job data.
            raise ControlError("Host command failed: " + args[0])
        return result.stdout.strip()

    def container(self, name):
        if not name:
            return None
        identifiers = self.command(
            ["docker", "container", "ls", "--all", "--quiet", "--filter", "name=^/" + name + "$"]
        ).split()
        if not identifiers:
            return None
        if len(identifiers) != 1:
            raise ControlError("Ambiguous managed container identity")
        fields = self.command([
            "docker", "inspect", "--format",
            '{{.Id}} {{.State.Running}} {{index .Config.Labels "com.docker.compose.project"}} '
            '{{index .Config.Labels "com.docker.compose.service"}}', identifiers[0],
        ]).split()
        if (
            len(fields) != 4
            or fields[2:] != ["filius-runners", "build-runner"]
            or fields[1] not in ("true", "false")
            or not re.fullmatch(r"[a-f0-9]{64}", fields[0])
        ):
            raise ControlError("Refusing to manage a container without the expected Compose identity")
        return {"id": fields[0], "running": fields[1] == "true"}

    def evidence(self, container):
        logs = self.command(["docker", "logs", "--tail", "5000", container["id"]])
        return "Listening for Jobs" in logs, "Running job:" in logs

    def launch(self, name):
        environment = os.environ.copy()
        environment.update(RUNNER_KIND="build", RUNNER_NAME=name,
                           RUNNER_IMAGE="filius-builder:local")
        return subprocess.Popen(
            ["/usr/bin/bash", "/usr/local/lib/filius/build-runner/run.sh", "--once", self.repository],
            env=environment,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )

    def activate(self):
        self.command(["systemctl", "start", "--no-block", WORKER_UNIT])


def dispatch(host, manual=False, activate=True):
    api = host.api()
    demand = None if manual else api.demand()
    if not manual and not demand:
        return {"ok": True, "action": "no-op", "queued_jobs": 0}
    with host.lock("worker"):
        state = host.load()
        container = host.container(state["name"])
        elapsed = state["idle_deadline"] is not None and time.time() >= state["idle_deadline"]
        absent_expired = (not container or not container["running"]) and elapsed and not state["seen_job"]
        if state["enabled"] and not absent_expired:
            if container and container["running"] and (state["quarantine"] is not None or elapsed):
                _, local_job = host.evidence(container)
                runner = None if local_job else api.runner(state["name"])
                if local_job or (runner and runner.get("busy") is True):
                    state.update(seen_job=True, idle_deadline=None, quarantine=None)
                elif idle_runner(runner, state["name"]):
                    if not any(label["name"].lower() == "docker-build" for label in runner["labels"]):
                        api.request("/actions/runners/{}/labels".format(runner["id"]),
                                    "POST", {"labels": ["docker-build"]})
                    state.update(idle_deadline=time.time() + IDLE_SECONDS, quarantine=None)
                else:
                    raise ControlError("Cannot safely revive a quarantined/overdue runner with uncertain state")
                host.save(state)
            if activate:
                host.activate()
            return {"ok": True, "action": "reused", "queued_jobs": demand}
        if container and container["running"]:
            raise ControlError("A disabled managed container is still live; refusing a replacement")
        # Demand can disappear between initial discovery and serialized activation.
        demand = None if manual else api.demand()
        if not manual and not demand:
            return {"ok": True, "action": "no-op", "queued_jobs": 0}
        state.update(enabled=True, idle_deadline=None, seen_job=False,
                     quarantine=None, starting=None)
        host.save(state)
        if activate:
            host.activate()
        return {"ok": True, "action": "enabled", "queued_jobs": demand}


class Worker:
    def __init__(self, host):
        self.host = host
        self.child = None

    def retire(self, state, now, paused):
        enabled = paused and state["enabled"] and (
            state["seen_job"] or state["idle_deadline"] is None or now < state["idle_deadline"]
        )
        deadline = state["idle_deadline"] if enabled else None
        state.update(enabled=enabled, name=None, idle_deadline=deadline,
                     quarantine=None, starting=None, seen_job=False)
        self.host.save(state)

    def tick(self, now, draining=False, paused=False):
        draining = draining or paused
        host = self.host
        with host.lock("worker"):
            state = host.load()
            if not state["enabled"]:
                return False
            container = host.container(state["name"])
            if not container or not container["running"]:
                if self.child and self.child.poll() is None:
                    return True
                if state["starting"] is not None and now - state["starting"] < START_SECONDS:
                    return True
                if container:
                    host.command(["docker", "rm", container["id"]])
                if draining or (
                    not state["seen_job"]
                    and state["idle_deadline"] is not None
                    and now >= state["idle_deadline"]
                ):
                    self.retire(state, now, paused)
                    return False
                # A completed job gets a new budget; idle failure/reboot does not.
                if state["seen_job"]:
                    state["idle_deadline"] = None
                state.update(name="filius-build-" + uuid.uuid4().hex,
                             seen_job=False, quarantine=None, starting=now)
                host.save(state)
                self.child = host.launch(state["name"])
                return True

            ready, local_job = host.evidence(container)
            if local_job:
                state.update(seen_job=True, idle_deadline=None, quarantine=None, starting=None)
                host.save(state)
                return True
            if state["seen_job"]:
                # One-job registration: wait for natural exit, even if completion hangs.
                return True
            api = host.api()
            runner = api.runner(state["name"])
            if runner and runner.get("busy") is True:
                state.update(seen_job=True, idle_deadline=None, quarantine=None, starting=None)
                host.save(state)
                return True
            if not ready or not idle_runner(runner, state["name"]):
                raise ControlError("Runner readiness/busy state uncertain; leaving the container untouched")
            state["starting"] = None
            if state["idle_deadline"] is None:
                state["idle_deadline"] = now + IDLE_SECONDS
            if not draining and now < state["idle_deadline"]:
                host.save(state)
                return True

            runner_id = runner["id"]
            if state["quarantine"] is None:
                if any(label["name"].lower() == "docker-build" for label in runner["labels"]):
                    api.request("/actions/runners/{}/labels/docker-build".format(runner_id), "DELETE")
                state["quarantine"] = now
                host.save(state)
                return True
            labels = {label["name"].lower() for label in runner["labels"]}
            if "docker-build" in labels:
                state["quarantine"] = None
                host.save(state)
                raise ControlError("Runner quarantine not confirmed; deferring idle retirement")
            if now - state["quarantine"] < DRAIN_SECONDS:
                return True
            # Recheck both observations immediately before targeted retirement.
            runner = api.request("/actions/runners/" + str(runner_id))
            _, local_job = host.evidence(container)
            if local_job or runner.get("busy") is True:
                state.update(seen_job=True, idle_deadline=None, quarantine=None)
                host.save(state)
                return True
            if not idle_runner(runner, state["name"]) or runner["id"] != runner_id:
                raise ControlError("Final idle check uncertain; refusing to stop")
            if any(label["name"].lower() == "docker-build" for label in runner["labels"]):
                raise ControlError("Final label quarantine check failed; refusing to stop")
            host.command(["docker", "stop", "--time", "30", container["id"]])
            remaining = host.container(state["name"])
            if remaining and remaining["running"]:
                raise ControlError("Managed idle container did not stop")
            self.retire(state, now, paused)
            print("Build worker paused for installation" if paused else
                  "Build worker retired" if draining else "Build worker expired after eight idle hours",
                  flush=True)
            # Forced registration deletion is safe only after the idle container exited.
            api.request("/actions/runners/" + str(runner_id), "DELETE")
            return False

    def run(self, draining=False, paused=False):
        stopping = False
        if draining or paused:
            print("Draining build worker; waiting for any active job to finish", flush=True)

        def stop(signum, frame):
            nonlocal stopping
            stopping = True

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        while not stopping:
            try:
                if not self.tick(time.time(), draining=draining, paused=paused):
                    return
            except (ControlError, OSError) as error:
                print("Build worker deferred: " + safe_error(error), flush=True)
            for _ in range(15):
                if stopping:
                    break
                time.sleep(1)
        # Stopping supervision must not signal/cancel the container's active job.


def safe_error(error):
    return str(error) if isinstance(error, ControlError) else "Host filesystem/process operation failed"


def process_requests(host):
    requests = host.root / "requests"
    results = host.root / "results"
    with host.lock("scan"):
        with os.scandir(requests) as entries:
            first = next(entries, None)
        for entry in ([] if first is None else [Path(first.path)]):
            identifier = entry.name[:-8] if entry.name.endswith(".request") else entry.name
            valid = entry.name == identifier + ".request" and REQUEST_ID.fullmatch(identifier)
            info = entry.lstat()
            if stat.S_ISDIR(info.st_mode):
                # Quarantine directories without traversing guest-controlled contents.
                entry.rename(host.state_dir / ("rejected-" + uuid.uuid4().hex))
                continue
            if not valid:
                entry.unlink()
                continue
            result_path = results / (identifier + ".json")
            if result_path.exists():
                entry.unlink()
                continue
            try:
                descriptor = os.open(entry, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                try:
                    opened = os.fstat(descriptor)
                    if not stat.S_ISREG(opened.st_mode) or opened.st_size != 0:
                        raise ControlError("Scan requests must be empty regular files")
                finally:
                    os.close(descriptor)
                outcome = dispatch(host)
            except (ControlError, OSError) as error:
                outcome = {"ok": False, "error": safe_error(error)}
            outcome["request_id"] = identifier
            atomic_json(result_path, outcome, 0o644)
            entry.unlink(missing_ok=True)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "validate":
        eligibility(sys.argv[2], sys.argv[3])
        return
    if os.geteuid() != 0:
        raise ControlError("Host control must run as root")
    host = Host()
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command in ("scan", "worker", "drain", "pause", "check-install", "all", "enable"):
        socket = os.environ.get("DOCKER_SOCKET")
        if not socket:
            raise ControlError("Installed DOCKER_SOCKET configuration is required")
        os.environ["DOCKER_HOST"] = "unix://" + socket
    if command == "check-access":
        host.api().request("/actions/runs?per_page=1")
    elif command == "scan":
        process_requests(host)
    elif command in ("worker", "drain"):
        with host.lock("supervisor"):
            Worker(host).run(draining=command == "drain")
    elif command == "pause":
        with host.lock("supervisor", blocking=False):
            Worker(host).run(paused=True)
            if host.load()["name"] is not None:
                raise ControlError("Maintenance drain did not finish; leaving the build container untouched")
    elif command == "resume":
        with host.lock("worker"):
            if host.load()["enabled"]:
                host.activate()
    elif command == "all":
        with host.lock("supervisor", blocking=False):
            print(json.dumps(dispatch(host, manual=True, activate=False)), flush=True)
            worker = Worker(host)
            worker.run()
            if host.load()["enabled"]:
                print("Draining the foreground build worker without cancelling its job", flush=True)
                worker.run(draining=True)
    elif command == "enable":
        print(json.dumps(dispatch(host, manual=True)), flush=True)
    elif command == "check-install":
        with host.lock("supervisor", blocking=False):
            with host.lock("worker"):
                state = host.load()
                container = host.container(state["name"])
                if container and container["running"]:
                    raise ControlError("Wait for the managed build container to exit before runtime installation")
    else:
        raise ControlError("Usage: controller.py scan|worker|all|enable|drain|pause|resume|check-access|check-install|validate FILE URL")


if __name__ == "__main__":
    try:
        main()
    except (ControlError, OSError) as error:
        print(safe_error(error), file=sys.stderr)
        sys.exit(1)
