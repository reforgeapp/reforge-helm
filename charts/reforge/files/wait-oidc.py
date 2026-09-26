import json
import os
import time
import urllib.error
import urllib.request

issuer = os.environ["OIDC_ISSUER"]
for attempt in range(120):
    try:
        with urllib.request.urlopen(issuer.rstrip("/") + "/.well-known/openid-configuration", timeout=10) as response:
            metadata = json.load(response)
        if metadata.get("issuer") == issuer and all(metadata.get(key) for key in ["authorization_endpoint", "token_endpoint", "jwks_uri"]):
            break
    except (OSError, ValueError, urllib.error.URLError):
        pass
    time.sleep(5)
else:
    raise SystemExit("OIDC discovery did not become ready; check issuer, DNS, TLS and provider provisioning")
