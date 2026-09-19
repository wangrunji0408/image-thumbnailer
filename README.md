# ImageThumbnailer

A fast and efficient Swift library for extracting embedded thumbnails from various image and video formats. Designed for minimal I/O - reads only the metadata and thumbnail data, not the full file.

## Supported Formats

| Format | Extension | Metadata | Thumbnails | Notes |
|--------|-----------|----------|------------|-------|
| HEIF/HEIC | .heic, .heif, .hif | Yes | Yes | iPhone, Canon HIF, etc. |
| JPEG | .jpg, .jpeg | Yes | Yes | EXIF + MPF multi-frame |
| Fujifilm RAF | .raf | Yes | Yes | Embedded JPEG preview + EXIF thumbnail; compressed and uncompressed |
| Sony ARW | .arw | Yes | Yes | Multiple thumbnails |
| Adobe DNG | .dng | Yes | Yes | Including Apple ProRAW |
| Nikon NEF | .nef | Yes | Yes | Lossless & efficient compression |
| Pentax PEF | .pef | Yes | Yes | Standard TIFF-based |
| Panasonic RW2 | .rw2 | Yes | Yes | Via JpgFromRaw tag |
| Canon CR2 | .cr2 | Yes | Yes | Standard TIFF-based |
| Canon CR3 | .cr3 | Yes | Yes | ISOBMFF container, JPEG from tracks |
| Olympus ORF | .orf | Yes | No | Metadata only; thumbnails in MakerNotes |
| MP4/MOV | .mp4, .mov | Yes | Yes | HEVC, H.264; first frame extraction |

### Not Yet Supported

| Format | Extension | Notes |
|--------|-----------|-------|
| Sigma X3F | .x3f | Proprietary format |

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/wangrunji0408/image-thumbnailer", from: "1.0.0")
]
```

## Usage

### Library Usage

```swift
import ImageThumbnailer

// Create a read function for your image file
let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
    let fileHandle = try FileHandle(forReadingFrom: url)
    defer { fileHandle.closeFile() }
    try fileHandle.seek(toOffset: offset)
    return fileHandle.readData(ofLength: Int(length))
}

// Use the appropriate reader for your format
let reader = HeifReader(readAt: readAt)  // or JpegReader, ArwReader, NefReader, etc.

let metadata = try await reader.getMetadata()
print("Image: \(metadata.width)x\(metadata.height)")

let thumbnails = try await reader.getThumbnailList()
for (i, info) in thumbnails.enumerated() {
    print("[\(i)] \(info.format) \(info.width ?? 0)x\(info.height ?? 0) (\(info.size) bytes)")
}

let thumbnailData = try await reader.getThumbnail(at: 0)
```

### Command Line Usage

```bash
# Extract thumbnail from various image formats
swift run ImageThumbnailerCLI input.heic
swift run ImageThumbnailerCLI input.nef
swift run ImageThumbnailerCLI input.arw
swift run ImageThumbnailerCLI input.raf

# Extract with minimum 300px short side
swift run ImageThumbnailerCLI input.heic -s 300

# Specify output path
swift run ImageThumbnailerCLI input.dng -o thumbnail.jpg
```

## Metadata

Every reader returns optional `captureTime` and `camera` fields in addition to dimensions,
GPS and duration. `CameraMetadata` includes make/model, lens make/model, software,
orientation, exposure time (seconds), f-number, ISO, exposure compensation (EV), focal
length (mm), 35mm equivalent focal length, exposure program, metering, flash, white balance,
artist and copyright. Enumerated camera settings retain their standard EXIF numeric codes.
Vendor MakerNotes, such as Fujifilm film simulation or GoPro telemetry, are not interpreted.

```swift
let metadata = try await reader.getMetadata()
print(metadata.captureTime?.value as Any)       // yyyy:MM:dd HH:mm:ss
print(metadata.captureTime?.subseconds as Any)  // Preserves leading zeros
print(metadata.captureTime?.utcOffset as Any)   // Optional, e.g. +08:00
print(metadata.captureTime?.date as Any)        // nil when the offset is unknown
print(metadata.camera?.model as Any)
print(metadata.camera?.exposureTime as Any)
```

Capture time uses EXIF DateTimeOriginal, falling back to DateTimeDigitized with its matching
offset/subseconds. MOV/MP4 readers support QuickTime creation-date and camera keys, including
track-level lens information and EXIF in Canon/JPEG video previews. `creationTime` separately
reports the QuickTime movie-header timestamp using the specified 1904 epoch; camera clocks
may be incorrectly configured, and a container timestamp is not labelled as capture time.
Missing/empty fields and undefined rational values remain nil.

```bash
swift run ImageThumbnailerCLI input.raf --metadata-json
```

## Local resource library

The 35 local photos/videos live directly in `Tests/ImageThumbnailerTests/Resources/`, named
by device model with numeric suffixes for duplicates. `Unknown_Device` / `GoPro_Unknown`
identify files without enough metadata to establish a model. `ResourceManifest.json` next
to the tests records original paths, new filenames, SHA-256 hashes, source URLs where known,
and group-qualified ExifTool baselines (avoiding collisions with vendor MakerNote tags).

```bash
# Verify all installed files; download known public samples if missing.
python3 Tests/download_resources.py
# Require all 35 resources and compare extracted fields to ExifTool baselines.
REQUIRE_ALL_RESOURCES=1 swift test --filter MetadataTests
```

Only three HEIF fixtures are bundled in Git. CI verifies and tests available fixtures;
full local validation requires the complete library. The full metadata suite also covers
unknown time zones, subsecond precision, cyclic/out-of-range EXIF, 64-bit QuickTime timestamps
and zero time scales. Metadata reads for the current library are below 64 KiB per file.

## RAF validation

`RafReader` reads the RAF header and Fuji directory, then reads the embedded JPEG through a
bounded view of the file. It exposes both the EXIF thumbnail and the full camera-rendered
preview, preserving GPS and rotation. Metadata uses the active sensor crop dimensions;
older SuperCCD cameras use preview dimensions because their diagonal sensor grid is not a
rendered image rectangle. This extracts embedded previews, not full RAW demosaicing.

The offline tests generate small RAF containers to exercise byte order, orientation, GPS,
missing thumbnails, malformed headers, and read bounds. Eight CC0 samples from
[raw.pixls.us](https://raw.pixls.us/) cover X-T2, X-T5 (including sports-finder crop), GFX 100,
and FinePix S5 Pro, with uncompressed, lossless, and lossy compression. Sources and SHA-256
checksums are recorded in `Tests/raf-samples.json`; large samples stay in ignored `build/`.

```bash
python3 Tests/download_raf_samples.py
RAF_SAMPLE_DIR="$PWD/build/raf-samples" swift test --filter RafReaderTests
```

The sample test decodes every extracted JPEG, checks dimensions, and limits metadata reads
to 64 KiB and total reads to the preview size plus 100 KiB.

## Requirements

- Swift 5.9+
- macOS 11.0+ / iOS 14.0+

## License

MIT License
