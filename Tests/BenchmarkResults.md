# Directory benchmark — 2026-09-19

Baseline library: `6f8c135648c0fb3a55f658dfb8700d540390f74c`, measured before reader changes using the new benchmark. Existing single-file CLI changes were preserved. Final measurements use the same input files and debug build mode. Environment: Apple Silicon, macOS 27.0, Apple Swift 6.4 (package language version 5.9).

Both comparisons passed: all metadata, thumbnail descriptors, output SHA-256 hashes and decoded dimensions match. **378 files attempted, 375 successful, 3 unchanged failures; 737 thumbnails decoded.**

| Dataset | Files | Thumbnails | Read calls before → after | Returned bytes before → after | Reduction |
|---|---:|---:|---:|---:|---:|
| Resources | 35 | 49 | 208 → 194 | 50,466,350 → 50,224,526 | calls −6.73%; bytes −0.48% |
| pixls-data | 343 | 688 | 2,679 → 2,355 | 799,068,797 → 796,113,267 | calls −12.09%; bytes −0.37% |

Metadata phase only:

| Dataset | Read calls before → after | Returned bytes before → after |
|---|---:|---:|
| Resources | 164 → 146 | 729,112 → 660,257 |
| pixls-data | 2,106 → 1,768 | 10,449,779 → 9,990,651 |

These are readAt callback metrics, not physical disk reads. Requested bytes, actual returned bytes, per-stage timings and every read offset/length are in the JSON reports. Total extraction is dominated by unchanged thumbnail payloads, so the byte reduction is smaller than the call reduction. Timings are not compared because network, OS and codec cache state varies.

## Changes and tradeoffs

- Reuse partially cached ranges instead of reading them again; cache EOF and reject truncated required reads. Large payloads fetch only missing bytes.
- RAF nested JPEG reads share the outer cache while staying within the declared preview.
- Remove small TIFF directory prefetches that caused subsequent reads, centralize format dispatch, consolidate unaligned integer reads, and reject negative thumbnail indices.
- All output bytes remain identical. This is an aggregate improvement, not a per-file Pareto improvement: filling multiple uncached gaps can take more calls, and replacing tiny TIFF prefetches with the shared 4 KiB read-ahead can read slightly more metadata in some DNGs.

Files with increased total read count:

- `resources/Fujifilm_X-T5.RAF`: 7 → 9 calls; returned bytes decrease by 28,524.
- `resources/Panasonic_DC-S5M2.RW2`: 7 → 9 calls; returned bytes decrease by 30,720.
- `pixls/Apple/iPhone XS/IMG_1105.dng`: 3 → 4 calls; returned bytes decrease by 4,764.
- `pixls/FUJIFILM/GFX 100/_DSF3979.RAF`: 5 → 6 calls; returned bytes decrease by 24,428.
- `pixls/FUJIFILM/GFX100RF/DSCF0075.RAF`: 7 → 9 calls; returned bytes decrease by 28,524.
- `pixls/FUJIFILM/GFX100RF/DSCF0091.RAF`: 7 → 9 calls; returned bytes decrease by 28,524.
- `pixls/FUJIFILM/GFX100S II/_DSF0001.RAF`: 7 → 9 calls; returned bytes decrease by 28,524.
- `pixls/FUJIFILM/GFX100S II/_DSF0004.RAF`: 7 → 9 calls; returned bytes decrease by 28,524.
- `pixls/FUJIFILM/GFX100S/Fujifilm-GFX100S-16bits-losslesscompressed-4_3.RAF`: 6 → 8 calls; returned bytes decrease by 28,524.
- `pixls/FUJIFILM/GFX100S/Fujifilm-GFX100S-16bits-uncompress-4_3.RAF`: 6 → 8 calls; returned bytes decrease by 28,524.

Files with increased returned bytes (pixls-data; all other files use no more bytes):

- `Adobe DNG Converter/Canon EOS 5D Mark III/5G4A9394-compressed-lossless.DNG`: +1,786 bytes; calls 5 → 4.
- `Adobe DNG Converter/Canon EOS 5D Mark III/5G4A9395-compressed-lossless.DNG`: +2,352 bytes; calls 5 → 4.
- `Autel Robotics/XB015/MAX_0001.DNG`: +2,808 bytes; calls 4 → 4.
- `Blackmagic Design/Pocket Cinema Camera 6k Pro/A010_04101355_S068.dng`: +646 bytes; calls 3 → 3.
- `Blackmagic/Blackmagic Pocket Cinema Camera 4k/4k_DCI_uncompressed.dng`: +662 bytes; calls 3 → 3.
- `Blackmagic/Blackmagic Pocket Cinema Camera 4k/BMPCC_4k_DCI_uncompressed.dng`: +662 bytes; calls 3 → 3.

## Known failures

The same three pixls-data files fail before and after. They have `.CR2` names but no TIFF/CR2 header; ExifTool also does not identify them as CR2 (one is classified as TXT, two return a file format error). They remain in the benchmark results with errors and cause benchmark exit code 1. No new failure was introduced.

- `Canon/PowerShot A480/CRW_0007.CR2`: metadata/thumbnail list `invalidData`.
- `Canon/PowerShot SX40 HS/CRW_6036.CR2`: metadata/thumbnail list `invalidData`.
- `Canon/SX150IS/CRW_1762.CR2`: metadata/thumbnail list `invalidData`.

## Reproduce and inspect

```bash
swift build
REQUIRE_ALL_RESOURCES=1 RAF_SAMPLE_DIR="$PWD/build/raf-samples" swift test
python3 Tests/test_benchmark.py
swift run ImageThumbnailerBenchmark Tests/ImageThumbnailerTests/Resources -o build/new-resources
swift run ImageThumbnailerBenchmark /Volumes/home/Resource/pixls-data -o build/new-pixls
python3 Tests/compare_benchmarks.py build/benchmark-before-resources/report.json build/new-resources/report.json
python3 Tests/compare_benchmarks.py build/benchmark-before-pixls/report.json build/new-pixls/report.json
```

Final checks: 21 Swift tests passed, including the full 35-file metadata library and eight additional RAF samples; 2 Python CLI integration tests passed. The existing CLI metadata matches the benchmark, and its original-file fallback remains byte-identical. Build and test logs contain no warnings or errors.

Local artifacts (ignored by Git):

- [Resources comparison](../build/comparison-resources.json)
- [pixls-data comparison](../build/comparison-pixls.json)
- [Resources final report](../build/benchmark-after-resources/report.json)
- [pixls-data final report](../build/benchmark-after-pixls/report.json)

Each final report directory contains `files/<relative source filename>/metadata.json` and all extracted thumbnails. Baselines are retained under the matching `benchmark-before-*` directories.
