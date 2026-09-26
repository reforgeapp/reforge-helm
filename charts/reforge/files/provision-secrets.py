import base64
import datetime
import json
import os
import secrets
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


class ProvisioningError(Exception):
    pass


class APIError(ProvisioningError):
    def __init__(self, status):
        self.status = status
        super().__init__(f"Kubernetes API returned HTTP {status}.")


class KubernetesAPI:
    def __init__(self, namespace):
        self.token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        self.context = ssl.create_default_context(
            cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        )
        host = os.environ["KUBERNETES_SERVICE_HOST"]
        if ":" in host:
            host = f"[{host}]"
        port = os.environ.get("KUBERNETES_SERVICE_PORT_HTTPS", "443")
        self.url = (
            f"https://{host}:{port}/api/v1/namespaces/"
            f"{urllib.parse.quote(namespace, safe='')}/secrets"
        )

    def request(self, method, name=None, body=None):
        with open(self.token_path, encoding="utf-8") as token_file:
            token = token_file.read().strip()
        url = self.url
        if name is not None:
            url += "/" + urllib.parse.quote(name, safe="")
        request = urllib.request.Request(
            url,
            data=None if body is None else json.dumps(body).encode("utf-8"),
            headers={
                "Authorization": "Bearer " + token,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method=method,
        )
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=15) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise APIError(error.code) from None
        except urllib.error.URLError:
            raise ProvisioningError("Kubernetes API connection failed.") from None
        except (ValueError, UnicodeError):
            raise ProvisioningError("Kubernetes API returned invalid JSON.") from None

    def get(self, name):
        return self.request("GET", name=name)

    def create(self, body):
        return self.request("POST", body=body)


REQUIRED_KEYS = {
    "app": ("encryption-key", "bootstrap-token", "bootstrap-expires-at"),
    "database": ("admin-password", "migrator-password", "runtime-password"),
    "authentik": ("secret-key", "bootstrap-password", "database-password", "client-secret"),
}


def validate_existing(secret, kind):
    data = secret.get("data", {})
    for key in REQUIRED_KEYS[kind]:
        try:
            value = base64.b64decode(data[key], validate=True)
            if not value:
                raise ValueError
            if kind == "app" and key == "encryption-key":
                if len(base64.b64decode(value, validate=True)) != 32:
                    raise ValueError
        except (KeyError, ValueError, TypeError):
            raise ProvisioningError(
                f"Existing {kind} Secret has a missing or invalid {key}; refusing to rotate it."
            ) from None


def generate_values(kind, ttl_hours, now):
    if kind == "app":
        expiry = now + datetime.timedelta(hours=ttl_hours)
        return {
            "encryption-key": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
            "bootstrap-token": secrets.token_hex(32),
            "bootstrap-expires-at": expiry.isoformat(timespec="seconds").replace("+00:00", "Z"),
        }
    if kind == "database":
        return {key: secrets.token_hex(32) for key in REQUIRED_KEYS[kind]}
    if kind == "authentik":
        return {
            "secret-key": secrets.token_urlsafe(64),
            "bootstrap-password": secrets.token_hex(32),
            "database-password": secrets.token_hex(32),
            "client-secret": secrets.token_hex(32),
        }
    raise ProvisioningError("Unknown Secret kind in configuration.")


def provision(config, api, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    ttl_hours = int(config["bootstrapTTLHours"])
    if ttl_hours <= 0:
        raise ProvisioningError("Bootstrap TTL must be positive.")
    for item in config["secrets"]:
        name = item["name"]
        kind = item["kind"]
        if kind not in REQUIRED_KEYS:
            raise ProvisioningError("Unknown Secret kind in configuration.")
        try:
            existing = api.get(name)
        except APIError as error:
            if error.status != 404:
                raise
        else:
            validate_existing(existing, kind)
            continue
        values = generate_values(kind, ttl_hours, now)
        secret = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": name,
                "namespace": config["namespace"],
                "labels": {
                    "reforgeapp.dev/release": config["release"],
                    "app.kubernetes.io/managed-by": "reforge-provisioner",
                },
                "annotations": {
                    "helm.sh/resource-policy": "keep",
                    "argocd.argoproj.io/sync-options": "Prune=false,Delete=false",
                },
            },
            "type": "Opaque",
            "data": {
                key: base64.b64encode(value.encode("utf-8")).decode("ascii")
                for key, value in values.items()
            },
        }
        try:
            created = api.create(secret)
        except APIError as error:
            if error.status != 409:
                raise
            created = api.get(name)
        validate_existing(created, kind)
    return len(config["secrets"])


def main():
    try:
        with open("/provisioning/config.json", encoding="utf-8") as config_file:
            config = json.load(config_file)
        count = provision(config, KubernetesAPI(config["namespace"]))
    except ProvisioningError as error:
        print(f"Secret provisioning failed: {error}", file=sys.stderr)
        return 1
    except (OSError, KeyError, ValueError, TypeError, OverflowError):
        print("Secret provisioning failed: invalid configuration or unavailable service account.", file=sys.stderr)
        return 1
    print(f"Secret provisioning complete: {count} Secrets ready.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
