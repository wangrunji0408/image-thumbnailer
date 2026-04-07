# ImageThumbnailer

A fast and efficient Swift library for extracting embedded thumbnails from various image and video formats. Designed for minimal I/O - reads only the metadata and thumbnail data, not the full file.

## Supported Formats

| Format | Extension | Metadata | Thumbnails | Notes |
|--------|-----------|----------|------------|-------|
| HEIF/HEIC | .heic, .heif, .hif | Yes | Yes | iPhone, Canon HIF, etc. |
| JPEG | .jpg, .jpeg | Yes | Yes | EXIF + MPF multi-frame |
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
| Fujifilm RAF | .raf | Proprietary format |
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

# Extract with minimum 300px short side
swift run ImageThumbnailerCLI input.heic -s 300

# Specify output path
swift run ImageThumbnailerCLI input.dng -o thumbnail.jpg
```

## Requirements

- Swift 5.9+
- macOS 11.0+ / iOS 14.0+

## License

MIT License
