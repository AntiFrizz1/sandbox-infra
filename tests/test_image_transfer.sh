#!/usr/bin/env bash
# Image delivery without a registry: export-image.sh on the build machine,
# load-image.sh on the VPS. Uses a tiny throwaway image built from scratch.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
SB=$(make_sandbox)
IMAGE="sbimgtest-$$:candidate"
trap 'docker rmi -f "$IMAGE" >/dev/null 2>&1; rm -rf "$SB"' EXIT
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"

echo "== закреплённая ссылка на образ =="
assert_ok 'registry digest accepted' is_pinned_image "ghcr.io/me/caddy@sha256:$(printf 'a%.0s' {1..64})"
assert_ok 'local image ID accepted' is_pinned_image "sha256:$(printf 'b%.0s' {1..64})"
assert_fail 'tag refused' is_pinned_image 'caddy:latest'
assert_fail 'malformed digest refused' is_pinned_image "caddy:2@sha256:$(printf 'a%.0s' {1..64})x"
assert_fail 'short ID refused' is_pinned_image 'sha256:abc'

if ! docker info >/dev/null 2>&1; then
    echo "  SKIP перенос образа: docker недоступен"
    finish
    exit $?
fi

echo "== экспорт на машине сборки =="
mkdir "$SB/ctx"
echo "payload $$" > "$SB/ctx/hello"
printf 'FROM scratch\nCOPY hello /hello\n' > "$SB/ctx/Dockerfile"
docker build -q -t "$IMAGE" "$SB/ctx" >/dev/null 2>&1
ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")
printf '{"artifacts":{"caddy":{"image_id":"sha256:%064d"}}}\n' 0 > "$SB/manifest.json"
assert_fail 'export refuses an image the scan does not cover' \
    bash "$ROOT/scripts/export-image.sh" "$IMAGE" "$SB/img.tar" --artifact caddy --manifest "$SB/manifest.json"
printf '{"artifacts":{"caddy":{"image_id":"%s"}}}\n' "$ID" > "$SB/manifest.json"
out=$(bash "$ROOT/scripts/export-image.sh" "$IMAGE" "$SB/img.tar" --artifact caddy --manifest "$SB/manifest.json")
SUM=$(sed -n 's/^sha256: *//p' <<< "$out")
assert_eq 'printed checksum matches the archive' "$(sha256sum "$SB/img.tar" | cut -d' ' -f1)" "$SUM"
assert_eq 'distribution recorded in the manifest' "archive $SUM $ID" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["artifacts"]["caddy"]["distribution"]; print(d["type"], d["sha256"], d["image_id"])' "$SB/manifest.json")"

echo "== загрузка на VPS =="
docker rmi -f "$IMAGE" >/dev/null
assert_fail 'image gone before loading' docker image inspect "$ID"
assert_fail 'wrong checksum refused' bash "$ROOT/deploy/load-image.sh" "$SB/img.tar" "$(printf 'f%.0s' {1..64})"
assert_fail 'nothing loaded after a refusal' docker image inspect "$ID"
cp "$SB/img.tar" "$SB/tampered.tar"
printf 'x' >> "$SB/tampered.tar"
assert_fail 'tampered archive refused' bash "$ROOT/deploy/load-image.sh" "$SB/tampered.tar" "$SUM"
mkdir "$SB/caddy"
printf 'TIMEWEB_API_TOKEN=x\nSANDBOX_CADDY_IMAGE=old\n' > "$SB/caddy/.env"
chmod 640 "$SB/caddy/.env"
loaded=$(SANDBOX_CADDY_DIR="$SB/caddy" bash "$ROOT/deploy/load-image.sh" "$SB/img.tar" "$SUM" --caddy 2>/dev/null)
assert_eq 'verified archive loads the same image' "$ID" "$loaded"
assert_ok 'image present after loading' docker image inspect "$ID"
assert_eq 'Caddy .env points at the loaded ID' "SANDBOX_CADDY_IMAGE=$ID" "$(grep '^SANDBOX_CADDY_IMAGE=' "$SB/caddy/.env")"
assert_eq 'other .env keys kept' 'TIMEWEB_API_TOKEN=x' "$(grep '^TIMEWEB' "$SB/caddy/.env")"
assert_ok 'loaded ID is a valid worker image' is_pinned_image "$loaded"

echo "== ID worker в политику по умолчанию =="
mkdir "$SB/defaults"
assert_fail 'no default policy: refused before loading' \
    env SANDBOX_POLICY_DEFAULTS="$SB/defaults" bash "$ROOT/deploy/load-image.sh" "$SB/img.tar" "$SUM" --worker
printf 'profile=worker\nimage=\nmemory_mb=512\n' > "$SB/defaults/worker.conf"
loaded=$(SANDBOX_POLICY_DEFAULTS="$SB/defaults" bash "$ROOT/deploy/load-image.sh" "$SB/img.tar" "$SUM" --worker 2>/dev/null)
assert_eq 'default worker policy gets the loaded ID' "image=$ID" "$(grep '^image=' "$SB/defaults/worker.conf")"
assert_eq 'other policy keys kept' 'memory_mb=512' "$(grep '^memory_mb=' "$SB/defaults/worker.conf")"
assert_fail 'unknown option refused' bash "$ROOT/deploy/load-image.sh" "$SB/img.tar" "$SUM" --nope
finish
