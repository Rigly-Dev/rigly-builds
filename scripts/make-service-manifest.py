#!/usr/bin/env python3
"""Merges built service packages into a manifest:
    make-service-manifest.py <product> <artifacts dir> <owner/repo> <previous manifest>
Output: {"schema": 1, "<product>": {"<series>": {"version": ..., "assets": {"<arch>": {url, sha256, size}}}}}
Series is major.minor (MariaDB "11.8"), or "latest" for products without series (MinIO)."""
import glob, json, os, sys

product, artifacts, repo, previous = sys.argv[1:5]
manifest = json.load(open(previous))
manifest.setdefault("schema", 1)
entries = manifest.setdefault(product, {})
for meta_path in sorted(glob.glob(os.path.join(artifacts, "*", f"{product}-*.json"))):
    meta = json.load(open(meta_path))
    version, arch = meta["version"], meta["arch"]
    series = meta.get("series") or ".".join(version.split(".")[:2])
    base = meta_path[:-5]
    archive = next(p for p in (base + ".tar.gz", base + ".zip", base) if os.path.isfile(p) and p != meta_path)
    name = os.path.basename(archive)
    tag = meta.get("tag", f"{product}-{version}")
    entry = entries.get(series)
    if not entry or entry.get("version") != version:
        entry = {"version": version, "assets": {}}
    entry["assets"][arch] = {
        "url": f"https://github.com/{repo}/releases/download/{tag}/{name}",
        "sha256": open(archive + ".sha256").read().split()[0],
        "size": os.path.getsize(archive),
    }
    entries[series] = entry
print(json.dumps(manifest, indent=2, sort_keys=True))
