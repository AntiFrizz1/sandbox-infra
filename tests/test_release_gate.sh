#!/usr/bin/env bash
# Synthetic evidence tests for fail-closed release approval; not scan results.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT
python3 - "$SB" <<'PY'
import datetime,hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); image='sha256:'+'a'*64
(p/'scan.json').write_text(json.dumps({'Metadata':{'ImageID':image},'Results':[]}))
(p/'sbom.json').write_text('{}')
manifest={'approved':True,'source_commit':'a'*40,'vulnerability_db':{'UpdatedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()},'artifacts':{'synthetic':{'image_id':image,'registry_digest_verified':True}}}
for kind in ('scan','sbom'):
 f=p/(kind+'.json');manifest['artifacts']['synthetic'][kind]={'file':f.name,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()}
(p/'release-manifest.json').write_text(json.dumps(manifest))
PY
assert_ok 'synthetic consistent approved evidence accepted' python3 "$ROOT/scripts/check-release.py" "$SB"
echo tamper >> "$SB/sbom.json"
assert_fail 'evidence tampering rejected' python3 "$ROOT/scripts/check-release.py" "$SB"
python3 - "$SB" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])/'release-manifest.json';d=json.loads(p.read_text());d['approved']=False;d['source_commit']=None;p.write_text(json.dumps(d))
PY
assert_fail 'unapproved working tree rejected' python3 "$ROOT/scripts/check-release.py" "$SB"
finish
