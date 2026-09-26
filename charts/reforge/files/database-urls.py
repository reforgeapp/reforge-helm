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
    path.write_text(variable + "=" + shlex.quote(url) + "\n")
    path.chmod(0o640)
