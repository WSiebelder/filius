import concurrent.futures
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("token_broker", ROOT / "token-broker/broker.py")
broker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(broker)


class BrokerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "state").mkdir()
        eligibility = self.root / "eligible.json"
        self.repository = "https://github.com/WSiebelder/filius"
        eligibility.write_text(json.dumps({"build_repositories": [self.repository]}))
        environment = patch.dict(os.environ, {
            "GITHUB_URL": self.repository,
            "FILIUS_CONTROL_DIR": str(self.root),
            "FILIUS_ELIGIBILITY_FILE": str(eligibility),
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.host = broker.Host()
        self.api = Mock()
        self.api.request.return_value = {"token": "short-lived-test-token"}
        self.host.api = Mock(return_value=self.api)
        self.broker = broker.Broker(self.host)
        self.name = "filius-build-test"

    def authorize(self):
        return self.broker.authorize(self.repository, self.name, "build")

    def test_one_token_per_authorized_instance_survives_broker_restart(self):
        instance = self.authorize()
        self.assertEqual(self.broker.issue(instance, self.repository, self.name),
                         {"token": "short-lived-test-token"})
        with self.assertRaises(broker.Rejected) as caught:
            broker.Broker(self.host).issue(instance, self.repository, self.name)
        self.assertEqual(caught.exception.status, 409)
        self.api.request.assert_called_once_with("/actions/runners/registration-token", "POST")
        self.assertNotIn("short-lived-test-token", self.broker.path.read_text())

    def test_unknown_wrong_repository_or_wrong_name_never_calls_github(self):
        instance = self.authorize()
        for values in (
            ("b" * 32, self.repository, self.name),
            (instance, "https://github.com/another/repository", self.name),
            (instance, self.repository, "another-runner"),
            (None, self.repository, self.name),
        ):
            with self.subTest(values=values), self.assertRaises(broker.Rejected):
                self.broker.issue(*values)
        self.api.request.assert_not_called()
        self.assertEqual(self.broker.issue(instance, self.repository, self.name)["token"],
                         "short-lived-test-token")

    def test_failed_github_call_consumes_grant_without_exposing_failure_contents(self):
        instance = self.authorize()
        self.host.api.side_effect = broker.ControlError("test-only-private-credential")
        with self.assertRaises(broker.Rejected) as caught:
            self.broker.issue(instance, self.repository, self.name)
        self.assertEqual(caught.exception.status, 502)
        self.assertNotIn("test-only-private-credential", str(caught.exception))
        with self.assertRaises(broker.Rejected) as caught:
            self.broker.issue(instance, self.repository, self.name)
        self.assertEqual(caught.exception.status, 409)
        self.host.api.assert_called_once()

    def test_expired_or_revoked_grants_cannot_be_used(self):
        with patch.object(broker.time, "time", return_value=100):
            instance = self.authorize()
        with patch.object(broker.time, "time", return_value=401):
            with self.assertRaisesRegex(broker.Rejected, "expired"):
                self.broker.issue(instance, self.repository, self.name)
        self.broker.revoke(instance)
        self.broker.revoke(instance)
        with self.assertRaisesRegex(broker.Rejected, "No matching"):
            self.broker.issue(instance, self.repository, self.name)
        self.api.request.assert_not_called()

    def test_new_instances_and_broker_restart_cannot_reset_cooldown(self):
        with patch.object(broker.time, "time", return_value=100):
            for _ in range(broker.REQUEST_LIMIT):
                instance = self.authorize()
                self.broker.issue(instance, self.repository, self.name)
                self.broker.revoke(instance)
            instance = self.authorize()
            with self.assertRaises(broker.Rejected) as caught:
                broker.Broker(self.host).issue(instance, self.repository, self.name)
            self.assertEqual(caught.exception.status, 429)
            with self.assertRaises(broker.Rejected) as caught:
                self.broker.issue(instance, self.repository, self.name)
            self.assertEqual(caught.exception.status, 409)
            self.assertEqual(self.api.request.call_count, broker.REQUEST_LIMIT)
        with patch.object(broker.time, "time", return_value=161):
            instance = self.authorize()
            self.broker.issue(instance, self.repository, self.name)
        self.assertEqual(self.api.request.call_count, broker.REQUEST_LIMIT + 1)

    def test_concurrent_requests_only_mint_once(self):
        instance = self.authorize()

        def issue(_):
            try:
                self.broker.issue(instance, self.repository, self.name)
                return 200
            except broker.Rejected as error:
                return error.status

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(issue, range(2)))
        self.assertEqual(sorted(results), [200, 409])
        self.api.request.assert_called_once()

    def test_invalid_installed_state_does_not_silently_reset_the_guard(self):
        for value in ({"grants": {}, "attempts": ["invalid"]},
                      {"grants": {"a" * 32: {}}, "attempts": []}):
            with self.subTest(value=value):
                self.broker.path.write_text(json.dumps(value))
                with self.assertRaises(broker.ControlError):
                    self.authorize()
        self.api.request.assert_not_called()

    def test_host_authorization_rejects_bad_scope_and_unsafe_names(self):
        for arguments in (
            ("https://github.com/another/repository", self.name, "build"),
            (self.repository, "../not-a-runner", "build"),
            (self.repository, self.name, "arbitrary-command"),
        ):
            with self.subTest(arguments=arguments), self.assertRaises(broker.ControlError):
                self.broker.authorize(*arguments)
        self.assertFalse(self.broker.path.exists())

    def start_server(self):
        path = self.root / "broker.sock"
        server = broker.Server(path, self.broker)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()

        def cleanup():
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

        self.addCleanup(cleanup)
        return path

    def request(self, path, method, endpoint, body=None, headers=None):
        connection = http.client.HTTPConnection("localhost", timeout=3)
        connection.sock = socket.socket(socket.AF_UNIX)
        connection.sock.settimeout(3)
        connection.sock.connect(str(path))
        try:
            connection.request(method, endpoint, body=body,
                               headers={"Content-Type": "application/json", **(headers or {})})
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_unix_http_interface_only_supports_health_and_token_requests(self):
        path = self.start_server()
        self.assertEqual(self.request(path, "GET", "/health"), (200, {"ok": True}))
        self.assertEqual(self.request(path, "POST", "/run-command")[0], 404)
        self.assertEqual(self.request(path, "POST", "/token", '{"command":"anything"}')[0], 400)
        self.assertEqual(self.request(path, "POST", "/token",
                                      headers={"Content-Length": "2049"})[0], 400)
        self.api.request.assert_not_called()

    def test_container_client_fetches_once_and_duplicate_does_not_mint_or_leak_token(self):
        instance = self.authorize()
        path = self.start_server()
        environment = dict(os.environ, GITHUB_URL=self.repository, RUNNER_NAME=self.name,
                           FILIUS_RUNNER_INSTANCE=instance, FILIUS_TOKEN_SOCKET=str(path))
        command = ["/bin/bash", str(ROOT / "build-runner/runner-token.sh")]
        first = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout.strip(), "short-lived-test-token")
        second = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=5)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("startup grants are not retried", second.stderr)
        self.assertNotIn("short-lived-test-token", second.stdout + second.stderr)
        self.api.request.assert_called_once()


class LauncherTests(unittest.TestCase):
    def test_help_and_invalid_modes_do_not_touch_host_prerequisites(self):
        launcher = str(ROOT / "build-runner/run.sh")
        result = subprocess.run(["/bin/bash", launcher, "--help"],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--once", result.stdout)
        self.assertIn("--all", result.stdout)
        self.assertIn("--service", result.stdout)
        for arguments in ([], ["--continuous", "https://github.com/WSiebelder/filius"],
                          ["--once"], ["--once", "not-a-repository"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run(["/bin/bash", launcher] + arguments,
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2)

    def test_non_build_roles_cannot_start_a_second_long_running_supervisor(self):
        for role in ("deploy", "orchestration"):
            environment = dict(os.environ, RUNNER_KIND=role)
            result = subprocess.run(
                ["/bin/bash", str(ROOT / "build-runner/run.sh"), "--service",
                 "https://github.com/WSiebelder/filius"],
                env=environment, capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("only the installed build worker", result.stderr)


class EntrypointTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        tools = self.root / "tools"
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text('#!/bin/bash\nprintf \'{"tag_name":"v2.338.2"}\\n\'\n')
        curl.chmod(0o755)
        self.helper = tools / "runner-token"
        self.helper.write_text(
            '#!/bin/bash\nprintf "called\\n" >> "$TOKEN_CALLS"\nprintf "broker-test-token\\n"\n'
        )
        self.helper.chmod(0o755)
        config = self.root / "config.sh"
        config.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARGUMENT_FILE"\n')
        config.chmod(0o755)
        run = self.root / "run.sh"
        run.write_text(
            '#!/bin/bash\nprintf "%s:%s\\n" "${RUNNER_TOKEN-unset}" '
            '"${FILIUS_RUNNER_INSTANCE-unset}" > "$ENV_FILE"\n'
        )
        run.chmod(0o755)
        self.environment = dict(
            os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
            GITHUB_URL="https://github.com/WSiebelder/filius",
            RUNNER_NAME="test-runner", RUNNER_VERSION="2.338.2",
            RUNNER_EPHEMERAL="true", FILIUS_RUNNER_INSTANCE="a" * 32,
            RUNNER_TOKEN="legacy-test-token",
            TOKEN_CALLS=str(self.root / "calls"), ARGUMENT_FILE=str(self.root / "arguments"),
            ENV_FILE=str(self.root / "environment"),
        )

    def run_entrypoint(self):
        script = (ROOT / "build-runner/runner-entrypoint.sh").read_text()
        script = script.replace("/usr/local/bin/runner-token", str(self.helper))
        return subprocess.run(
            ["/bin/bash", "-c", script], cwd=self.root, env=self.environment,
            capture_output=True, text=True, timeout=5,
        )

    def test_broker_token_wins_and_startup_credentials_do_not_enter_job_environment(self):
        result = self.run_entrypoint()
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = (self.root / "arguments").read_text()
        self.assertIn("broker-test-token", arguments)
        self.assertNotIn("legacy-test-token", arguments)
        self.assertIn("--ephemeral\n", arguments)
        self.assertIn("--disableupdate\n", arguments)
        self.assertEqual((self.root / "calls").read_text(), "called\n")
        self.assertEqual((self.root / "environment").read_text(), "unset:unset\n")
        self.assertNotIn("broker-test-token", result.stdout + result.stderr)

    def test_failed_broker_request_does_not_fall_back_to_an_inherited_token(self):
        self.helper.write_text('#!/bin/bash\nexit 1\n')
        result = self.run_entrypoint()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "arguments").exists())
        self.assertFalse((self.root / "environment").exists())

    def test_pre_broker_installed_runtime_can_upgrade_images_first(self):
        self.environment.pop("FILIUS_RUNNER_INSTANCE")
        result = self.run_entrypoint()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Legacy registration-token startup", result.stderr)
        self.assertIn("legacy-test-token", (self.root / "arguments").read_text())
        self.assertFalse((self.root / "calls").exists())
        self.assertEqual((self.root / "environment").read_text(), "unset:unset\n")


if __name__ == "__main__":
    unittest.main()
