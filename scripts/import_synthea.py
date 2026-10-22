#!/usr/bin/env python3
"""POST Synthea FHIR R4 transaction bundles to a FHIR server, one per file.

Usage: python3 -I import_synthea.py <bundle_dir> [base_url]
Keep this script outside the bundle directory (the bundles are downloaded data).
"""
import pathlib
import sys
import urllib.error
import urllib.request

bundle_dir = pathlib.Path(sys.argv[1])
base_url = (sys.argv[2] if len(sys.argv) > 2 else "http://localhost:8080/fhir").rstrip("/")

ok = failed = 0
for path in sorted(bundle_dir.glob("*.json")):
    body = path.read_bytes()
    req = urllib.request.Request(
        base_url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/fhir+json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            resp.read()
        ok += 1
    except urllib.error.HTTPError as exc:
        failed += 1
        print(f"FAIL {path.name}: HTTP {exc.code} {exc.read()[:200]!r}", file=sys.stderr)
    except urllib.error.URLError as exc:
        failed += 1
        print(f"FAIL {path.name}: {exc.reason}", file=sys.stderr)
    if (ok + failed) % 50 == 0:
        print(f"progress: ok={ok} failed={failed}", flush=True)

print(f"done: ok={ok} failed={failed}")
