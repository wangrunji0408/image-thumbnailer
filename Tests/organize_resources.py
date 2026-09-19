#!/usr/bin/env python3
"""Flatten local media by recorded device model; retain hashes and EXIF baselines for tests.
Requires ExifTool. Refuses to replace an existing manifest; it is also the rename audit trail.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent / 'ImageThumbnailerTests'
resources = root / 'Resources'
manifest = root / 'ResourceManifest.json'
if manifest.exists():
    raise SystemExit('ResourceManifest.json already exists; review it before reorganizing again.')
fields = ['FileType', 'Make', 'Model', 'DeviceModelName', 'Encoder', 'CompressorName',
          'DateTimeOriginal', 'CreateDate', 'CreationDate', 'SubSecTimeOriginal', 'OffsetTimeOriginal',
          'LensMake', 'LensModel', 'ExposureTime', 'FNumber', 'ISO', 'ExposureCompensation',
          'FocalLength', 'FocalLengthIn35mmFormat', 'Orientation', 'Software', 'Artist', 'Copyright',
          'ExposureProgram', 'MeteringMode', 'Flash', 'WhiteBalance', 'GPSLatitude', 'GPSLongitude',
          'GPSAltitude', 'Duration']
rows = json.loads(subprocess.check_output(['exiftool', '-r', '-json', '-n',
    *('-' + name for name in fields), str(resources)]))
brands = {'SONY': 'Sony', 'Apple': 'Apple', 'Canon': 'Canon', 'FUJIFILM': 'Fujifilm',
          'NIKON CORPORATION': 'Nikon', 'NIKON DIGITAL CAMERA': 'Nikon',
          'OLYMPUS IMAGING CORP.': 'Olympus', 'RICOH IMAGING COMPANY, LTD.': 'Pentax',
          'LEICA CAMERA AG': 'Leica', 'Panasonic': 'Panasonic', 'samsung': 'Samsung', 'DJI': 'DJI'}
used = set()
plan = []
for row in sorted(rows, key=lambda r: r['SourceFile']):
    source = Path(row.pop('SourceFile'))
    model = (row.get('Model') or row.get('DeviceModelName') or '').strip()
    brand = brands.get(row.get('Make'), row.get('Make', '')).strip()
    device_source = 'metadata'
    if not model:
        encoder = row.get('Encoder', '')
        if 'OsmoPocket3' in encoder:
            model, brand = 'Osmo Pocket 3', 'DJI'
        elif 'GoPro' in row.get('CompressorName', ''):
            model, brand, device_source = 'Unknown', 'GoPro', 'encoder; exact model absent'
        else:
            model, device_source = 'Unknown_Device', 'device metadata absent'
    if not brand and model.startswith('ILCE-'):
        brand = 'Sony'
    if not brand and model.startswith('HERO'):
        brand = 'GoPro'
    device = model if model.lower().startswith(brand.lower()) else brand + ' ' + model
    stem = re.sub(r'[^\w-]+', '_', device, flags=re.UNICODE).strip('_')
    name = stem + source.suffix.upper()
    n = 2
    while name.casefold() in used:
        name = f'{stem}_{n}{source.suffix.upper()}'
        n += 1
    used.add(name.casefold())
    with source.open('rb') as file:
        digest = hashlib.file_digest(file, 'sha256').hexdigest()
    plan.append(dict(original=source.relative_to(resources).as_posix(), file=name,
                     device=device, deviceSource=device_source, sha256=digest, expected=row))
standard_tags = [
    'IFD0:Make', 'IFD0:Model', 'IFD0:Orientation', 'IFD0:Software', 'IFD0:Artist', 'IFD0:Copyright',
    'ExifIFD:DateTimeOriginal', 'ExifIFD:CreateDate', 'ExifIFD:OffsetTimeOriginal', 'ExifIFD:SubSecTimeOriginal',
    'ExifIFD:LensMake', 'ExifIFD:LensModel', 'ExifIFD:ExposureTime', 'ExifIFD:FNumber', 'ExifIFD:ISO',
    'ExifIFD:ExposureCompensation', 'ExifIFD:FocalLength', 'ExifIFD:FocalLengthIn35mmFormat',
    'ExifIFD:ExposureProgram', 'ExifIFD:MeteringMode', 'ExifIFD:Flash', 'ExifIFD:WhiteBalance',
    'GPS:GPSLatitude', 'GPS:GPSLongitude', 'GPS:GPSLatitudeRef', 'GPS:GPSLongitudeRef', 'GPS:GPSAltitude',
    'QuickTime:CreateDate', 'Keys:CreationDate', 'Keys:Make', 'Keys:Model',
    'VideoKeys:LensModel', 'VideoKeys:FocalLengthIn35mmFormat',
]
baselines = json.loads(subprocess.check_output(['exiftool', '-json', '-n', '-G1',
    *('-' + tag for tag in standard_tags), *(str(resources / row['original']) for row in plan)]))
for row, baseline in zip(plan, baselines):
    baseline.pop('SourceFile')
    row['standard'] = baseline
# Save the recovery mapping before any move. All targets must be new or one of the source paths.
sources = {str(resources / row['original']).casefold() for row in plan}
assert all(not (resources / row['file']).exists() or str(resources / row['file']).casefold() in sources for row in plan)
manifest.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + '\n')
staged = []
try:
    for i, row in enumerate(plan):
        temporary = resources / f'.organize-{i}.tmp'
        assert not temporary.exists()
        (resources / row['original']).rename(temporary)
        staged.append((temporary, row))
    for temporary, row in staged:
        target = resources / row['file']
        assert not target.exists()
        temporary.rename(target)
        with target.open('rb') as file:
            assert hashlib.file_digest(file, 'sha256').hexdigest() == row['sha256']
        print(f"{row['original']} -> {row['file']}")
except BaseException:
    print('Rename interrupted. Use ResourceManifest.json and .organize-*.tmp to recover.')
    raise
for directory in sorted(resources.rglob('*'), reverse=True):
    if directory.is_dir() and not any(directory.iterdir()):
        directory.rmdir()
print(f'Verified {len(plan)} unchanged media files.')
