import CoreGraphics
import Foundation
import ImageIO
import OSLog

private let logger = Logger(subsystem: "com.wangrunji.ImageThumbnailer", category: "JpegReader")

// MARK: - JpegReader Implementation

public class JpegReader: ImageReader {
    private let reader: Reader
    private var thumbnailEntries: [ThumbnailEntry]?
    private var metadata: Metadata?
    private var imageOrientation: UInt16?  // 存储主图像的 orientation

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        reader = Reader(readAt: readAt)
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if thumbnailEntries == nil {
            try await loadMetadata()
        }

        return thumbnailEntries?.map { entry in
            let orientation = imageOrientation ?? 1
            let (rotation, _) = orientationToRotation(orientation)

            return ThumbnailInfo(
                size: entry.length,
                format: "jpeg",
                width: entry.width,
                height: entry.height,
                rotation: rotation
            )
        } ?? []
    }

    public func getThumbnail(at index: Int) async throws -> Data {
        if thumbnailEntries == nil {
            try await loadMetadata()
        }

        guard let entries = thumbnailEntries, index < entries.count else {
            throw ImageReaderError.indexOutOfBounds
        }

        let entry = entries[index]
        let thumbnailData = try await reader.read(at: UInt64(entry.offset), length: entry.length)

        return thumbnailData
    }

    public func getMetadata() async throws -> Metadata {
        if metadata == nil {
            try await loadMetadata()
        }

        guard let metadata = metadata else {
            throw ImageReaderError.invalidData
        }
        return metadata
    }

    private func loadMetadata() async throws {
        // Read JPEG header and find EXIF data
        try await reader.prefetch(at: 0, length: 16384)

        // Validate JPEG format
        guard try await reader.read(at: 0, length: 2) == Data([0xFF, 0xD8]) else {
            throw ImageReaderError.invalidData
        }

        // First, extract main image dimensions from SOF marker
        if let (width, height) = try await extractImageDimensions(at: 0, length: 0x100000) {
            metadata = Metadata(width: width, height: height)
            logger.debug("Extracted main image dimensions: \(width)x\(height)")
        }

        // Find EXIF data and parse thumbnails
        var entries: [ThumbnailEntry] = []

        // Try to extract EXIF data - it's optional for JPEG files
        if let (exifOffset, exifLength) = try await extractExifData() {
            var ifdOffset = try await parseTiffHeader(at: exifOffset)
            var ifdIndex = 0

            while ifdOffset > 0 && ifdOffset < exifLength {
                ifdOffset = try await parseIFD(
                    exifOffset: UInt64(exifOffset),
                    ifdOffset: UInt64(ifdOffset),
                    entries: &entries,
                    isThumbnail: ifdIndex > 0,
                )
                ifdIndex += 1
            }
        } else {
            logger.debug("No EXIF data found in JPEG file")
        }

        // Look for MPF thumbnails
        let mpfEntries = try await extractMPFThumbnails()
        entries.append(contentsOf: mpfEntries)

        thumbnailEntries = entries
    }

    private func extractExifData() async throws -> (UInt64, UInt32)? {
        var offset: UInt64 = 2  // Skip JPEG SOI marker

        // Search for EXIF segment (APP1 with EXIF identifier)
        while offset < 65536 {
            let marker = try await reader.readUInt16(at: offset)
            guard (marker & 0xFF00) == 0xFF00 else { break }

            let markerType = UInt8(marker & 0xFF)
            let segmentLength = try await reader.readUInt16(at: offset + 2)

            if markerType == 0xE1 {  // APP1 segment
                let header = try await reader.readString(at: UInt64(offset + 4), length: 4)
                if header == "Exif" {
                    logger.debug("Found EXIF data at offset \(offset + 4)")
                    let exifOffset = offset + 10  // offset + 4 (segment header) + 6 (Exif\0\0)
                    let exifLength = UInt32(segmentLength - 6)  // Skip "Exif\0\0"
                    return (exifOffset, exifLength)
                }
            }

            if segmentLength < 2 { break }
            offset += 2 + UInt64(segmentLength)
        }

        return nil
    }

    private func extractImageDimensions(at imageOffset: UInt64, length: UInt32) async throws
        -> (UInt32, UInt32)?
    {
        // Validate JPEG format
        guard try await reader.read(at: imageOffset, length: 2) == Data([0xFF, 0xD8]) else {
            return nil
        }

        var offset = imageOffset + 2  // Skip SOI marker
        let maxOffset = imageOffset + UInt64(length)

        // Search for SOF marker
        while offset < maxOffset {
            let marker = try await reader.readUInt16(at: offset, byteOrder: .bigEndian)
            guard (marker & 0xFF00) == 0xFF00 else { break }

            let markerType = UInt8(marker & 0xFF)
            let segmentLength = try await reader.readUInt16(at: offset + 2, byteOrder: .bigEndian)

            // SOF markers: 0xC0-0xCF (except 0xC4, 0xC8, 0xCC which are not SOF)
            if (markerType >= 0xC0 && markerType <= 0xCF) && markerType != 0xC4
                && markerType != 0xC8 && markerType != 0xCC
            {
                let height = UInt32(
                    try await reader.readUInt16(at: offset + 5, byteOrder: .bigEndian))
                let width = UInt32(
                    try await reader.readUInt16(at: offset + 7, byteOrder: .bigEndian))
                return (width, height)
            }

            if segmentLength < 2 { break }
            offset += 2 + UInt64(segmentLength)
        }

        return nil
    }

    private func parseTiffHeader(at offset: UInt64) async throws -> UInt32 {
        // Check byte order
        let byteOrderData = try await reader.read(at: offset, length: 2)
        if byteOrderData[0] == 0x49, byteOrderData[1] == 0x49 {  // "II" - Intel (little endian)
            reader.setByteOrder(.littleEndian)
        } else if byteOrderData[0] == 0x4D, byteOrderData[1] == 0x4D {  // "MM" - Motorola (big endian)
            reader.setByteOrder(.bigEndian)
        } else {
            throw ImageReaderError.invalidData
        }

        // Check magic number (42)
        let magic = try await reader.readUInt16(at: offset + 2)
        guard magic == 42 else { throw ImageReaderError.invalidData }

        // Read IFD offset
        let ifdOffset = try await reader.readUInt32(at: offset + 4)

        return ifdOffset
    }

    private func parseIFD(
        exifOffset: UInt64,
        ifdOffset: UInt64,
        entries: inout [ThumbnailEntry],
        isThumbnail: Bool,
    ) async throws -> UInt32 {
        let absoluteIfdOffset = exifOffset + ifdOffset

        let entryCount = try await reader.readUInt16(at: absoluteIfdOffset)
        let entriesDataLength = UInt32(entryCount * 12 + 4)  // 12 bytes per entry + 4 bytes for next IFD offset

        // Prefetch all IFD entries for dense reading
        try await reader.prefetch(at: absoluteIfdOffset, length: entriesDataLength)

        var currentOffset = absoluteIfdOffset + 2

        var thumbnailOffset: UInt32?
        var thumbnailLength: UInt32?
        var thumbnailWidth: UInt32?
        var thumbnailHeight: UInt32?

        logger.debug(
            "Parsing IFD at offset \(ifdOffset), isThumbnail: \(isThumbnail), entryCount: \(entryCount)"
        )

        // Parse directory entries
        for _ in 0..<entryCount {
            let tag = try await reader.readUInt16(at: currentOffset)
            let type = try await reader.readUInt16(at: currentOffset + 2)
            let _ = try await reader.readUInt32(at: currentOffset + 4)  // count
            let value =
                if type == 3 {
                    try UInt32(await reader.readUInt16(at: currentOffset + 8))
                } else {
                    try await reader.readUInt32(at: currentOffset + 8)
                }

            if isThumbnail {
                switch tag {
                case 0x0201:  // JPEGInterchangeFormat (thumbnail offset)
                    thumbnailOffset = value
                case 0x0202:  // JPEGInterchangeFormatLength (thumbnail length)
                    thumbnailLength = value
                case 0x0100:  // ImageWidth
                    thumbnailWidth = value
                case 0x0101:  // ImageLength (Height)
                    thumbnailHeight = value
                default:
                    break
                }
            } else {
                switch tag {
                case 0x8825:  // GPS IFD
                    if let gpsLocation = try await parseGPSIFD(
                        reader: reader, exifOffset: exifOffset, gpsIFDOffset: UInt64(value))
                    {
                        // Merge GPS data with existing metadata
                        if let existingMetadata = metadata {
                            metadata = Metadata(
                                width: existingMetadata.width,
                                height: existingMetadata.height,
                                duration: existingMetadata.duration,
                                location: gpsLocation
                            )
                        }
                    }
                case 0x0112:  // Orientation
                    imageOrientation = UInt16(value)
                    logger.debug("Found main image orientation: \(self.imageOrientation ?? 0)")
                default:
                    break
                }
            }

            currentOffset += 12
        }

        // If this is a thumbnail IFD and we found both offset and length
        if isThumbnail, let relativeOffset = thumbnailOffset, let length = thumbnailLength {
            // Convert relative offset to absolute offset
            let absoluteOffset = UInt32(exifOffset) + relativeOffset

            // If thumbnail dimensions are not in IFD, read them from the thumbnail JPEG data
            if thumbnailWidth == nil || thumbnailHeight == nil {
                // Read thumbnail dimensions from SOF marker
                if let (w, h) = try await extractImageDimensions(
                    at: UInt64(absoluteOffset), length: length)
                {
                    thumbnailWidth = w
                    thumbnailHeight = h
                    logger.debug("Extracted thumbnail dimensions from SOF: \(w)x\(h)")
                }
            }

            let entry = ThumbnailEntry(
                offset: absoluteOffset,
                length: length,
                width: thumbnailWidth,
                height: thumbnailHeight,
            )
            entries.append(entry)
            logger.debug(
                "Found thumbnail: relativeOffset=\(relativeOffset), absoluteOffset=\(absoluteOffset), length=\(length), width=\(thumbnailWidth ?? 0), height=\(thumbnailHeight ?? 0)"
            )
        }

        // Read next IFD offset
        let nextIFDOffset = try await reader.readUInt32(at: currentOffset)

        return nextIFDOffset
    }

    private func extractMPFThumbnails() async throws -> [ThumbnailEntry] {
        var offset: UInt64 = 2  // Skip JPEG SOI marker

        // Search for APP2 segments that contain MPF data
        while offset < 0x100000 {  // 1MB search range
            try await reader.prefetch(at: offset, length: 256)
            guard try await reader.readUInt8(at: offset) == 0xFF else {
                break
            }

            let markerType = try await reader.readUInt8(at: offset + 1)
            let segmentLength = try await reader.readUInt16(at: offset + 2, byteOrder: .bigEndian)

            if markerType == 0xE2 {  // APP2 segment
                let header = try await reader.readString(at: offset + 4, length: 4)

                // Check for MPF data - MPF format starts with "MPF\0" or directly with TIFF header
                if header == "MPF\0" || header == "MPF " {
                    logger.debug(
                        "Found MPF data in APP2 segment at offset \(offset + 4), segment size: \(segmentLength - 2)"
                    )
                    let mpfOffset = offset + 4
                    let mpfEntries = try await parseMPFData(
                        mpfOffset: mpfOffset, mpfLength: UInt32(segmentLength - 2))
                    logger.debug("MPF parsing returned \(mpfEntries.count) entries")
                    return mpfEntries
                }
            }

            if segmentLength < 2 { break }
            offset += 2 + UInt64(segmentLength)
        }

        return []
    }

    private func parseMPFData(mpfOffset: UInt64, mpfLength: UInt32) async throws -> [ThumbnailEntry]
    {
        var thumbnails: [ThumbnailEntry] = []
        guard mpfLength >= 12 else {
            logger.debug("MPF data too small: \(mpfLength) bytes")
            return thumbnails
        }

        // Prefetch MPF data for dense reading
        try await reader.prefetch(at: mpfOffset, length: mpfLength)

        // Parse MPF header
        let tiffDataOffset = mpfOffset + 4  // Skip "MPF\0" or "MPF "

        logger.debug(
            "MPF data size: \(mpfLength) bytes, TIFF data starts at offset \(tiffDataOffset)")

        // Parse TIFF header within MPF
        let ifdOffset = try await parseTiffHeader(at: tiffDataOffset)

        // Parse MP Index IFD
        let mpIndexIFDOffset = tiffDataOffset + UInt64(ifdOffset)

        let entryCount = try await reader.readUInt16(at: mpIndexIFDOffset)
        let entriesDataLength = UInt32(entryCount * 12 + 4)  // 12 bytes per entry + 4 bytes for next IFD offset

        // Prefetch all IFD entries for dense reading
        try await reader.prefetch(at: mpIndexIFDOffset, length: entriesDataLength)

        var currentOffset = mpIndexIFDOffset + 2

        logger.debug("MPF Index IFD at offset \(mpIndexIFDOffset) has \(entryCount) entries")

        var numberOfImages: UInt32 = 0
        var mpEntryOffset: UInt64 = 0

        // Parse MP Index IFD entries
        for _ in 0..<entryCount {
            let tag = try await reader.readUInt16(at: currentOffset)
            let type = try await reader.readUInt16(at: currentOffset + 2)
            let count = try await reader.readUInt32(at: currentOffset + 4)
            let valueOffset = try await reader.readUInt32(at: currentOffset + 8)

            switch tag {
            case 0xB000:  // MP Format Version
                logger.debug("MP Format Version found")
            case 0xB001:  // Number of Images
                numberOfImages = valueOffset
                logger.debug("Number of Images: \(numberOfImages)")
            case 0xB002:  // MP Entry
                if type == 7, count > 0 {  // UNDEFINED type with count > 0
                    // MP Entry data location depends on the count
                    if count <= 4 {
                        // Data is stored directly in the valueOffset field
                        mpEntryOffset = currentOffset + 8  // Point to the valueOffset field itself
                    } else {
                        // Data is stored at the offset pointed by valueOffset
                        // The offset is relative to the start of the TIFF header
                        mpEntryOffset = tiffDataOffset + UInt64(valueOffset)
                    }
                    logger.debug(
                        "MP Entry offset: \(mpEntryOffset), count: \(count), type: \(type)")
                }
            default:
                break
            }

            currentOffset += 12
        }

        // Parse MP Entry data
        if numberOfImages > 0, mpEntryOffset > 0 {
            let mpEntries = try await parseMPEntries(
                entryOffset: mpEntryOffset,
                numberOfImages: Int(numberOfImages),
                mpfOffset: mpfOffset
            )
            thumbnails.append(contentsOf: mpEntries)
        }

        return thumbnails
    }

    private func parseMPEntries(
        entryOffset: UInt64,
        numberOfImages: Int,
        mpfOffset: UInt64
    ) async throws -> [ThumbnailEntry] {
        var thumbnails: [ThumbnailEntry] = []

        logger.debug("Parsing \(numberOfImages) MP entries at offset \(entryOffset)")

        // Prefetch all MP entries for dense reading (16 bytes per entry)
        let entriesDataLength = UInt32(numberOfImages * 16)
        try await reader.prefetch(at: entryOffset, length: entriesDataLength)

        // Parse all MP entries
        var tempOffset = entryOffset

        for i in 0..<numberOfImages {
            let imageAttributes = try await reader.readUInt32(at: tempOffset)
            let imageSize = try await reader.readUInt32(at: tempOffset + 4)
            let imageOffset = try await reader.readUInt32(at: tempOffset + 8)
            let _ = try await reader.readUInt16(at: tempOffset + 12)  // dependent1
            let _ = try await reader.readUInt16(at: tempOffset + 14)  // dependent2

            // Extract flags, format, and type from imageAttributes
            let flags = (imageAttributes & 0xF800_0000) >> 27
            let format = (imageAttributes & 0x0700_0000) >> 24
            let type = imageAttributes & 0x00FF_FFFF

            logger.debug(
                "MP Entry \(i): flags=\(String(flags, radix: 16), privacy: .public), format=\(format), type=0x\(String(type, radix: 16), privacy: .public), size=\(imageSize), offset=\(imageOffset)"
            )

            // Process entry to create thumbnail
            // Skip invalid entries
            guard imageSize > 0, imageSize < 50_000_000 else {
                logger.debug("Skipping entry \(i): invalid size \(imageSize)")
                tempOffset += 16
                continue
            }

            // Determine if this is a preview/thumbnail image
            let isPreview: Bool
            switch type {
            case 0x010001...0x010005:  // Large Thumbnails
                isPreview = true
            case 0x020001...0x020003:  // Multi-frame images
                isPreview = true
            case 0x040000:  // Original Preservation Image
                isPreview = true
            case 0x050000:  // Gain Map Image
                isPreview = true
            case 0x030000:  // Baseline MP Primary Image
                isPreview = false
            default:
                // Check if it's a large thumbnail type (0x01xxxx)
                isPreview = (type & 0xFF0000) == 0x010000
            }

            logger.debug("MP Entry \(i): isPreview=\(isPreview), type=0x\(String(type, radix: 16))")

            // Only extract preview/thumbnail images, skip primary image
            guard isPreview else {
                logger.debug("Skipping entry \(i): not a preview/thumbnail")
                tempOffset += 16
                continue
            }

            // Calculate absolute offset
            if imageOffset == 0 {
                // Offset 0 means this is the primary image at the start of the file
                // For thumbnails, this shouldn't happen, but handle it gracefully
                logger.debug("Skipping entry \(i): offset is 0")
                tempOffset += 16
                continue
            }

            // MPF offsets are relative to the start of the APP2 segment
            let absoluteOffset = UInt32(mpfOffset) + 4 + imageOffset

            // Extract dimensions from MPF thumbnail JPEG data
            var width: UInt32?
            var height: UInt32?
            if let (w, h) = try await extractImageDimensions(
                at: UInt64(absoluteOffset), length: imageSize)
            {
                width = w
                height = h
                logger.debug("Extracted MPF thumbnail dimensions from SOF: \(w)x\(h)")
            }

            let thumbnailEntry = ThumbnailEntry(
                offset: absoluteOffset,
                length: imageSize,
                width: width,
                height: height,
            )
            thumbnails.append(thumbnailEntry)
            logger.debug(
                "Found MPF thumbnail: offset=\(absoluteOffset), size=\(imageSize), dimensions=\(width ?? 0)x\(height ?? 0), type=0x\(String(type, radix: 16))"
            )

            tempOffset += 16
        }

        return thumbnails
    }
}

// MARK: - Internal Types

private struct ThumbnailEntry {
    let offset: UInt32
    let length: UInt32
    let width: UInt32?
    let height: UInt32?
}

// MARK: - Utility Functions

private func orientationToRotation(_ orientation: UInt16) -> (Int, Bool) {
    switch orientation {
    case 1: return (0, false)  // Normal
    case 2: return (0, true)  // Mirror horizontal (no rotation, just flip)
    case 3: return (180, false)  // Rotate 180°
    case 4: return (180, true)  // Mirror vertical (180° + flip)
    case 5: return (270, true)  // Mirror horizontal and rotate 270° CW
    case 6: return (90, false)  // Rotate 90° CW
    case 7: return (90, true)  // Mirror horizontal and rotate 90° CW
    case 8: return (270, false)  // Rotate 270° CW
    default: return (0, false)  // Unknown orientation, default to normal
    }
}

private func getThumbnailDimensions(_ data: Data) -> (width: UInt32, height: UInt32) {
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
        let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber
    else {
        return (0, 0)
    }

    return (UInt32(width.intValue), UInt32(height.intValue))
}
