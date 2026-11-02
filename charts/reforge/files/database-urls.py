import os
import shlex
from pathlib import Path
from urllib.parse import quote, urlencode

os.umask(0o027)
query = {"sslmode": os.environ["DATABASE_SSLMODE"]}
if os.environ.get("DATABASE_CA"):
    query["sslrootcert"] = os.environ["DATABASE_CA"]
host = os.environ["DATABASE_HOST"]
if ":" in host:
    host = "[" + host + "]"
for role, directory, variable in [
    ("RUNTIME", "/database", "REFORGE_DATABASE_URL"),
    ("MIGRATOR", "/migration", "REFORGE_MIGRATION_DATABASE_URL"),
]:
    user = quote(os.environ[role + "_USER"], safe="")
    password = quote(os.environ[role + "_PASSWORD"], safe="")
    name = quote(os.environ["DATABASE_NAME"], safe="")
    url = f"postgresql://{user}:{password}@{host}:{os.environ['DATABASE_PORT']}/{name}?{urlencode(query)}"
    path = Path(directory) / ("runtime.env" if role == "RUNTIME" else "migration.env")
    lines = variable + "=" + shlex.quote(url) + "\n"
    if role == "RUNTIME" and os.environ.get("STAFF_PASSWORD"):
        staff = quote(os.environ["STAFF_USER"], safe="")
        secret = quote(os.environ["STAFF_PASSWORD"], safe="")
        lines += "REFORGE_STAFF_DATABASE_URL=" + shlex.quote(f"postgresql://{staff}:{secret}@{host}:{os.environ['DATABASE_PORT']}/{name}?{urlencode(query)}") + "\n"
    path.write_text(lines)
    path.chmod(0o640)
