#!/usr/bin/env bash
# Bounded retention of completed logs and metadata. Never touches volumes/cache.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
NAME=${1-}
require_valid_app_name "$NAME"
[[ $# -le 2 && (${2-} == '' || ${2-} == --dry-run) ]] || die 'Usage: cleanup-app.sh <name> [--dry-run]'
DRY=${2-}
state=$(app_state_dir "$NAME")
require_plain_under "$SANDBOX_STATE_ROOT" "$state/logs" || die 'unsafe state'
# Fixed server-side budget: 20 logs, 20 MiB. Hooks truncate each log at 1 MiB.
# Dry run takes the same lock; lock inode persists (no application data writes).
lock_app "$NAME"
for path in "$state/logs"/*; do
    [[ -e $path || -L $path ]] || continue
    require_plain_under "$state/logs" "$path" || die 'unsafe log entry'
    is_log_sha "$(basename "$path" .log)" || die 'unexpected log entry'
    [[ -f $path ]] || die 'unexpected log type'
done
python3 - "$state" "$DRY" "$(app_site_dir "$NAME")/current" <<'PY'
import os, pathlib, sys, tempfile
state=pathlib.Path(sys.argv[1]); dry=bool(sys.argv[2])
logdir=state/'logs'
history=state/'deploys.tsv'
if history.is_symlink(): raise SystemExit('unsafe history')
lines=history.read_text().splitlines() if history.exists() else []
last=lines[-1].split('\t')[2] if lines else ''
active=pathlib.Path(sys.argv[3]).resolve().name.split('.')[0]
# Only completed logs in deploy history are cleanup candidates. Unknown files stay.
known={row.split('\t')[2] for row in lines if len(row.split('\t')) == 5}
files=sorted(logdir.glob('*.log'),key=lambda p:p.stat().st_mtime_ns,reverse=True)
count=0; size=0
for p in files:
    count+=1; size+=p.stat().st_size
    if count>20 or size>20*1024*1024:
        if p.stem in known and p.stem not in (last,active):
            print(('would remove ' if dry else 'remove ')+str(p))
            if not dry: p.unlink()
# Preserve the last attempt and recent status checks; atomic replacement.
if len(lines)>200 and not dry:
    fd,tmp=tempfile.mkstemp(prefix='.deploys.',dir=state)
    with os.fdopen(fd,'w') as f: f.write('\n'.join(lines[-200:])+'\n')
    os.replace(tmp,history)
PY
