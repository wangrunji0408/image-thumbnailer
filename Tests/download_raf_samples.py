#!/usr/bin/env python3
"""Download CC0 RAF test samples from raw.pixls.us and verify their SHA-256 hashes."""
import hashlib
import json
from pathlib import Path
import sys
from urllib.parse import quote
from urllib.request import urlopen

root = Path(__file__).resolve().parent
output = Path(sys.argv[1]) if len(sys.argv) > 1 else root.parent / 'build/raf-samples'
output.mkdir(parents=True, exist_ok=True)
for sample in json.loads((root / 'raf-samples.json').read_text()):
    target = output / f"{sample['id']}.RAF"
    if not target.exists():
        partial = target.with_suffix('.download')
        with urlopen(quote(sample['url'], safe=':/'), timeout=120) as response, partial.open('wb') as file:
            while chunk := response.read(1024 * 1024):
                file.write(chunk)
        partial.replace(target)
    with target.open('rb') as file:
        checksum = hashlib.file_digest(file, 'sha256').hexdigest()
    if checksum != sample['sha256']:
        raise RuntimeError(f'Checksum mismatch: {target}')
    print(f"{target.name}: {sample['model']} — SHA-256 OK")
print(f'RAF_SAMPLE_DIR="{output.resolve()}" swift test --filter RafReaderTests')
