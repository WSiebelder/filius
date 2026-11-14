import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import Mock, patch
import urllib.error


SPEC = importlib.util.spec_from_file_location(
    "controller", Path(__file__).resolve().parents[1] / "host-control/controller.py"
)
control = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(control)


class DispatchMountTests(unittest.TestCase):
    def script(self, root):
        workflow = Path(__file__).resolve().parents[1] / ".github/workflows/dispatch_runner.yml"
        script = textwrap.dedent(workflow.read_text().split("        run: |\n", 1)[1])
        return script.replace("/filius-control", str(root))

    def test_missing_either_control_directory_fails_before_request_submission(self):
        for directories in ((), ("requests",), ("results",)):
            with self.subTest(directories=directories), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for directory in directories:
                    (root / directory).mkdir()
                environment = dict(os.environ, GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1")
                result = subprocess.run(
                    ["/bin/bash", "-c", self.script(root)],
                    env=environment, capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("::error::Host control mount directories are missing", result.stdout)
                self.assertIn("setup.sh", result.stdout)
                self.assertFalse((root / "requests/123-1.request").exists())
                for directory in ("requests", "results"):
                    self.assertEqual((root / directory).exists(), directory in directories)

    def test_control_directories_allow_preflight_to_continue(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "requests").mkdir()
            (root / "results").mkdir()
            preflight = self.script(root).split("export REQUEST_ID=", 1)[0]
            result = subprocess.run(
                ["/bin/bash", "-c", preflight],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.api = control.GitHub("test-only-token")
        self.api.request = Mock()

    def test_active_run_current_attempt_and_paginated_runs_jobs(self):
        ignored = {"id": 99, "run_attempt": 1, "status": "completed"}
        queued = {"id": 1, "run_attempt": 2, "status": "queued"}
        active = {"id": 2, "run_attempt": 3, "status": "in_progress"}
        job = {"id": 7, "status": "queued", "conclusion": None,
               "labels": ["SELF-HOSTED", "Linux", "X64", "docker-build"]}
        replies = {
            "/actions/runs?status=queued&per_page=100&page=1": {"workflow_runs": [ignored] * 100},
            "/actions/runs?status=queued&per_page=100&page=2": {"workflow_runs": [queued]},
            "/actions/runs/1/attempts/2/jobs?per_page=100&page=1": {"jobs": [{"status": "completed"}] * 100},
            "/actions/runs/1/attempts/2/jobs?per_page=100&page=2": {"jobs": [job]},
            "/actions/runs?status=in_progress&per_page=100&page=1": {"workflow_runs": [active]},
            "/actions/runs/2/attempts/3/jobs?per_page=100&page=1": {"jobs": [dict(job, id=8)]},
        }
        self.api.request.side_effect = replies.__getitem__
        self.assertEqual(self.api.demand(), 2)
        self.assertEqual(self.api.request.call_count, len(replies))

    def test_blocked_unsupported_cancelled_and_other_roles_do_not_count(self):
        jobs = [
            {"status": "queued", "labels": []},  # Unresolved/dependency-blocked job.
            {"status": "queued", "labels": ["self-hosted", "docker-build", "arm64"]},
            {"status": "queued", "labels": ["self-hosted", "docker-orchestrate"]},
            {"status": "queued", "labels": ["self-hosted", "docker-deploy"]},
            {"status": "completed", "labels": ["self-hosted", "docker-build"]},
            {"status": "queued", "conclusion": "cancelled", "labels": ["self-hosted", "docker-build"]},
        ]
        self.api.pages = Mock(side_effect=[
            [{"id": 1, "run_attempt": 1, "status": "queued"},
             {"id": 2, "run_attempt": 1, "status": "waiting"}],
            jobs,
            [],
        ])
        self.assertEqual(self.api.demand(), 0)
        self.assertNotIn("/actions/runs/2/attempts/1/jobs",
                         [call.args[0] for call in self.api.pages.call_args_list])

    def test_permission_failure_is_not_empty_demand(self):
        self.api.request.side_effect = control.ControlError("GitHub HTTP 403")
        with self.assertRaisesRegex(control.ControlError, "403"):
            self.api.demand()

    def test_pagination_exhaustion_is_an_error(self):
        self.api.request.return_value = {"jobs": [{}] * 100}
        with self.assertRaisesRegex(control.ControlError, "pagination limit"):
            list(self.api.pages("/actions/runs/1/jobs", "jobs"))

    def test_http_failure_does_not_expose_token_or_response(self):
        api = control.GitHub("test-only-token")
        api.opener.open = Mock(side_effect=urllib.error.HTTPError(
            "https://api.github.com", 403, "test-only-token", {}, None
        ))
        with self.assertRaises(control.ControlError) as caught:
            api.request("/actions/runners")
        self.assertIn("403", str(caught.exception))
        self.assertNotIn("test-only-token", str(caught.exception))


class HostTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("requests", "results", "state"):
            (self.root / name).mkdir()
        self.allowlist = self.root / "eligibility.json"
        self.allowlist.write_text(json.dumps({"build_repositories": [control.REPOSITORY]}))
        environment = patch.dict(os.environ, {
            "GITHUB_URL": control.REPOSITORY,
            "FILIUS_ELIGIBILITY_FILE": str(self.allowlist),
            "FILIUS_CONTROL_DIR": str(self.root),
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.host = control.Host()
        self.api = Mock(spec=control.GitHub)
        self.host.api = Mock(return_value=self.api)
        self.host.activate = Mock()
        self.host.container = Mock(return_value=None)
        self.host.command = Mock(return_value="")
        self.host.launch = Mock(return_value=Mock())
        self.host.evidence = Mock(return_value=(True, False))

    def state(self, **settings):
        value = self.host.load()
        value.update(settings)
        self.host.save(value)
        return value

    def runner(self, **settings):
        value = {
            "id": 7, "name": self.host.load()["name"], "busy": False, "status": "online",
            "labels": [{"name": label} for label in control.BUILD_LABELS],
        }
        value.update(settings)
        self.api.runner.return_value = value
        self.api.request.return_value = value
        return value

    def live_worker(self, **settings):
        value = dict(enabled=True, name="filius-build-" + "a" * 32, seen_job=False,
                     idle_deadline=None, quarantine=None, starting=None)
        value.update(settings)
        self.state(**value)
        self.host.container.return_value = {"id": "managed-container", "running": True}
        self.runner()
        return control.Worker(self.host)

    def test_eligibility_rejects_wrong_repos_duplicates_and_schema(self):
        for value in (
            {"build_repositories": ["https://github.com/WSiebelder/another"]},
            {"build_repositories": [control.REPOSITORY, control.REPOSITORY]},
            {"build_repositories": control.REPOSITORY},
            {"build_repositories": [control.REPOSITORY], "capacity": 2},
        ):
            with self.subTest(value=value):
                self.allowlist.write_text(json.dumps(value))
                with self.assertRaises(control.ControlError):
                    control.eligibility(self.allowlist, control.REPOSITORY)
        self.allowlist.write_text(json.dumps({"build_repositories": [control.REPOSITORY]}))
        with self.assertRaises(control.ControlError):
            control.eligibility(self.allowlist, "https://github.com/other/control")

    def test_no_demand_and_stale_demand_do_not_activate(self):
        for replies in ([0], [1, 0]):
            with self.subTest(replies=replies):
                self.api.demand.side_effect = replies
                self.assertEqual(control.dispatch(self.host)["action"], "no-op")
                self.assertFalse(self.host.load()["enabled"])
                self.host.activate.assert_not_called()

    def test_concurrent_dispatch_reserves_only_one_worker(self):
        self.api.demand.return_value = 2
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda _: control.dispatch(self.host), range(2)))
        self.assertEqual(sorted(result["action"] for result in results), ["enabled", "reused"])
        worker = control.Worker(self.host)
        worker.tick(100)
        worker.tick(101)
        self.host.launch.assert_called_once()

    def test_busy_worker_is_reused_without_resetting_budget(self):
        deadline = control.time.time() + 100
        self.state(enabled=True, name="filius-build-" + "a" * 32, idle_deadline=deadline)
        self.host.container.return_value = {"id": "container", "running": True}
        self.api.demand.return_value = 2
        self.assertEqual(control.dispatch(self.host)["action"], "reused")
        self.assertEqual(self.host.load()["idle_deadline"], deadline)
        self.host.launch.assert_not_called()

    def test_manual_demand_revives_quarantined_worker_instead_of_reporting_false_reuse(self):
        self.live_worker(idle_deadline=100, quarantine=100)
        self.runner(labels=[{"name": "self-hosted"}])
        self.api.demand.return_value = 1
        with patch.object(control.time, "time", return_value=200):
            self.assertEqual(control.dispatch(self.host)["action"], "reused")
        self.api.request.assert_called_once_with(
            "/actions/runners/7/labels", "POST", {"labels": ["docker-build"]}
        )
        self.assertIsNone(self.host.load()["quarantine"])
        self.assertEqual(self.host.load()["idle_deadline"], 200 + control.IDLE_SECONDS)
        self.host.launch.assert_not_called()

    def test_manual_demand_revives_absent_overdue_enabled_worker(self):
        self.state(enabled=True, name="filius-build-" + "a" * 32, idle_deadline=100)
        self.api.demand.return_value = 1
        with patch.object(control.time, "time", return_value=200):
            self.assertEqual(control.dispatch(self.host)["action"], "enabled")
        self.assertIsNone(self.host.load()["idle_deadline"])
        control.Worker(self.host).tick(200)
        self.host.launch.assert_called_once()

    def test_uncertain_quarantine_does_not_restore_labels_or_launch(self):
        self.live_worker(idle_deadline=100, quarantine=100)
        self.api.demand.return_value = 1
        self.api.runner.return_value = None
        with self.assertRaisesRegex(control.ControlError, "uncertain"):
            control.dispatch(self.host)
        self.host.activate.assert_not_called()
        self.host.launch.assert_not_called()
        self.api.request.assert_not_called()

    def test_api_error_does_not_enable_worker(self):
        self.api.demand.side_effect = control.ControlError("GitHub HTTP 403")
        with self.assertRaises(control.ControlError):
            control.dispatch(self.host)
        self.assertFalse(self.host.load()["enabled"])
        self.host.activate.assert_not_called()

    def test_disabled_live_container_prevents_replacement(self):
        self.state(name="filius-build-" + "a" * 32)
        self.host.container.return_value = {"id": "container", "running": True}
        self.api.demand.return_value = 1
        with self.assertRaisesRegex(control.ControlError, "still live"):
            control.dispatch(self.host)
        self.host.activate.assert_not_called()

    def test_never_enabled_and_expired_state_do_not_revive(self):
        self.assertFalse(control.Worker(self.host).tick(100000))
        self.host.launch.assert_not_called()

    def test_elapsed_idle_budget_does_not_launch_on_boot_and_dispatch_can_revive(self):
        self.state(enabled=True, name="filius-build-" + "a" * 32, idle_deadline=100)
        self.assertFalse(control.Worker(self.host).tick(200))
        self.host.launch.assert_not_called()
        self.api.demand.return_value = 1
        self.assertEqual(control.dispatch(self.host)["action"], "enabled")
        self.assertIsNone(self.host.load()["idle_deadline"])
        control.Worker(self.host).tick(201)
        self.host.launch.assert_called_once()

    def test_first_ready_listener_starts_budget_and_restart_preserves_it(self):
        worker = self.live_worker()
        worker.tick(100)
        deadline = self.host.load()["idle_deadline"]
        self.assertEqual(deadline, 100 + control.IDLE_SECONDS)
        control.Worker(self.host).tick(200)
        self.assertEqual(self.host.load()["idle_deadline"], deadline)
        self.host.launch.assert_not_called()

    def test_idle_failure_keeps_original_deadline_on_replacement(self):
        self.state(enabled=True, name="filius-build-" + "a" * 32, idle_deadline=200)
        control.Worker(self.host).tick(100)
        self.assertEqual(self.host.load()["idle_deadline"], 200)
        self.host.launch.assert_called_once()

    def test_busy_or_local_job_at_deadline_cancels_expiry_and_allows_long_job(self):
        for local in (False, True):
            with self.subTest(local=local):
                self.host.command.reset_mock()
                self.api.request.reset_mock()
                worker = self.live_worker(idle_deadline=100)
                self.host.evidence.return_value = (True, local)
                self.runner(busy=not local)
                worker.tick(100)
                self.assertIsNone(self.host.load()["idle_deadline"])
                self.assertTrue(self.host.load()["seen_job"])
                self.runner(busy=False)
                worker.tick(100 + 2 * control.IDLE_SECONDS)
                self.host.command.assert_not_called()
                self.host.launch.assert_not_called()

    def test_local_job_survives_api_outage(self):
        worker = self.live_worker(idle_deadline=100)
        self.host.evidence.return_value = (True, True)
        self.host.api.side_effect = control.ControlError("GitHub unavailable")
        worker.tick(100)
        self.assertTrue(self.host.load()["seen_job"])
        self.host.command.assert_not_called()

    def test_completion_starts_fresh_ephemeral_runner_and_idle_budget(self):
        worker = self.live_worker(idle_deadline=100)
        self.runner(busy=True)
        worker.tick(99)
        self.host.container.return_value = None
        worker.tick(100)
        self.assertIsNone(self.host.load()["idle_deadline"])
        name = self.host.load()["name"]
        self.assertNotEqual(name, "filius-build-" + "a" * 32)
        self.host.launch.assert_called_once_with(name)
        self.host.container.return_value = {"id": "replacement", "running": True}
        self.runner()
        worker.tick(200)
        self.assertEqual(self.host.load()["idle_deadline"], 200 + control.IDLE_SECONDS)

    def test_expiry_quarantines_then_confirms_idle_before_targeted_stop(self):
        worker = self.live_worker(idle_deadline=100)
        worker.tick(100)
        self.api.request.assert_called_once_with("/actions/runners/7/labels/docker-build", "DELETE")
        self.host.command.assert_not_called()
        labels = [{"name": "self-hosted"}, {"name": "linux"}, {"name": "x64"}]
        self.runner(labels=labels)
        worker.tick(159)
        self.host.command.assert_not_called()
        self.host.container.side_effect = [
            {"id": "managed-container", "running": True}, None,
        ]
        self.assertFalse(worker.tick(160))
        self.host.command.assert_called_once_with(
            ["docker", "stop", "--time", "30", "managed-container"]
        )
        self.api.request.assert_any_call("/actions/runners/7", "DELETE")
        self.assertFalse(self.host.load()["enabled"])
        self.assertFalse(control.Worker(self.host).tick(100000))
        self.host.launch.assert_not_called()

    def test_quarantine_racing_job_is_not_stopped(self):
        worker = self.live_worker(idle_deadline=100)
        worker.tick(100)
        self.runner(busy=True, labels=[])
        worker.tick(160)
        self.assertTrue(self.host.load()["seen_job"])
        self.assertIsNone(self.host.load()["quarantine"])
        self.host.command.assert_not_called()

    def test_final_check_busy_local_or_uncertain_never_stops(self):
        for change in ("busy", "local", "offline", "missing-labels", "wrong-identity", "api-error"):
            with self.subTest(change=change):
                self.host.evidence.side_effect = None
                self.host.evidence.return_value = (True, False)
                self.host.command.reset_mock()
                self.api.request.reset_mock()
                worker = self.live_worker(idle_deadline=100, quarantine=100)
                runner = self.runner(labels=[])
                final = dict(runner)
                if change == "busy":
                    final["busy"] = True
                elif change == "offline":
                    final["status"] = "offline"
                elif change == "missing-labels":
                    final.pop("labels")
                elif change == "wrong-identity":
                    final["name"] = "some-other-runner"
                elif change == "local":
                    self.host.evidence.side_effect = [(True, False), (True, True)]
                if change == "api-error":
                    self.api.request.side_effect = control.ControlError("GitHub HTTP 403")
                else:
                    self.api.request.side_effect = None
                    self.api.request.return_value = final
                try:
                    worker.tick(160)
                except control.ControlError:
                    pass
                self.api.request.assert_called_once_with("/actions/runners/7")
                self.host.command.assert_not_called()
                self.assertTrue(self.host.load()["enabled"])
                self.host.evidence.side_effect = None
        self.api.request.side_effect = None

    def test_failed_label_removal_preserves_enabled_deadline(self):
        worker = self.live_worker(idle_deadline=100)
        self.api.request.side_effect = control.ControlError("GitHub HTTP 403")
        with self.assertRaises(control.ControlError):
            worker.tick(100)
        self.assertEqual(self.host.load()["idle_deadline"], 100)
        self.assertIsNone(self.host.load()["quarantine"])
        self.assertTrue(self.host.load()["enabled"])
        self.host.command.assert_not_called()

    def test_label_removal_before_state_write_can_recover_safely(self):
        worker = self.live_worker(idle_deadline=100)
        self.runner(labels=[])
        worker.tick(100)
        self.api.request.assert_not_called()
        self.assertEqual(self.host.load()["quarantine"], 100)
        self.host.command.assert_not_called()

    def test_operator_drain_waits_for_busy_job_without_replacement(self):
        worker = self.live_worker()
        self.runner(busy=True)
        self.assertTrue(worker.tick(100, draining=True))
        self.host.command.assert_not_called()
        self.host.container.return_value = None
        self.assertFalse(worker.tick(200, draining=True))
        self.host.launch.assert_not_called()
        self.assertFalse(self.host.load()["enabled"])

    def test_operator_drain_uses_the_same_quarantine_for_an_idle_worker(self):
        worker = self.live_worker(idle_deadline=100 + control.IDLE_SECONDS)
        worker.tick(100, draining=True)
        self.api.request.assert_called_once_with("/actions/runners/7/labels/docker-build", "DELETE")
        self.host.command.assert_not_called()
        self.runner(labels=[])
        self.host.container.side_effect = [
            {"id": "managed-container", "running": True}, None,
        ]
        self.assertFalse(worker.tick(160, draining=True))
        self.host.command.assert_called_once_with(["docker", "stop", "--time", "30", "managed-container"])

    def test_request_result_and_repeat_are_bound_to_run_attempt(self):
        self.api.demand.return_value = 0
        request = self.root / "requests/123-1.request"
        request.touch()
        control.process_requests(self.host)
        result = json.loads((self.root / "results/123-1.json").read_text())
        self.assertEqual(result, {"ok": True, "action": "no-op", "queued_jobs": 0, "request_id": "123-1"})
        request.touch()
        control.process_requests(self.host)
        self.api.demand.assert_called_once()
        (self.root / "requests/123-2.request").touch()
        control.process_requests(self.host)
        self.assertTrue((self.root / "results/123-2.json").exists())
        self.assertEqual(self.api.demand.call_count, 2)

    def test_symlink_payload_and_directory_requests_cannot_control_host(self):
        target = self.root / "do-not-touch"
        target.write_text("private")
        request = self.root / "requests/123-1.request"
        request.symlink_to(target)
        control.process_requests(self.host)
        self.assertEqual(target.read_text(), "private")
        self.assertFalse(json.loads((self.root / "results/123-1.json").read_text())["ok"])
        (self.root / "requests/123-2.request").write_text("https://github.com/other/repository")
        control.process_requests(self.host)
        self.assertFalse(json.loads((self.root / "results/123-2.json").read_text())["ok"])
        directory = self.root / "requests/123-3.request"
        directory.mkdir()
        (directory / "symlink").symlink_to(target)
        control.process_requests(self.host)
        self.assertFalse(directory.exists())
        self.assertEqual(target.read_text(), "private")
        self.api.demand.assert_not_called()

    def test_invalid_identifier_is_consumed_without_scan_or_result(self):
        for name in ("0-1.request", "123-0.request", "arbitrary-command", "123-1.json"):
            (self.root / "requests" / name).touch()
            control.process_requests(self.host)
        self.api.demand.assert_not_called()
        self.assertEqual(list((self.root / "results").iterdir()), [])
        self.assertEqual(list((self.root / "requests").iterdir()), [])

    def test_request_arriving_during_scan_is_not_lost(self):
        (self.root / "requests/123-1.request").touch()

        def demand():
            (self.root / "requests/456-1.request").touch()
            return 0

        self.api.demand.side_effect = demand
        control.process_requests(self.host)
        self.assertTrue((self.root / "requests/456-1.request").exists())
        self.api.demand.side_effect = None
        self.api.demand.return_value = 0
        control.process_requests(self.host)
        self.assertTrue((self.root / "results/456-1.json").exists())

    def test_malformed_persisted_state_fails_closed(self):
        self.host.state_path.write_text('{"enabled": true, "name": "../not-a-runner"}')
        with self.assertRaises(control.ControlError):
            control.Worker(self.host).tick(100)
        self.host.launch.assert_not_called()

    def test_wrong_compose_identity_prevents_container_management(self):
        self.host.command.side_effect = ["abc", "abc true some-other-project build-runner"]
        with self.assertRaisesRegex(control.ControlError, "Compose identity"):
            control.Host.container(self.host, "filius-build-" + "a" * 32)

    def test_ambiguous_docker_state_or_invalid_identity_is_not_treated_as_stopped(self):
        for fields in (
            "a" * 64 + " unknown filius-runners build-runner",
            "--unexpected-option false filius-runners build-runner",
        ):
            with self.subTest(fields=fields):
                self.host.command.side_effect = ["abc", fields]
                with self.assertRaises(control.ControlError):
                    control.Host.container(self.host, "filius-build-" + "a" * 32)


if __name__ == "__main__":
    unittest.main()
