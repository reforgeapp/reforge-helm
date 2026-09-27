import json
import os
import time
import urllib.error
import urllib.request

issuer = os.environ["OIDC_ISSUER"]
request = urllib.request.Request(
    issuer.rstrip("/") + "/.well-known/openid-configuration",
    headers={"User-Agent": "reforge-oidc-ready/1.0"},
)
last_error = None
for attempt in range(120):
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            metadata = json.load(response)
        if metadata.get("issuer") == issuer and all(metadata.get(key) for key in ["authorization_endpoint", "token_endpoint", "jwks_uri"]):
            break
    except (OSError, ValueError, urllib.error.URLError) as error:
        last_error = error
    time.sleep(5)
else:
    raise SystemExit(f"OIDC discovery did not become ready: {last_error}")
