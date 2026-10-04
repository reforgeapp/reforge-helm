import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
IMAGES = ("go", "javascript", "python", "maintenance")


def replace_once(text, pattern, replacement):
    updated, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"expected one match for {pattern}, found {count}")
    return updated


def sync(version, digests, root=ROOT):
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError("release version must be semantic versioning without a prefix")
    if set(digests) != set(IMAGES) or any(not DIGEST.fullmatch(value) for value in digests.values()):
        raise ValueError("workspace image digests must be complete SHA-256 values")
    chart_path = root / "charts/reforge/Chart.yaml"
    values_path = root / "charts/reforge/values.yaml"
    chart = chart_path.read_text()
    current_match = re.search(r'^appVersion: "([0-9]+\.[0-9]+\.[0-9]+)"$', chart, re.MULTILINE)
    chart_match = re.search(r"^version: ([0-9]+)\.([0-9]+)\.([0-9]+)$", chart, re.MULTILINE)
    if current_match is None or chart_match is None:
        raise ValueError("chart versions are missing")
    current = tuple(map(int, current_match.group(1).split(".")))
    incoming = tuple(map(int, match.groups()))
    if incoming < current:
        raise ValueError("refusing to downgrade Reforge")
    if incoming == current:
        return None
    next_chart = f"{chart_match.group(1)}.{chart_match.group(2)}.{int(chart_match.group(3)) + 1}"
    chart = replace_once(chart, r"^version: [0-9]+\.[0-9]+\.[0-9]+$", f"version: {next_chart}")
    chart = replace_once(chart, r'^appVersion: "[0-9]+\.[0-9]+\.[0-9]+"$', f'appVersion: "{version}"')
    values = values_path.read_text()
    for name, digest in digests.items():
        values = replace_once(values, rf"^(      {name}: ghcr\.io/reforgeapp/reforge-workspace-{name}@)sha256:[0-9a-f]{{64}}$", rf"\g<1>{digest}")
    chart_path.write_text(chart)
    values_path.write_text(values)
    return next_chart


def main():
    if len(sys.argv) != 2 + len(IMAGES):
        raise SystemExit("usage: sync_reforge_release.py VERSION GO_DIGEST JAVASCRIPT_DIGEST PYTHON_DIGEST MAINTENANCE_DIGEST")
    chart_version = sync(sys.argv[1], dict(zip(IMAGES, sys.argv[2:])))
    if chart_version:
        print(chart_version)


if __name__ == "__main__":
    main()
