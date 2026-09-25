#!/usr/bin/env python3
"""Fail closed on unreviewed/mismatched/stale scan evidence. No registry writes."""
import datetime as dt
import gzip
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else 'docs/security-remediation')
manifest = json.loads((root / 'release-manifest.json').read_text())
errors = []
if not manifest.get('approved'):
    errors.append('candidate is not approved')
if not manifest.get('source_commit'):
    errors.append('final source commit is not recorded')
metadata = manifest['vulnerability_db']
updated = dt.datetime.fromisoformat(metadata['UpdatedAt'].replace('Z', '+00:00'))
if dt.datetime.now(dt.timezone.utc) - updated > dt.timedelta(hours=24):
    errors.append('vulnerability DB evidence older than 24 hours: rescan')
for name, artifact in manifest['artifacts'].items():
    for kind in ('scan', 'sbom'):
        path = root / artifact[kind]['file']
        if hashlib.sha256(path.read_bytes()).hexdigest() != artifact[kind]['sha256']:
            errors.append(f'{name}: {kind} checksum mismatch')
    path = root / artifact['scan']['file']
    scan = json.loads(gzip.decompress(path.read_bytes()) if path.suffix == '.gz' else path.read_bytes())
    if scan.get('Metadata', {}).get('ImageID') != artifact['image_id']:
        errors.append(f'{name}: scan image identity mismatch')
    vulns = [v for r in scan.get('Results', []) for v in r.get('Vulnerabilities', [])]
    if any(v['Severity'] in ('HIGH', 'CRITICAL') for v in vulns):
        errors.append(f'{name}: unresolved HIGH/CRITICAL findings')
    if not artifact.get('registry_digest_verified'):
        errors.append(f'{name}: distribution digest not verified in release registry')
if errors:
    print('\n'.join('BLOCKED: ' + error for error in errors))
    raise SystemExit(1)
print('release evidence gate passed')
