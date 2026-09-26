#!/usr/bin/env bash
# Scans a candidate image and records the evidence in the release manifest.
#
#   scan-image.sh <image> <caddy|worker> [evidence-dir]
#
# Runs Trivy (vulnerabilities) and Syft (CycloneDX SBOM) from digest-pinned
# official images, writes <artifact>.scan.json and <artifact>.sbom.cdx.json
# (gzip-compressed when large) into the evidence directory, and updates the
# artifact's image ID, checksums and finding counts plus the vulnerability DB
# metadata in release-manifest.json. It resets approval and the archive
# record: a new scan needs a new review and a new export-image.sh.
# Exceptions are not generated: the gate lists findings that need one.
set -euo pipefail
TRIVY=aquasec/trivy@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969
SYFT=anchore/syft@sha256:500e2d872ac019436926e8322b4fc1f39441d94d21f6f4046c6ff29b30e8cb02
(( $# >= 2 )) || { echo 'Usage: scan-image.sh <image> <caddy|worker> [evidence-dir]' >&2; exit 2; }
IMAGE=$1
NAME=$2
DIR=$(readlink -f "${3:-docs/security-remediation}")
[[ $NAME =~ ^[a-z][a-z0-9-]*$ ]] || { echo "bad artifact name: $NAME" >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SOCK=(-v /var/run/docker.sock:/var/run/docker.sock)

docker volume create sandbox-trivy-cache >/dev/null
docker run --rm "${SOCK[@]}" -v sandbox-trivy-cache:/root/.cache -v "$WORK:/out" "$TRIVY" \
    image --quiet --format json --output /out/scan.json --scanners vuln "$IMAGE"
docker run --rm -v sandbox-trivy-cache:/root/.cache "$TRIVY" version --format json > "$WORK/trivy.json"
docker run --rm "${SOCK[@]}" -v "$WORK:/out" "$SYFT" "docker:$IMAGE" -q -o cyclonedx-json=/out/sbom.json
docker run --rm "$SYFT" version -o json > "$WORK/syft.json"

python3 - "$WORK" "$DIR" "$NAME" "$(docker image inspect -f '{{.Id}}' "$IMAGE")" "$TRIVY" "$SYFT" <<'PY'
import collections, datetime, gzip, hashlib, json, pathlib, sys
work, out, name, image_id, trivy_image, syft_image = sys.argv[1:]
work, out = pathlib.Path(work), pathlib.Path(out)
scan = json.loads((work / 'scan.json').read_text())
assert scan['Metadata']['ImageID'] == image_id, 'scan is not of this image'

def store(src, base):
    data = src.read_bytes()
    if len(data) > 5 * 1024 * 1024:   # keep the repository small, losslessly
        target = out / (base + '.gz')
        target.write_bytes(gzip.compress(data, mtime=0))
    else:
        target = out / base
        target.write_bytes(data)
    # A previous scan may have stored the other form; a stale copy next to the
    # current one would look like evidence for this image.
    other = out / (base if target.name.endswith('.gz') else base + '.gz')
    other.unlink(missing_ok=True)
    return {'file': target.name, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}

manifest_path = out / 'release-manifest.json'
m = json.loads(manifest_path.read_text())
counts = collections.Counter(v['Severity'] for r in scan['Results'] for v in r.get('Vulnerabilities') or [])
a = m['artifacts'].setdefault(name, {})
a.update({
    'image_id': image_id,
    'registry_digest_verified': False,
    'scan': store(work / 'scan.json', f'{name}.scan.json'),
    'sbom': store(work / 'sbom.json', f'{name}.sbom.cdx.json'),
    'findings_by_severity': dict(counts),
    'unique_vulnerability_ids': len({v['VulnerabilityID'] for r in scan['Results'] for v in r.get('Vulnerabilities') or []}),
})
a.pop('distribution', None)
trivy = json.loads((work / 'trivy.json').read_text())
syft = json.loads((work / 'syft.json').read_text())
m['vulnerability_db'] = trivy['VulnerabilityDB']
m['tools'] = {'trivy': {'version': trivy['Version'], 'image': trivy_image},
              'syft': {'version': syft.get('version'), 'image': syft_image}}
m['approved'] = False
m['source_commit'] = None
m['created_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
manifest_path.write_text(json.dumps(m, indent=1) + '\n')
high = counts['HIGH'] + counts['CRITICAL']
print(f'{name}: {image_id}  {dict(counts)}')
print(f'HIGH/CRITICAL: {high}; run scripts/check-release.py to see which need a fix or an exception')
PY
