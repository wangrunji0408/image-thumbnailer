#!/usr/bin/env python3
"""Restore known public samples under their device names; verify every existing sample."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from urllib.request import urlopen

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--verify-present', action='store_true', help='Verify installed files without downloading')
parser.add_argument('--public-only', action='store_true', help='Allow unavailable local-only samples')
args = parser.parse_args()

root = Path(__file__).resolve().parent / 'ImageThumbnailerTests'
output = root / 'Resources'
output.mkdir(exist_ok=True)
missing = []
for row in json.loads((root / 'ResourceManifest.json').read_text()):
    target = output / row['file']
    if not target.exists():
        if args.verify_present:
            continue
        if 'downloadURL' not in row:
            missing.append(row['file'])
            continue
        temporary = target.with_suffix(target.suffix + '.download')
        with urlopen(row['downloadURL'], timeout=120) as response, temporary.open('wb') as file:
            while chunk := response.read(1024 * 1024):
                file.write(chunk)
        with temporary.open('rb') as file:
            if hashlib.file_digest(file, 'sha256').hexdigest() != row['sha256']:
                raise RuntimeError(f'Checksum mismatch: {temporary}; original preserved')
        temporary.replace(target)
    with target.open('rb') as file:
        if hashlib.file_digest(file, 'sha256').hexdigest() != row['sha256']:
            raise RuntimeError(f'Checksum mismatch: {target}; refusing to overwrite')
    print(f"OK {target.name}")
if missing and not args.public_only:
    print('Local samples unavailable from public URLs: ' + ', '.join(missing), file=sys.stderr)
    raise SystemExit(1)
