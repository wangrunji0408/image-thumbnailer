# ImageThumbnailer

Swift library + CLI for extracting embedded thumbnails from image/video files with minimal I/O reads.

## Build & Test

```bash
swift build
swift test
swift run ImageThumbnailerCLI <file> [-s <short-side-length>] [-t <index>] [-o <output>]
```

## Architecture

- `Sources/ImageThumbnailer/` - Library target
  - `Lib.swift` - Public API: `ImageReader` protocol, `ThumbnailInfo`, `Metadata` structs
  - `Reader.swift` - Low-level buffered I/O with byte-order handling
  - `Tiff.swift` - TIFF-based RAW readers: ARW, DNG, NEF, PEF, ORF, RW2, CR2 (all extend `TiffReader`)
  - `Cr3.swift` - Canon CR3 (ISOBMFF container)
  - `Heif.swift` - HEIF/HEIC reader
  - `Jpeg.swift` - JPEG with EXIF/MPF support
  - `Mp4.swift` - MP4/MOV video
  - `HeifWriter.swift` - HEIC writer for wrapping HEVC data
  - `GPSParser.swift` - GPS extraction from EXIF
- `Sources/ImageThumbnailerCLI/main.swift` - CLI entry point
- `Tests/ImageThumbnailerTests/` - Tests with sample files in `Resources/`

## Key Design Decisions

- All readers use async `readAt: (UInt64, UInt32) -> Data` callback for lazy I/O
- `TiffReader` has `MainImageStrategy`: `.useIfd0` (ARW, CR2, PEF, ORF, RW2) vs `.useSubIfd` (DNG, NEF)
- Thumbnails validated as standard JPEG (not lossless JPEG used in RAW data) via SOF marker check
- CLI `-s` flag selects smallest thumbnail with width >= requested value
- Test sample files at `Tests/ImageThumbnailerTests/Resources/` (see `test_batch_raw.sh` for larger file tests)
