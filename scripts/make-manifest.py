#!/usr/bin/env python3
"""Merges freshly built packages into manifest.json, which Rigly reads to find downloads.

    make-manifest.py <artifacts dir> <owner/repo> [existing manifest.json] > manifest.json

Each build contributes php-<version>-<platform>-<arch>.{tar.gz|zip,.sha256,json}
(macOS: php-8.4.27-macos-aarch64.tar.gz, Windows: php-8.4.27-windows-x64.zip). Entries for PHP
versions not rebuilt this run are kept from the existing manifest.
"""
import datetime
import glob
import json
import os
import sys


def main() -> None:
    artifacts, repo = sys.argv[1], sys.argv[2]
    existing = sys.argv[3] if len(sys.argv) > 3 else None
    manifest = {"schema": 1, "php": {}}
    if existing and os.path.exists(existing):
        with open(existing) as f:
            manifest = json.load(f)

    for meta_path in sorted(glob.glob(os.path.join(artifacts, "**", "php-*.json"), recursive=True)):
        with open(meta_path) as f:
            build = json.load(f)
        version, arch = build["php"], build["arch"]
        minor = ".".join(version.split(".")[:2])
        base = os.path.basename(meta_path)[: -len(".json")]
        candidates = [os.path.join(os.path.dirname(meta_path), base + ext) for ext in (".tar.gz", ".zip")]
        tarball = next((c for c in candidates if os.path.exists(c)), None)
        if tarball is None:
            print(f"warning: no archive for {meta_path}", file=sys.stderr)
            continue
        with open(tarball + ".sha256") as f:
            sha256 = f.read().strip()

        entry = manifest["php"].get(minor)
        # A new patch release replaces the entry (and its per-arch assets) wholesale.
        if entry is None or entry["version"] != version:
            entry = {"version": version, "assets": {}}
        entry["assets"][arch] = {
            "url": f"https://github.com/{repo}/releases/download/php-{version}/{os.path.basename(tarball)}",
            "sha256": sha256,
            "size": os.path.getsize(tarball),
            "extensions": build["extensions"],
            "shared": build["shared"],
            **({"build": build["build"]} if "build" in build else {}),
            "built_at": build["built_at"],
        }
        manifest["php"][minor] = entry

    manifest["php"] = dict(sorted(manifest["php"].items(), key=lambda kv: [int(p) for p in kv[0].split(".")]))
    manifest["updated"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    json.dump(manifest, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
