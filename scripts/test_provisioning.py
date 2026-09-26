import base64
import contextlib
import copy
import datetime
import importlib.util
import io
import json
import pathlib
import unittest
import urllib.error
from unittest import mock


path = pathlib.Path(__file__).parents[1] / "charts/reforge/files/provision-secrets.py"
spec = importlib.util.spec_from_file_location("provision_secrets", path)
provisioner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provisioner)


class FakeAPI:
    def __init__(self):
        self.secrets = {}
        self.created = []
        self.conflict = None

    def get(self, name):
        if name not in self.secrets:
            raise provisioner.APIError(404)
        return copy.deepcopy(self.secrets[name])

    def create(self, secret):
        name = secret["metadata"]["name"]
        self.created.append(copy.deepcopy(secret))
        if self.conflict is not None:
            self.secrets[name] = copy.deepcopy(self.conflict)
            raise provisioner.APIError(409)
        self.secrets[name] = copy.deepcopy(secret)
        return copy.deepcopy(secret)


class ProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.now = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
        self.config = {
            "namespace": "test",
            "release": "test",
            "bootstrapTTLHours": 24,
            "secrets": [
                {"name": "test-app", "kind": "app"},
                {"name": "test-database", "kind": "database"},
                {"name": "test-authentik", "kind": "authentik"},
            ],
        }

    def values(self, name):
        return {
            key: base64.b64decode(value).decode()
            for key, value in self.api.secrets[name]["data"].items()
        }

    def test_generated_values_have_required_entropy_and_formats(self):
        provisioner.provision(self.config, self.api, self.now)
        app = self.values("test-app")
        self.assertEqual(len(base64.b64decode(app["encryption-key"], validate=True)), 32)
        self.assertRegex(app["bootstrap-token"], r"^[0-9a-f]{64}$")
        self.assertEqual(app["bootstrap-expires-at"], "2026-01-02T00:00:00Z")
        passwords = list(self.values("test-database").values())
        authentik = self.values("test-authentik")
        for key in ("bootstrap-password", "database-password", "client-secret"):
            passwords.append(authentik[key])
        for password in passwords:
            self.assertRegex(password, r"^[0-9a-f]{64}$")
        self.assertEqual(len(set(passwords)), len(passwords))
        self.assertEqual(len(base64.urlsafe_b64decode(authentik["secret-key"] + "==")), 64)
        fresh = provisioner.generate_values("app", 24, self.now)
        self.assertNotEqual(fresh["encryption-key"], app["encryption-key"])
        self.assertNotEqual(fresh["bootstrap-token"], app["bootstrap-token"])

    def test_generated_secrets_avoid_argocd_tracking_labels_and_owner_cleanup(self):
        provisioner.provision(self.config, self.api, self.now)
        for secret in self.api.secrets.values():
            metadata = secret["metadata"]
            self.assertNotIn("app.kubernetes.io/instance", metadata["labels"])
            self.assertNotIn("ownerReferences", metadata)
            self.assertEqual(metadata["annotations"]["argocd.argoproj.io/sync-options"], "Prune=false,Delete=false")

    def test_existing_secrets_and_expired_bootstrap_remain_unchanged(self):
        provisioner.provision(self.config, self.api, self.now)
        initial = copy.deepcopy(self.api.secrets)
        self.api.created.clear()
        provisioner.provision(self.config, self.api, self.now + datetime.timedelta(days=365))
        self.assertEqual(self.api.secrets, initial)
        self.assertEqual(self.api.created, [])

    def test_concurrent_create_reuses_winner_without_rotation(self):
        provisioner.provision(self.config, self.api, self.now)
        winner = copy.deepcopy(self.api.secrets["test-app"])
        self.api = FakeAPI()
        self.api.conflict = winner
        self.config["secrets"] = self.config["secrets"][:1]
        provisioner.provision(self.config, self.api, self.now + datetime.timedelta(days=1))
        self.assertEqual(self.api.secrets["test-app"], winner)
        self.assertNotEqual(self.api.created[0]["data"], winner["data"])

    def test_existing_incomplete_secret_fails_without_mutation(self):
        provisioner.provision(self.config, self.api, self.now)
        del self.api.secrets["test-app"]["data"]["encryption-key"]
        initial = copy.deepcopy(self.api.secrets)
        self.api.created.clear()
        with self.assertRaisesRegex(provisioner.ProvisioningError, "refusing to rotate"):
            provisioner.provision(self.config, self.api, self.now)
        self.assertEqual(self.api.secrets, initial)
        self.assertEqual(self.api.created, [])

    def test_access_denied_never_attempts_creation(self):
        with mock.patch.object(self.api, "get", side_effect=provisioner.APIError(403)):
            with self.assertRaisesRegex(provisioner.APIError, "HTTP 403"):
                provisioner.provision(self.config, self.api, self.now)
        self.assertEqual(self.api.created, [])

    def test_http_error_body_and_credentials_never_reach_logs(self):
        api = object.__new__(provisioner.KubernetesAPI)
        api.token_path = "unused"
        api.url = "https://kubernetes.default.svc/api/v1/namespaces/test/secrets"
        api.context = None
        marker = "super-secret-do-not-log"
        failure = urllib.error.HTTPError(api.url, 500, marker, {}, io.BytesIO(marker.encode()))
        with mock.patch("builtins.open", mock.mock_open(read_data=marker)):
            with mock.patch("urllib.request.urlopen", side_effect=failure):
                with self.assertRaises(provisioner.APIError) as raised:
                    api.get("test-app")
        self.assertNotIn(marker, str(raised.exception))
        stderr = io.StringIO()
        with mock.patch("builtins.open", mock.mock_open(read_data=json.dumps(self.config))):
            with mock.patch.object(provisioner, "KubernetesAPI", return_value=self.api):
                with mock.patch.object(self.api, "get", side_effect=raised.exception):
                    with contextlib.redirect_stderr(stderr):
                        self.assertEqual(provisioner.main(), 1)
        self.assertIn("HTTP 500", stderr.getvalue())
        self.assertNotIn(marker, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
