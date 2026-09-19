# ImageThumbnailer

Swift library and macOS CLI for extracting embedded image thumbnails, video previews and
metadata with minimal I/O. Reads through an asynchronous `readAt(offset, length)` callback;
no full RAW decoding. Requires Swift 5.9+, macOS 11+ or iOS 14+ (library).

## Supported files

HEIC/HEIF/HIF, JPEG, RAF, ARW, DNG, NEF, PEF, RW2, CR2, CR3, ORF and MP4/MOV
(HEVC/H.264). ORF currently provides metadata only. A supported extension does not guarantee
that every vendor variant has an extractable preview.

Metadata includes dimensions, GPS, duration, EXIF capture time and camera/lens/exposure
fields where present. Unknown capture time zones stay unknown; QuickTime `creationTime`
is a separate container timestamp. Vendor MakerNotes are not interpreted.

## Use

Add this repository as a Swift Package dependency and import `ImageThumbnailer`:

```swift
let handle = try FileHandle(forReadingFrom: url)
defer { try? handle.close() }
let reader = try ImageReaderFactory.makeReader(forExtension: url.pathExtension) { offset, length in
    try handle.seek(toOffset: offset)
    return try handle.read(upToCount: Int(length)) ?? Data()
}
let metadata = try await reader.getMetadata()
for (index, info) in try await reader.getThumbnailList().enumerated() {
    let data = try await reader.getThumbnail(at: index)
    // Save data using info.format; honor info.rotation when displaying it.
}
```

Readers cache data from an immutable source; use one reader per file and serialize calls.
Individual readers (`HeifReader`, `RafReader`, etc.) remain available directly.

```bash
swift run ImageThumbnailerCLI photo.raf -o preview.jpg
swift run ImageThumbnailerCLI photo.heic -t 0 -o preview.heic
swift run ImageThumbnailerCLI photo.raf --metadata-json
```

## Directory benchmark

```bash
swift run ImageThumbnailerBenchmark /path/to/media -o build/before
# After changing the library, run the same input again into a new directory:
swift run ImageThumbnailerBenchmark /path/to/media -o build/after
python3 Tests/compare_benchmarks.py build/before/report.json build/after/report.json
```

The tool recursively scans regular files using case-insensitive supported extensions and
extracts **every thumbnail size exposed by the reader**, including full embedded previews.
It does not resize images, demosaic RAW data, or copy the original as a thumbnail fallback.
Symlinks are skipped. Output must be a new/empty directory outside the input tree.

- `files/<relative source filename>/metadata.json`: metadata, thumbnail descriptors, errors,
  per-stage performance and the complete read trace.
- `files/<relative source filename>/00.jpeg` (etc.): extracted thumbnails, decoded with ImageIO
  to verify readability; the JSON records decoded dimensions and SHA-256 hashes.
- `report.json`: all file results and aggregate totals. Bad files are recorded and processing
  continues; any file failure returns exit code 1. Zero thumbnails is valid for metadata-only files.

`readCount` counts `readAt` calls, including failed attempts; `requestedBytes` counts requested
lengths and `returnedBytes` counts actual data returned (including repeated ranges). They measure
library I/O, not physical disk reads or OS cache misses. Timings include parsing, extraction,
output writes and decoding in their respective stages; they are diagnostic, not a cold-disk benchmark.
The comparison checks metadata, thumbnail descriptors, decoded dimensions and exact output hashes,
and fails on changed results or increased aggregate I/O. Unchanged pre-existing failures remain visible.

The latest measured results and per-file tradeoffs are in [BenchmarkResults.md](Tests/BenchmarkResults.md).

## Test

```bash
swift build
swift test
python3 Tests/test_benchmark.py

# Complete local library (35 files); optional CC0 RAF samples:
python3 Tests/download_resources.py
python3 Tests/download_raf_samples.py
REQUIRE_ALL_RESOURCES=1 RAF_SAMPLE_DIR="$PWD/build/raf-samples" swift test
```

Only three HEIF fixtures are tracked. `ResourceManifest.json` records the complete local
library, SHA-256 hashes and ExifTool baselines; missing optional resources are skipped unless
`REQUIRE_ALL_RESOURCES=1` is set. RAF sample sources are in `Tests/raf-samples.json`.

MIT License.
