#!/usr/bin/env bash
# Synthetic evidence tests for fail-closed release approval; not scan results.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

# make_evidence <dir> <findings-json> [exceptions-json]
# Writes a consistent, approved manifest over the given scan findings.
make_evidence() {
    python3 - "$@" <<'PY'
import datetime, hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1]); p.mkdir(parents=True, exist_ok=True)
findings = json.loads(sys.argv[2])
image = 'sha256:' + 'a' * 64
(p / 'scan.json').write_text(json.dumps(
    {'Metadata': {'ImageID': image}, 'Results': [{'Vulnerabilities': findings}]}))
(p / 'sbom.json').write_text('{}')
manifest = {
    'approved': True, 'source_commit': 'a' * 40,
    'vulnerability_db': {'UpdatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()},
    'artifacts': {'worker': {'image_id': image, 'registry_digest_verified': True}},
}
for kind in ('scan', 'sbom'):
    f = p / (kind + '.json')
    manifest['artifacts']['worker'][kind] = {'file': f.name, 'sha256': hashlib.sha256(f.read_bytes()).hexdigest()}
if len(sys.argv) > 3:
    f = p / 'exceptions.json'
    f.write_text(sys.argv[3])
    manifest['exceptions'] = {'file': f.name, 'sha256': hashlib.sha256(f.read_bytes()).hexdigest()}
(p / 'release-manifest.json').write_text(json.dumps(manifest))
PY
}
gate() { python3 "$ROOT/scripts/check-release.py" "$1"; }
day() { date -u -d "$1" +%Y-%m-%d; }

echo "== целостность и одобрение =="
make_evidence "$SB/clean" '[]'
assert_ok 'synthetic consistent approved evidence accepted' gate "$SB/clean"
echo tamper >> "$SB/clean/sbom.json"
assert_fail 'evidence tampering rejected' gate "$SB/clean"
make_evidence "$SB/unapproved" '[]'
python3 - "$SB/unapproved" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])/'release-manifest.json';d=json.loads(p.read_text());d['approved']=False;d['source_commit']=None;p.write_text(json.dumps(d))
PY
assert_fail 'unapproved working tree rejected' gate "$SB/unapproved"

echo "== исключения =="
HIGH='[{"VulnerabilityID":"CVE-2026-1","PkgName":"linux-libc-dev","Severity":"HIGH"}]'
FIXABLE='[{"VulnerabilityID":"CVE-2026-2","PkgName":"pacote","Severity":"HIGH","FixedVersion":"21.5.1"}]'
exc() {  # exc <id> <package> <expires> [reason] [owner]
    printf '{"exceptions":[{"artifact":"worker","id":"%s","package":"%s","expires":"%s","reason":"%s","owner":"%s"}]}' \
        "$1" "$2" "$3" "${4-headers only, kernel code not in image}" "${5-admin}"
}
make_evidence "$SB/high" "$HIGH"
assert_fail 'unexcepted HIGH blocks' gate "$SB/high"
make_evidence "$SB/excepted" "$HIGH" "$(exc CVE-2026-1 linux-libc-dev "$(day '+30 days')")"
assert_ok 'documented, current exception accepted' gate "$SB/excepted"
make_evidence "$SB/expired" "$HIGH" "$(exc CVE-2026-1 linux-libc-dev "$(day '-1 day')")"
out=$(gate "$SB/expired" 2>&1)
assert_ok 'expired exception blocks with a reason' grep -q 'expired' <<< "$out"
make_evidence "$SB/far" "$HIGH" "$(exc CVE-2026-1 linux-libc-dev "$(day '+200 days')")"
assert_fail 'exception longer than 90 days refused' gate "$SB/far"
make_evidence "$SB/noreason" "$HIGH" "$(exc CVE-2026-1 linux-libc-dev "$(day '+30 days')" '')"
assert_fail 'exception without a reason refused' gate "$SB/noreason"
make_evidence "$SB/noowner" "$HIGH" "$(exc CVE-2026-1 linux-libc-dev "$(day '+30 days')" 'reason' '')"
assert_fail 'exception without an owner refused' gate "$SB/noowner"
make_evidence "$SB/otherpkg" "$HIGH" "$(exc CVE-2026-1 perl-base "$(day '+30 days')")"
assert_fail 'exception for another package does not apply' gate "$SB/otherpkg"
make_evidence "$SB/fixable" "$FIXABLE" "$(exc CVE-2026-2 pacote "$(day '+30 days')")"
out=$(gate "$SB/fixable" 2>&1)
assert_ok 'fixable finding cannot be excepted' grep -q 'fix available' <<< "$out"
make_evidence "$SB/swapped" "$HIGH" "$(exc CVE-2026-1 linux-libc-dev "$(day '+30 days')")"
exc CVE-2026-1 linux-libc-dev "$(day '+80 days')" > "$SB/swapped/exceptions.json"
assert_fail 'exceptions file changed after approval' gate "$SB/swapped"
make_evidence "$SB/stale" '[]' "$(exc CVE-2026-9 linux-libc-dev "$(day '+30 days')")"
out=$(gate "$SB/stale" 2>&1)
assert_ok 'unused exception only warns' gate "$SB/stale"
assert_ok 'unused exception is reported' grep -q 'unused exception' <<< "$out"
finish
