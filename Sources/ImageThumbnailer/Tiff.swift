import CoreGraphics
import Foundation
import ImageIO
import OSLog

private let logger = Logger(subsystem: "com.wangrunji.ImageThumbnailer", category: "TiffReader")

// MARK: - TiffReader Implementation

/// Generic TIFF-based image reader for formats like DNG and ARW
public class TiffReader: ImageReader {
    private let reader: Reader
    private var thumbnailEntries: [ThumbnailEntry]?
    private var metadata: Metadata?
    private var orientation: UInt16?

    /// Strategy for determining main image dimensions in IFD0
    /// - useIfd0: Use ImageWidth/ImageHeight from IFD0 directly (ARW)
    /// - useSubIfd: Use dimensions from SubIFD tag (DNG)
    private let mainImageStrategy: MainImageStrategy

    public enum MainImageStrategy {
        case useIfd0  // ARW: Main image dimensions are in IFD0
        case useSubIfd  // DNG: Main image dimensions are in SubIFD
    }

    public init(
        readAt: @escaping (UInt64, UInt32) async throws -> Data,
        mainImageStrategy: MainImageStrategy = .useIfd0
    ) {
        reader = Reader(readAt: readAt)
        self.mainImageStrategy = mainImageStrategy
    }

    public required convenience init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        self.init(readAt: readAt, mainImageStrategy: .useIfd0)
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if thumbnailEntries == nil {
            try await loadMetadata()
        }

        return thumbnailEntries?.map { entry in
            ThumbnailInfo(
                size: entry.length,
                format: "jpeg",
                width: entry.width,
                height: entry.height,
                rotation: orientationToRotation(orientation)
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
        return try await reader.read(at: UInt64(entry.offset), length: entry.length)
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
        // Read TIFF header and validate format
        try await reader.prefetch(at: 0, length: 4096)
        let ifdOffset = try await parseTiffHeader()

        // Parse IFDs to find thumbnail entries and main image dimensions
        var entries: [ThumbnailEntry] = []
        var currentIfdOffset = ifdOffset
        var ifdIndex = 0
        var mainImageWidth: UInt32 = 0
        var mainImageHeight: UInt32 = 0

        while currentIfdOffset > 0 && ifdIndex < 10 {
            let nextIfdOffset = try await parseIFDForDataAndDimensions(
                ifdOffset: currentIfdOffset,
                entries: &entries,
                mainWidth: &mainImageWidth,
                mainHeight: &mainImageHeight,
                ifdIndex: ifdIndex
            )

            currentIfdOffset = nextIfdOffset
            ifdIndex += 1
        }

        // If we couldn't find main image dimensions, throw error
        if mainImageWidth == 0 || mainImageHeight == 0 {
            throw ImageReaderError.invalidData
        }

        thumbnailEntries = entries
        metadata = Metadata(width: mainImageWidth, height: mainImageHeight)
    }

    private func parseIFDForDataAndDimensions(
        ifdOffset: UInt32,
        entries: inout [ThumbnailEntry],
        mainWidth: inout UInt32,
        mainHeight: inout UInt32,
        ifdIndex: Int
    ) async throws -> UInt32 {
        try await reader.prefetch(at: UInt64(ifdOffset), length: 256)
        let entryCount = try await reader.readUInt16(at: UInt64(ifdOffset))

        var thumbnailOffset: UInt32?
        var thumbnailLength: UInt32?
        var thumbnailWidth: UInt32?
        var thumbnailHeight: UInt32?
        var subfileType: UInt32?

        for i in 0..<entryCount {
            let entryOffset = UInt64(ifdOffset) + 2 + UInt64(i) * 12

            let tag = try await reader.readUInt16(at: entryOffset)
            let type = try await reader.readUInt16(at: entryOffset + 2)
            // let count = try await reader.readUInt32(offset: entryOffset + 4)
            let value =
                if type == 3 {
                    try UInt32(await reader.readUInt16(at: entryOffset + 8))
                } else {
                    try await reader.readUInt32(at: entryOffset + 8)
                }

            switch tag {
            case 0x00FE:  // SubfileType
                subfileType = value
            // For DNG: 0 = Full-resolution, 1 = Reduced-resolution (preview)
            // For ARW: Check if this is the main image IFD

            case 0x0100:  // ImageWidth
                switch mainImageStrategy {
                case .useIfd0:
                    // ARW: Main image dimensions are in IFD0
                    if ifdIndex == 0 {
                        mainWidth = value
                    } else {
                        thumbnailWidth = value
                    }
                case .useSubIfd:
                    // DNG: Only use if this is full-resolution image (subfileType == 0) in IFD0
                    if ifdIndex == 0 && subfileType == 0 {
                        mainWidth = value
                    } else {
                        thumbnailWidth = value
                    }
                }

            case 0x0101:  // ImageHeight
                switch mainImageStrategy {
                case .useIfd0:
                    if ifdIndex == 0 {
                        mainHeight = value
                    } else {
                        thumbnailHeight = value
                    }
                case .useSubIfd:
                    if ifdIndex == 0 && subfileType == 0 {
                        mainHeight = value
                    } else {
                        thumbnailHeight = value
                    }
                }

            case 0x0111:  // StripOffsets or ThumbnailOffset
                thumbnailOffset = value

            case 0x0117:  // StripByteCounts or ThumbnailLength
                thumbnailLength = value

            case 0x0201:  // JPEGInterchangeFormat (thumbnail/preview offset)
                thumbnailOffset = value

            case 0x0202:  // JPEGInterchangeFormatLength (thumbnail/preview length)
                thumbnailLength = value

            case 0x0112:  // Orientation
                if ifdIndex == 0 {  // Only use orientation from main IFD
                    orientation = UInt16(value)
                }

            case 0x014A:  // SubIFD
                let subIfdOffset = value
                let subIfdDimensions = try await parseSubIFDForDimensions(
                    subIfdOffset: UInt64(subIfdOffset))

                switch mainImageStrategy {
                case .useIfd0:
                    // ARW: Use SubIFD dimensions for main image if in IFD0
                    if ifdIndex == 0 {
                        mainWidth = subIfdDimensions.width
                        mainHeight = subIfdDimensions.height
                    } else {
                        thumbnailWidth = subIfdDimensions.width
                        thumbnailHeight = subIfdDimensions.height
                    }
                case .useSubIfd:
                    // DNG: Always use SubIFD dimensions for main image if in IFD0
                    if ifdIndex == 0 {
                        mainWidth = subIfdDimensions.width
                        mainHeight = subIfdDimensions.height
                    }
                }

            default:
                break
            }
        }

        // Add thumbnail entry if we found valid thumbnail data
        if let thumbnailOffset = thumbnailOffset, let thumbnailLength = thumbnailLength {
            // If dimensions not found in IFD, extract from JPEG data
            if thumbnailWidth == nil || thumbnailHeight == nil {
                if let (w, h) = try await extractImageDimensions(
                    at: UInt64(thumbnailOffset), length: thumbnailLength)
                {
                    thumbnailWidth = w
                    thumbnailHeight = h
                    logger.debug("Extracted thumbnail dimensions from SOF: \(w)x\(h)")
                }
            }

            let entry = ThumbnailEntry(
                offset: thumbnailOffset,
                length: thumbnailLength,
                width: thumbnailWidth,
                height: thumbnailHeight
            )
            entries.append(entry)
            logger.debug(
                "Found JPEG thumbnail: offset=\(thumbnailOffset), length=\(thumbnailLength), width=\(thumbnailWidth ?? 0), height=\(thumbnailHeight ?? 0)"
            )
        }

        // Read next IFD offset
        let nextIfdOffsetLocation = UInt64(ifdOffset) + 2 + UInt64(entryCount) * 12
        let nextIfdOffset = try await reader.readUInt32(at: nextIfdOffsetLocation)

        return nextIfdOffset
    }

    private func parseSubIFDForDimensions(subIfdOffset: UInt64) async throws -> (
        width: UInt32, height: UInt32
    ) {
        // Read SubIFD header
        try await reader.prefetch(at: subIfdOffset, length: 1024)
        let entryCount = try await reader.readUInt16(at: subIfdOffset)

        var width: UInt32 = 0
        var height: UInt32 = 0

        for i in 0..<Int(entryCount) {
            let entryOffset = subIfdOffset + 2 + UInt64(i) * 12

            let tag = try await reader.readUInt16(at: entryOffset)
            let type = try await reader.readUInt16(at: entryOffset + 2)
            // let count = try await reader.readUInt32(offset: entryOffset + 4)
            let value =
                if type == 3 {
                    try UInt32(await reader.readUInt16(at: entryOffset + 8))
                } else {
                    try await reader.readUInt32(at: entryOffset + 8)
                }

            switch tag {
            case 0x0100:  // ImageWidth
                width = value
            case 0x0101:  // ImageHeight
                height = value
            default:
                break
            }
        }

        return (width, height)
    }

    private func parseTiffHeader() async throws -> UInt32 {
        let data = try await reader.read(at: 0, length: 2)
        guard data.count >= 2 else { throw ImageReaderError.invalidData }

        if data[0] == 0x49, data[1] == 0x49 {  // "II" - Intel (little endian)
            reader.setByteOrder(.littleEndian)
        } else if data[0] == 0x4D, data[1] == 0x4D {  // "MM" - Motorola (big endian)
            reader.setByteOrder(.bigEndian)
        } else {
            throw ImageReaderError.invalidData
        }

        // Check magic number (42)
        let magic = try await reader.readUInt16(at: 2)
        guard magic == 42 else { throw ImageReaderError.invalidData }

        // Get IFD offset
        let ifdOffset = try await reader.readUInt32(at: 4)

        return ifdOffset
    }

    private func orientationToRotation(_ orientation: UInt16?) -> Int? {
        guard let orientation = orientation else { return nil }

        switch orientation {
        case 1: return 0  // Top-left (normal)
        case 3: return 180  // Bottom-right (rotate 180)
        case 6: return 90  // Right-top (rotate 90 CW)
        case 8: return 270  // Left-bottom (rotate 270 CW or 90 CCW)
        default: return 0  // Default to no rotation for unknown orientations
        }
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
}

// MARK: - Internal Types

private struct ThumbnailEntry {
    let offset: UInt32
    let length: UInt32
    let width: UInt32?
    let height: UInt32?
}
