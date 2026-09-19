# ImageThumbnailer

Swift package for extracting embedded thumbnails and metadata with minimal remote/local I/O.
Library: macOS 11+, iOS 14+, Swift 5.9+. CLI and benchmark use macOS ImageIO/AppKit.

## Build and validation

```bash
swift build
swift test
python3 Tests/test_benchmark.py  # build first; tests directory traversal, reports and comparison
REQUIRE_ALL_RESOURCES=1 RAF_SAMPLE_DIR="$PWD/build/raf-samples" swift test
```

Do not clean builds unnecessarily. Local untracked media and `build/` outputs can be large;
do not delete them or commit them. Preserve unrelated working-tree changes.

## Architecture

- `Sources/ImageThumbnailer/Lib.swift`: `ImageReader`, `ThumbnailInfo`, `Metadata` public types.
- `ImageReaderFactory.swift`: single extension-to-reader registry shared by both executables.
- `Reader.swift`: sorted, disjoint cached ranges; partial hits fetch only missing ranges.
  Small parser reads prefetch up to 4 KiB without crossing cached ranges. Large payload reads
  are exact. Prefetch tolerates EOF, required reads reject truncation and offset overflow.
  Integer loads support unaligned buffers and explicit byte order.
- `Tiff.swift`: ARW/DNG/NEF/PEF/ORF/RW2/CR2. `.useIfd0` vs `.useSubIfd` selects main dimensions.
  Standard JPEG previews are distinguished from lossless JPEG sensor data.
- `Jpeg.swift`, `Heif.swift`, `Cr3.swift`, `Mp4.swift`: format-specific metadata/preview readers.
- `Raf.swift`: bounded embedded JPEG view shares its parent's cache. Disable parent read-ahead
  for nested reads so requests cannot cross the declared preview boundary.
- `ExifParser.swift`, `CaptureMetadata.swift`, `GPSParser.swift`: bounded EXIF and typed metadata.
- `HeifWriter.swift`: wrap HEVC/H.264-derived previews in displayable HEIC containers.
- `Sources/ImageThumbnailerCLI/main.swift`: single-file extraction/metadata, orientation handling.
  Preserve its original-file fallback when no thumbnail satisfies a request.
- `Sources/ImageThumbnailerBenchmark/Benchmark.swift`: recursive extraction, decode validation,
  JSON results, SHA-256 and readAt measurement. Fresh reader/handle per file; serial processing.
- `Tests/ImageThumbnailerTests/`: format/metadata tests, Reader I/O regression tests and resources.
- `Tests/compare_benchmarks.py`: correctness + aggregate I/O comparison; known failures stay visible.

Readers are stateful, cache an immutable source and require serialized calls. `readAt` returns
requested data or a shorter result at EOF. Do not introduce concurrent seeks on a shared FileHandle.
Do not read whole RAW/video files to simplify metadata parsing. New formats belong in the factory;
all thumbnails exposed by a reader must be extractable and invalid indices must throw.

## Benchmark workflow for I/O changes

Capture a baseline **before** changing readers, then rebuild and use fresh output directories:

```bash
swift run ImageThumbnailerBenchmark Tests/ImageThumbnailerTests/Resources -o build/before-resources
swift run ImageThumbnailerBenchmark /Volumes/home/Resource/pixls-data -o build/before-pixls
# Apply changes, rebuild, then repeat both runs with after-* output directories.
python3 Tests/compare_benchmarks.py build/before-resources/report.json build/after-resources/report.json
python3 Tests/compare_benchmarks.py build/before-pixls/report.json build/after-pixls/report.json
```

Output must be empty and outside the source directory. Every supported regular file is attempted,
including all exposed thumbnail sizes; no original-file fallback is used. Symbolic links are skipped.
Per-file JSON includes metadata, thumbnail hashes/decoded dimensions, per-stage metrics, read traces
and errors; the root report adds totals. Failures return exit code 1 after saving the report.

Compare both read count and actual returned bytes, separately for metadata and total extraction.
Requested bytes include EOF over-read; these are readAt metrics, not disk/cache-miss measurements.
Elapsed time includes decoding and output writes and is sensitive to filesystem/codec caches.
Require unchanged metadata, descriptors, thumbnail hashes and decoded dimensions; investigate new
failures and report per-file I/O tradeoffs, not just aggregate improvements. Run Swift tests and the
Python CLI integration tests after the final code changes.

The local pixls-data snapshot includes three files named `.CR2` without TIFF/CR2 headers:
`Canon/PowerShot A480/CRW_0007.CR2`, `Canon/PowerShot SX40 HS/CRW_6036.CR2`, and
`Canon/SX150IS/CRW_1762.CR2`. Keep their errors in reports; do not skip or count them as passing.

## Fixtures

`Tests/ImageThumbnailerTests/Resources/` contains 35 local files, only three tracked in Git.
`ResourceManifest.json` contains hashes and group-qualified ExifTool expectations.
`Tests/download_resources.py` verifies/downloads known sources; `REQUIRE_ALL_RESOURCES=1`
requires the full local library. `Tests/download_raf_samples.py` downloads eight CC0 RAF files
into ignored `build/raf-samples`; set `RAF_SAMPLE_DIR` to include them in Swift tests.
