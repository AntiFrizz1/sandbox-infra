#!/bin/sh
# Runs only inside the disposable worker. No host execution fallback.
set -eu
export HOME=/tmp/home npm_config_cache=/tmp/npm
mkdir -p "$HOME"
cp -R /source/. /work/
cd /work
if [ -f package-lock.json ]; then npm ci --offline; else npm install --offline; fi
# Only separately provisioned build secrets, never project runtime env.
if [ -f /build-env ]; then cp /build-env /work/.env; chmod 600 /work/.env; fi
/bin/sh -c "$1"
