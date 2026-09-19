#!/usr/bin/env python3
"""Compare benchmark correctness and readAt I/O, including unchanged known failures."""
import argparse
import json
import sys


def compare(before, after):
    old = {item['path']: item for item in before['files']}
    new = {item['path']: item for item in after['files']}
    differences = []
    for path in sorted(old.keys() | new.keys()):
        if path not in old or path not in new:
            differences.append(f'{path}: input added or removed')
            continue
        a, b = old[path], new[path]
        for key in ('fileBytes', 'metadata', 'errors'):
            if a.get(key) != b.get(key):
                differences.append(f'{path}: {key} changed')
        if len(a['thumbnails']) != len(b['thumbnails']):
            differences.append(f'{path}: thumbnail count changed')
        for x, y in zip(a['thumbnails'], b['thumbnails']):
            # The extraction order, descriptor, bytes and decoded dimensions must match.
            for key in ('index', 'info', 'outputBytes', 'sha256', 'decodedWidth', 'decodedHeight', 'error'):
                if x.get(key) != y.get(key):
                    differences.append(f"{path}: thumbnail {x['index']} {key} changed")
    totals = {}
    for stage in ('metadataPerformance', 'performance'):
        totals[stage] = {}
        for key in ('readCount', 'requestedBytes', 'returnedBytes'):
            a = sum(item[stage][key] for item in old.values())
            b = sum(item[stage][key] for item in new.values())
            totals[stage][key] = {'before': a, 'after': b, 'delta': b - a,
                                 'reductionPercent': round((a - b) / a * 100, 3) if a else None}
    return {
        'beforeFiles': len(old), 'afterFiles': len(new),
        'beforeFailedFiles': sum(bool(item['errors']) for item in old.values()),
        'afterFailedFiles': sum(bool(item['errors']) for item in new.values()),
        'thumbnails': sum(len(item['thumbnails']) for item in new.values()),
        'correctnessDifferences': differences,
        'totals': totals,
        'filesWithMoreReads': [path for path in sorted(old.keys() & new.keys())
                               if new[path]['performance']['readCount'] > old[path]['performance']['readCount']],
        'filesWithMoreBytes': [path for path in sorted(old.keys() & new.keys())
                               if new[path]['performance']['returnedBytes'] > old[path]['performance']['returnedBytes']],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before')
    parser.add_argument('after')
    parser.add_argument('--output', help='Also write machine-readable comparison JSON')
    args = parser.parse_args()
    with open(args.before) as f:
        before = json.load(f)
    with open(args.after) as f:
        after = json.load(f)
    result = compare(before, after)
    rendered = json.dumps(result, indent=2, ensure_ascii=False)
    print(rendered)
    if args.output:
        with open(args.output, 'w') as f:
            f.write(rendered + '\n')
    # Known failures remain visible; equivalence requires no *new* failures or output changes.
    regression = any(v['delta'] > 0 for stage in result['totals'].values() for v in stage.values())
    return 1 if result['correctnessDifferences'] or regression else 0


if __name__ == '__main__':
    sys.exit(main())
