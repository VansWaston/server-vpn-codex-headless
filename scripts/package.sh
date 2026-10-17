#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
python3 - "$ROOT" "${1:-$ROOT/dist/server-vpn-codex-headless.tar.gz}" <<'PY'
import gzip
from pathlib import Path
import sys
import tarfile

root, output = map(Path, sys.argv[1:])
names = (root / 'packaging-files.txt').read_text().splitlines()
for name in names:
    path = root / name
    if not path.is_file() or path.is_symlink() or '..' in Path(name).parts or Path(name).is_absolute():
        raise SystemExit(f'Invalid package entry: {name}')
output.parent.mkdir(parents=True, exist_ok=True)
temporary = output.with_name(output.name + '.next')
try:
    with temporary.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w') as archive:
            for name in sorted(names):
                path = root / name
                info = archive.gettarinfo(str(path), 'server-vpn-codex-headless/' + name)
                info.uid = info.gid = 0
                info.uname = info.gname = ''
                info.mtime = 0
                info.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                with path.open('rb') as handle:
                    archive.addfile(info, handle)
    temporary.replace(output)
finally:
    temporary.unlink(missing_ok=True)
print(output)
PY
