#!/usr/bin/env bash
# Saves a reviewed image to an archive for deploy/load-image.sh on the VPS.
#
#   export-image.sh <image> <out.tar> [--artifact caddy|worker] [--manifest path]
#
# Prints the archive's SHA-256: that is what load-image.sh verifies. With
# --artifact the image must be the one the manifest's scan and SBOM cover
# (same image ID), and the archive is recorded as that artifact's
# distribution, so the release gate knows how it reaches the server.
set -euo pipefail
usage() { echo 'Usage: export-image.sh <image> <out.tar> [--artifact NAME] [--manifest path]' >&2; exit 2; }
(( $# >= 2 )) || usage
IMAGE=$1
OUT=$2
shift 2
ARTIFACT=""
MANIFEST=docs/security-remediation/release-manifest.json
while (( $# )); do
    case $1 in
        --artifact) ARTIFACT=${2-}; shift 2 || usage ;;
        --manifest) MANIFEST=${2-}; shift 2 || usage ;;
        *) usage ;;
    esac
done

id=$(docker image inspect --format '{{.Id}}' "$IMAGE")
if [[ -n $ARTIFACT ]]; then
    scanned=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifacts"][sys.argv[2]]["image_id"])' \
        "$MANIFEST" "$ARTIFACT")
    if [[ $id != "$scanned" ]]; then
        echo "!! $IMAGE is $id, but the scanned $ARTIFACT is $scanned — rescan first" >&2
        exit 1
    fi
fi
docker save "$IMAGE" -o "$OUT"
sum=$(sha256sum -- "$OUT" | cut -d' ' -f1)
if [[ -n $ARTIFACT ]]; then
    python3 - "$MANIFEST" "$ARTIFACT" "$sum" "$id" "$(basename "$OUT")" <<'PY'
import json, sys
path, name, digest, image_id, file_name = sys.argv[1:]
with open(path) as f:
    manifest = json.load(f)
manifest['artifacts'][name]['distribution'] = {
    'type': 'archive', 'file': file_name, 'sha256': digest, 'image_id': image_id}
with open(path, 'w') as f:
    json.dump(manifest, f, indent=1)
    f.write('\n')
PY
fi
echo "archive:  $OUT"
echo "image id: $id"
echo "sha256:   $sum"
echo "on the VPS: sudo /srv/deploy/load-image.sh $(basename "$OUT") $sum"
