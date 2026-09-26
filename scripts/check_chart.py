import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/reforge"


def render(values=None, expect_success=True):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as overrides:
        yaml.safe_dump(values or {}, overrides)
        overrides.flush()
        result = subprocess.run(
            ["helm", "template", "verify", str(CHART), "--namespace", "verify", "-f", overrides.name],
            text=True, capture_output=True, env={**os.environ, "KUBECONFIG": "/dev/null"},
        )
    if not expect_success:
        return result
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout, [resource for resource in yaml.safe_load_all(result.stdout) if resource]


def resource(resources, kind, suffix):
    return next(item for item in resources if item["kind"] == kind and item["metadata"]["name"] == "verify" + suffix)


class ChartTests(unittest.TestCase):
    def test_default_render_stable_and_credential_boundaries(self):
        first, resources = render()
        second, _ = render()
        self.assertEqual(first, second)
        self.assertFalse(any(item["kind"] == "Secret" for item in resources))
        config = resource(resources, "ConfigMap", "-provision")
        generated = json.loads(config["data"]["config.json"])["secrets"]
        self.assertEqual({item["kind"] for item in generated}, {"app", "database", "authentik"})
        pod = resource(resources, "Deployment", "-control")["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertNotIn("hostNetwork", pod)
        self.assertTrue(all("hostPath" not in volume for volume in pod["volumes"]))
        runner = next(item for item in pod["containers"] if item["name"] == "runner")
        self.assertEqual(runner["securityContext"]["runAsUser"], 10002)
        for container in pod["containers"]:
            security = container["securityContext"]
            self.assertFalse(security.get("privileged", False))
            self.assertFalse(security["allowPrivilegeEscalation"])
            self.assertEqual(security["capabilities"]["drop"], ["ALL"])
            self.assertNotIn("migration", {mount["name"] for mount in container["volumeMounts"]})
            keys = {item.get("valueFrom", {}).get("secretKeyRef", {}).get("key") for item in container.get("env", [])}
            self.assertNotIn("admin-password", keys)
            self.assertNotIn("migrator-password", keys)
        init = [item["name"] for item in pod["initContainers"]]
        self.assertLess(init.index("database-roles"), init.index("schema"))
        self.assertLess(init.index("schema"), init.index("runtime-grants"))
        self.assertLess(init.index("runtime-grants"), init.index("oidc-ready"))

    def test_external_services_remove_generation_and_bundles(self):
        values = yaml.safe_load((ROOT / "examples/external.yaml").read_text())
        values["runner"] = {"enabled": False}
        _, resources = render(values)
        names = {item["metadata"]["name"] for item in resources}
        self.assertNotIn("verify-provision", names)
        self.assertNotIn("verify-postgresql", names)
        self.assertNotIn("verify-auth-server", names)
        pod = resource(resources, "Deployment", "-control")["spec"]["template"]["spec"]
        self.assertEqual([item["name"] for item in pod["containers"]], ["control"])
        self.assertNotIn("database-roles", [item["name"] for item in pod["initContainers"]])
        self.assertIn("recipe-catalog", [item["name"] for item in pod["initContainers"]])
        control = pod["containers"][0]
        self.assertNotIn("REFORGE_BUILTIN_RUNNER_DIR", {item["name"] for item in control["env"]})
        self.assertEqual(next(volume for volume in pod["volumes"] if volume["name"] == "database-ca")["secret"]["secretName"], "postgres-ca")

    def test_byosecrets_skipped_and_tls_routing_agree(self):
        _, resources = render({
            "publicURL": "https://app.example.com:8443",
            "secrets": {"existingSecret": "app-keyring", "bootstrap": {"enabled": False}},
            "authentik": {"publicURL": "https://login.example.com:8443", "existingSecret": "identity-keyring", "ingress": {"tlsSecretName": "identity-tls"}},
            "postgresql": {"tls": {"existingSecret": "database-tls"}},
            "ingress": {"tlsSecretName": "app-tls"},
            "nodeSelector": {"pool": "automation"},
            "tolerations": [{"key": "automation", "operator": "Exists", "effect": "NoSchedule"}],
        })
        generated = json.loads(resource(resources, "ConfigMap", "-provision")["data"]["config.json"])["secrets"]
        self.assertEqual(generated, [{"kind": "database", "name": "verify-database"}])
        for suffix, host in [("", "app.example.com"), ("-authentik", "login.example.com")]:
            ingress = resource(resources, "Ingress", suffix)
            self.assertEqual(ingress["spec"]["rules"][0]["host"], host)
            self.assertEqual(ingress["spec"]["tls"][0]["hosts"], [host])
        blueprint = resource(resources, "ConfigMap", "-authentik-blueprint")["data"]["reforge.yaml"]
        self.assertIn("https://app.example.com:8443/auth/callback", blueprint)
        self.assertIn("signing_key: !Find", blueprint)
        self.assertIn("client_secret: !Env REFORGE_OIDC_CLIENT_SECRET", blueprint)
        for deployment in [item for item in resources if item["kind"] == "Deployment"]:
            pod = deployment["spec"]["template"]["spec"]
            self.assertEqual(pod["nodeSelector"], {"kubernetes.io/arch": "amd64", "pool": "automation"})
            self.assertEqual(pod["tolerations"][0]["key"], "automation")

    def test_unsafe_or_incomplete_values_fail_before_install(self):
        cases = [
            {"publicURL": "http://app.example.com"},
            {"publicURL": "https://app.example.com/path"},
            {"postgresql": {"enabled": False}},
            {"authentik": {"enabled": False}},
            {"runner": {"slots": 0}},
            {"secrets": {"bootstrap": {"ttlHours": 0}}},
        ]
        for values in cases:
            with self.subTest(values=values):
                self.assertNotEqual(render(values, expect_success=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
