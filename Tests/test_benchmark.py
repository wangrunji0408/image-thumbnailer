#!/usr/bin/env python3
"""CLI integration tests; run after swift build (uses a bundled HEIC fixture)."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from compare_benchmarks import compare

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / '.build/debug/ImageThumbnailerBenchmark'
FIXTURE = ROOT / 'Tests/ImageThumbnailerTests/Resources/Apple_iPhone_16_Pro.HEIC'


class BenchmarkTests(unittest.TestCase):
    def run_tool(self, source, output):
        return subprocess.run([str(BINARY), str(source), '-o', str(output)],
                              capture_output=True, text=True, timeout=60)

    def test_recursive_extraction_failure_reporting_and_comparison(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'input'
            (source / 'nested').mkdir(parents=True)
            shutil.copyfile(FIXTURE, source / 'same.HEIC')
            shutil.copyfile(FIXTURE, source / 'nested/same.heic')
            (source / 'ignored.txt').write_text('ignored')
            (source / 'broken.jpg').write_bytes(b'broken')
            output = root / 'before'
            run = self.run_tool(source, output)
            self.assertEqual(run.returncode, 1, run.stderr)
            report = json.loads((output / 'report.json').read_text())
            self.assertEqual(report['skippedFiles'], 1)
            self.assertEqual(len(report['files']), 3)
            self.assertEqual(sum(bool(f['errors']) for f in report['files']), 1)
            for item in report['files']:
                self.assertEqual(item['performance']['readCount'], len(item['reads']))
                self.assertEqual(item['performance']['requestedBytes'], sum(r['requestedBytes'] for r in item['reads']))
                self.assertEqual(item['performance']['returnedBytes'], sum(r['returnedBytes'] for r in item['reads']))
                stages = [item['metadataPerformance'], item['thumbnailListPerformance']] + [t['performance'] for t in item['thumbnails']]
                for key in ('readCount', 'requestedBytes', 'returnedBytes'):
                    self.assertEqual(item['performance'][key], sum(s[key] for s in stages))
                folder = output / 'files' / item['path']
                self.assertEqual(json.loads((folder / 'metadata.json').read_text()), item)
                for thumbnail in item['thumbnails']:
                    self.assertGreater(thumbnail['decodedWidth'], 0)
                    self.assertEqual((folder / thumbnail['output']).stat().st_size, thumbnail['outputBytes'])
            self.assertNotEqual(self.run_tool(source, output).returncode, 0)
            self.assertNotEqual(self.run_tool(source, source / 'output').returncode, 0)
            self.assertFalse((source / 'output').exists())
            second = root / 'after'
            self.assertEqual(self.run_tool(source, second).returncode, 1)
            after = json.loads((second / 'report.json').read_text())
            result = compare(report, after)
            self.assertEqual(result['correctnessDifferences'], [])
            self.assertEqual(result['beforeFailedFiles'], 1)
            for stage in result['totals'].values():
                self.assertTrue(all(value['delta'] == 0 for value in stage.values()))
            after['files'][-1]['thumbnails'][0]['sha256'] = 'changed'
            self.assertTrue(compare(report, after)['correctnessDifferences'])

    def test_missing_or_empty_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertNotEqual(self.run_tool(root / 'missing', root / 'out').returncode, 0)
            source = root / 'empty'
            source.mkdir()
            self.assertNotEqual(self.run_tool(source, root / 'out').returncode, 0)


if __name__ == '__main__':
    unittest.main()
