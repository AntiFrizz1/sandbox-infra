#!/usr/bin/env python3
"""Fail closed on unreviewed/mismatched/stale scan evidence. No registry writes.

A HIGH/CRITICAL finding blocks the release unless an exception names the
same artifact, vulnerability ID and package, gives a reason and an owner,
and expires within 90 days. A finding with a fixed version available cannot
be excepted: it has to be fixed. The exceptions file is covered by the
manifest checksum, so an approval covers exactly that set.
"""
import datetime as dt
import gzip
import hashlib
import json
import re
from pathlib import Path
import sys

MAX_EXCEPTION_DAYS = 90

root = Path(sys.argv[1] if len(sys.argv) > 1 else 'docs/security-remediation')
manifest = json.loads((root / 'release-manifest.json').read_text())
errors = []
warnings = []
today = dt.datetime.now(dt.timezone.utc).date()


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


if not manifest.get('approved'):
    errors.append('candidate is not approved')
if not manifest.get('source_commit'):
    errors.append('final source commit is not recorded')
metadata = manifest['vulnerability_db']
updated = dt.datetime.fromisoformat(metadata['UpdatedAt'].replace('Z', '+00:00'))
if dt.datetime.now(dt.timezone.utc) - updated > dt.timedelta(hours=24):
    errors.append('vulnerability DB evidence older than 24 hours: rescan')

exceptions = {}
if 'exceptions' in manifest:
    path = root / manifest['exceptions']['file']
    if sha256(path) != manifest['exceptions']['sha256']:
        errors.append('exceptions file checksum mismatch')
    for entry in json.loads(path.read_text()).get('exceptions', []):
        key = (entry.get('artifact'), entry.get('id'), entry.get('package'))
        problems = []
        if not str(entry.get('reason', '')).strip():
            problems.append('no reason')
        if not str(entry.get('owner', '')).strip():
            problems.append('no owner')
        try:
            expires = dt.date.fromisoformat(entry.get('expires', ''))
            if expires < today:
                problems.append(f'expired {expires}')
            elif (expires - today).days > MAX_EXCEPTION_DAYS:
                problems.append(f'expires later than {MAX_EXCEPTION_DAYS} days')
        except (TypeError, ValueError):
            problems.append('no valid expiry date')
        exceptions[key] = {'problems': problems, 'used': False}

for name, artifact in manifest['artifacts'].items():
    for kind in ('scan', 'sbom'):
        path = root / artifact[kind]['file']
        if sha256(path) != artifact[kind]['sha256']:
            errors.append(f'{name}: {kind} checksum mismatch')
    path = root / artifact['scan']['file']
    scan = json.loads(gzip.decompress(path.read_bytes()) if path.suffix == '.gz' else path.read_bytes())
    if scan.get('Metadata', {}).get('ImageID') != artifact['image_id']:
        errors.append(f'{name}: scan image identity mismatch')
    blocking = 0
    for result in scan.get('Results', []):
        for vuln in result.get('Vulnerabilities') or []:
            if vuln['Severity'] not in ('HIGH', 'CRITICAL'):
                continue
            ref = f"{name}: {vuln['VulnerabilityID']} in {vuln['PkgName']}"
            exception = exceptions.get((name, vuln['VulnerabilityID'], vuln['PkgName']))
            if exception:
                exception['used'] = True
            if vuln.get('FixedVersion'):
                errors.append(f"{ref}: fix available ({vuln['FixedVersion']}), exceptions do not apply")
            elif exception is None:
                blocking += 1
            elif exception['problems']:
                errors.append(f"{ref}: exception {', '.join(exception['problems'])}")
    if blocking:
        errors.append(f'{name}: {blocking} unresolved HIGH/CRITICAL findings without exception')
    # The image reaches the server either by a verified registry digest or as
    # an archive whose checksum load-image.sh verifies; the archive must come
    # from the scanned image.
    dist = artifact.get('distribution') or {}
    archive_ok = (dist.get('type') == 'archive'
                  and re.fullmatch(r'[a-f0-9]{64}', str(dist.get('sha256', '')))
                  and dist.get('image_id') == artifact['image_id'])
    if not artifact.get('registry_digest_verified') and not archive_ok:
        if dist.get('type') == 'archive':
            errors.append(f'{name}: archive does not come from the scanned image')
        else:
            errors.append(f'{name}: no verified distribution (registry digest or export-image.sh archive)')

for (name, vid, package), exception in exceptions.items():
    if not exception['used']:
        warnings.append(f'unused exception {name} {vid} {package}: remove it')

for line in warnings:
    print('WARNING: ' + line)
if errors:
    print('\n'.join('BLOCKED: ' + error for error in errors))
    raise SystemExit(1)
print('release evidence gate passed')
