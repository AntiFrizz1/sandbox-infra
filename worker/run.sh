#!/bin/sh
# Runs only inside the disposable worker. No host execution fallback.
#   fetch — may have network, but no repository or dependency code runs:
#           npm only downloads and unpacks (--ignore-scripts);
#   build — never has network; lifecycle scripts and build_cmd run here.
set -eu
export HOME=/tmp/home npm_config_update_notifier=false \
    npm_config_fund=false npm_config_audit=false
mkdir -p "$HOME"
case ${1-} in
fetch)
    cp -R /source/. /work/
    cd /work
    # The cache lives in the output tree, not on the small /tmp tmpfs.
    export npm_config_cache=/work/.sandbox-npm-cache
    if [ -f package-lock.json ]; then
        npm ci --ignore-scripts
    elif [ -f package.json ]; then
        npm install --ignore-scripts
    fi
    rm -rf /work/.sandbox-npm-cache
    ;;
build)
    cd /work
    export npm_config_cache=/tmp/npm npm_config_offline=true
    # Official Node images ship headers here; node-gyp must not download them.
    export npm_config_nodedir=/usr/local
    if [ -f package.json ]; then
        npm rebuild
        for script in preinstall install postinstall prepare; do
            npm run --if-present "$script"
        done
    fi
    # Only separately provisioned build secrets, never project runtime env.
    if [ -f /build-env ]; then cp /build-env /work/.env; chmod 600 /work/.env; fi
    /bin/sh -c "$2"
    ;;
*)
    echo "usage: sandbox-worker fetch | build <command>" >&2
    exit 64
    ;;
esac
