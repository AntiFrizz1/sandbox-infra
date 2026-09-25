#!/usr/bin/env python3
"""Drain all input but retain/send at most the configured byte budget."""
import os
import sys

path, limit = sys.argv[1], int(sys.argv[2])
marker = b'\n[output truncated]\n'
if limit < len(marker):
    raise SystemExit('log limit too small')
remaining = limit - len(marker)
truncated = False
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, 'wb', buffering=0) as log:
    while chunk := sys.stdin.buffer.read1(65536):
        kept = chunk[:remaining]
        remaining -= len(kept)
        if len(kept) < len(chunk) and not truncated:
            kept += marker
            truncated = True
        log.write(kept)
        try:
            sys.stdout.buffer.write(kept)
            sys.stdout.buffer.flush()
        except BrokenPipeError:
            # Client disconnect must not stop draining the worker pipe.
            sys.stdout = open(os.devnull, 'w')
