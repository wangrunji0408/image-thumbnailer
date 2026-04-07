import Foundation
import OSLog

private let logger = Logger(subsystem: "com.wangrunji.ImageThumbnailer", category: "Cr3Reader")

/// Canon UUID: 85c0b687-820f-11e0-8111-f4ce462b6a48
private let canonUUID: [UInt8] = [
    0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0,
    0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48,
]

// MARK: - Cr3Reader Implementation

/// Canon CR3 (RAW) image reader
/// CR3 files use ISOBMFF container with track-based structure
public class Cr3Reader: ImageReader {
    private let reader: Reader
    private var thumbnailEntries: [Cr3ThumbnailEntry]?
    private var cachedMetadata: Metadata?

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        reader = Reader(readAt: readAt)
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if thumbnailEntries == nil { try await loadMetadata() }
        return thumbnailEntries?.map { entry in
            ThumbnailInfo(
                size: UInt32(entry.size),
                format: entry.format,
                width: entry.width,
                height: entry.height,
                rotation: entry.rotation
            )
        } ?? []
    }

    public func getThumbnail(at index: Int) async throws -> Data {
        if thumbnailEntries == nil { try await loadMetadata() }
        guard let entries = thumbnailEntries, index < entries.count else {
            throw ImageReaderError.indexOutOfBounds
        }
        let entry = entries[index]
        let rawData = try await reader.read(at: entry.offset, length: UInt32(entry.size))

        // For HEVC thumbnails, wrap in HEIC container
        if let hevcEntry = entry.hevcEntry {
            let heicData = try await createHEICFromHEVC(hevcEntry, hevcData: rawData)
            if let heicData { return heicData }
        }
        return rawData
    }

    public func getMetadata() async throws -> Metadata {
        if cachedMetadata == nil { try await loadMetadata() }
        guard let metadata = cachedMetadata else { throw ImageReaderError.invalidData }
        return metadata
    }

    // MARK: - Core Parsing

    private func loadMetadata() async throws {
        // 1. Validate ftyp
        try await reader.prefetch(at: 0, length: 4096)
        let ftypSize = try await reader.readUInt32(at: 0, byteOrder: .bigEndian)
        let ftypType = try await reader.readString(at: 4, length: 4)
        guard ftypType == "ftyp" else { throw ImageReaderError.invalidData }

        let brand = try await reader.readString(at: 8, length: 4)
        guard brand == "crx " else { throw ImageReaderError.unsupportedFormat }

        // 2. Find moov box
        let (moovOffset, moovSize) = try await findBox(
            named: "moov", in: UInt64(ftypSize), length: nil)

        try await reader.prefetch(at: moovOffset, length: min(moovSize, 65536))

        // 3. Parse moov children
        var mainWidth: UInt32 = 0
        var mainHeight: UInt32 = 0
        var entries: [Cr3ThumbnailEntry] = []

        let moovDataStart = moovOffset + 8
        let moovDataEnd = moovOffset + UInt64(moovSize)
        var offset = moovDataStart

        while offset + 8 <= moovDataEnd {
            let boxSize = try await reader.readUInt32(at: offset, byteOrder: .bigEndian)
            let boxType = try await reader.readString(at: offset + 4, length: 4)
            guard boxSize >= 8 else { break }

            switch boxType {
            case "uuid":
                // Check if this is the Canon UUID box
                let uuidData = try await reader.read(at: offset + 8, length: 16)
                if Array(uuidData) == canonUUID {
                    let result = try await parseCanonUUID(
                        at: offset + 24, size: UInt32(boxSize) - 24)
                    mainWidth = result.width
                    mainHeight = result.height
                    if let thmb = result.thumbnail {
                        entries.append(thmb)
                    }
                }

            case "trak":
                if let trackEntry = try await parseTrack(
                    at: offset + 8, size: UInt32(boxSize) - 8)
                {
                    entries.append(trackEntry)
                }

            default:
                break
            }

            offset += UInt64(boxSize)
        }

        guard mainWidth > 0 && mainHeight > 0 else { throw ImageReaderError.invalidData }

        // Sort thumbnails by size (smallest first)
        entries.sort { $0.size < $1.size }

        thumbnailEntries = entries
        cachedMetadata = Metadata(width: mainWidth, height: mainHeight)
    }

    // MARK: - Canon UUID Box Parsing

    private struct CanonUUIDResult {
        var width: UInt32 = 0
        var height: UInt32 = 0
        var orientation: UInt16 = 1
        var thumbnail: Cr3ThumbnailEntry?
    }

    private func parseCanonUUID(at start: UInt64, size: UInt32) async throws -> CanonUUIDResult {
        var result = CanonUUIDResult()
        let end = start + UInt64(size)
        var offset = start

        while offset + 8 <= end {
            let boxSize = try await reader.readUInt32(at: offset, byteOrder: .bigEndian)
            let boxType = try await reader.readString(at: offset + 4, length: 4)
            guard boxSize >= 8 else { break }

            switch boxType {
            case "CMT1":
                // TIFF IFD with ImageWidth, ImageHeight, Orientation
                let tiffStart = offset + 8
                let dims = try await parseTiffIFD(at: tiffStart)
                if dims.width > 0 { result.width = dims.width }
                if dims.height > 0 { result.height = dims.height }
                result.orientation = dims.orientation

            case "THMB":
                let dataStart = offset + 8
                let version = try await reader.readUInt8(at: dataStart)

                if version == 0 {
                    // THMB v0: JPEG thumbnail
                    // Header: version(4) + width(2) + height(2) + jpegSize(4) + padding(4) = 16 bytes
                    let thmbWidth = try await reader.readUInt16(
                        at: dataStart + 4, byteOrder: .bigEndian)
                    let thmbHeight = try await reader.readUInt16(
                        at: dataStart + 6, byteOrder: .bigEndian)
                    let jpegSize = try await reader.readUInt32(
                        at: dataStart + 8, byteOrder: .bigEndian)
                    let jpegOffset = dataStart + 16

                    result.thumbnail = Cr3ThumbnailEntry(
                        offset: jpegOffset,
                        size: jpegSize,
                        width: UInt32(thmbWidth),
                        height: UInt32(thmbHeight),
                        rotation: orientationToRotation(result.orientation),
                        format: "jpeg",
                        hevcEntry: nil
                    )
                } else {
                    // THMB v1: HEVC thumbnail
                    // Header: version(1) + pad(3) + unk(2) + width(2) + unk(4) + dataSize(4) = 16 bytes
                    // Followed by sub-boxes: CISZ, hvcC, colr, pixi, IMGD
                    let thmbEnd = offset + UInt64(boxSize)
                    var thmbWidth: UInt32 = 0
                    var thmbHeight: UInt32 = 0
                    var hvcCData: Data?
                    var imgdOffset: UInt64 = 0
                    var imgdSize: UInt32 = 0

                    var subOff = dataStart + 16
                    while subOff + 8 <= thmbEnd {
                        let subSize = try await reader.readUInt32(
                            at: subOff, byteOrder: .bigEndian)
                        let subType = try await reader.readString(
                            at: subOff + 4, length: 4)
                        guard subSize >= 8 else { break }

                        switch subType {
                        case "CISZ":
                            if subSize >= 20 {
                                thmbWidth = try await reader.readUInt32(
                                    at: subOff + 12, byteOrder: .bigEndian)
                                thmbHeight = try await reader.readUInt32(
                                    at: subOff + 16, byteOrder: .bigEndian)
                            }
                        case "hvcC":
                            hvcCData = try await reader.read(
                                at: subOff + 8, length: subSize - 8)
                        case "IMGD":
                            // IMGD data has a 4-byte length prefix before the actual HEVC NAL units
                            imgdOffset = subOff + 8 + 4
                            imgdSize = subSize - 8 - 4
                        default:
                            break
                        }
                        subOff += UInt64(subSize)
                    }

                    if imgdSize > 0, let hvcCData {
                        // Build properties for HeifWriter
                        var properties: [ItemProperty] = []

                        // ispe (image spatial extents)
                        var ispeData = Data()
                        ispeData.append(contentsOf: [0, 0, 0, 0])  // version/flags
                        withUnsafeBytes(of: thmbWidth.bigEndian) { ispeData.append(contentsOf: $0) }
                        withUnsafeBytes(of: thmbHeight.bigEndian) {
                            ispeData.append(contentsOf: $0)
                        }
                        properties.append(ItemProperty(
                            propertyIndex: 1, propertyType: "ispe",
                            rotation: nil, width: thmbWidth, height: thmbHeight,
                            rawData: ispeData))

                        // hvcC
                        properties.append(ItemProperty(
                            propertyIndex: 2, propertyType: "hvcC",
                            rotation: nil, width: nil, height: nil,
                            rawData: hvcCData))

                        let hevcEntry = HeifThumbnailEntry(
                            itemId: 1,
                            offset: 0, size: imgdSize,
                            rotation: orientationToRotation(result.orientation),
                            width: thmbWidth, height: thmbHeight,
                            type: "hvc1",
                            properties: properties
                        )

                        result.thumbnail = Cr3ThumbnailEntry(
                            offset: imgdOffset,
                            size: imgdSize,
                            width: thmbWidth,
                            height: thmbHeight,
                            rotation: orientationToRotation(result.orientation),
                            format: "heic",
                            hevcEntry: hevcEntry
                        )
                    }
                }

            default:
                break
            }

            offset += UInt64(boxSize)
        }

        return result
    }

    // MARK: - TIFF IFD Parsing (for CMT1)

    private func parseTiffIFD(at tiffStart: UInt64) async throws -> (
        width: UInt32, height: UInt32, orientation: UInt16
    ) {
        // TIFF header: byte order (2) + magic (2) + IFD offset (4)
        let bo = try await reader.read(at: tiffStart, length: 2)
        let byteOrder: ByteOrder =
            (bo[0] == 0x49 && bo[1] == 0x49) ? .littleEndian : .bigEndian

        let ifdOffset = try await reader.readUInt32(at: tiffStart + 4, byteOrder: byteOrder)
        let ifdStart = tiffStart + UInt64(ifdOffset)
        let entryCount = try await reader.readUInt16(at: ifdStart, byteOrder: byteOrder)

        var width: UInt32 = 0
        var height: UInt32 = 0
        var orientation: UInt16 = 1

        for i in 0..<entryCount {
            let entryOffset = ifdStart + 2 + UInt64(i) * 12
            let tag = try await reader.readUInt16(at: entryOffset, byteOrder: byteOrder)
            let type = try await reader.readUInt16(at: entryOffset + 2, byteOrder: byteOrder)
            let value: UInt32 =
                if type == 3 {  // SHORT
                    UInt32(
                        try await reader.readUInt16(at: entryOffset + 8, byteOrder: byteOrder))
                } else {
                    try await reader.readUInt32(at: entryOffset + 8, byteOrder: byteOrder)
                }

            switch tag {
            case 0x0100: width = value
            case 0x0101: height = value
            case 0x0112: orientation = UInt16(value)
            default: break
            }
        }

        return (width, height, orientation)
    }

    // MARK: - Track Parsing

    private func parseTrack(at start: UInt64, size: UInt32) async throws -> Cr3ThumbnailEntry? {
        let end = start + UInt64(size)

        // Read tkhd for dimensions
        guard let (tkhdOffset, _) = try? await findChildBox(named: "tkhd", in: start, end: end)
        else { return nil }

        try await reader.prefetch(at: tkhdOffset, length: 256)
        let version = try await reader.readUInt8(at: tkhdOffset + 8)
        let matrixOffset: UInt64 = tkhdOffset + 8 + (version == 0 ? 40 : 52)
        // Width/height are after the 36-byte matrix
        let widthFixed = try await reader.readUInt32(
            at: matrixOffset + 36, byteOrder: .bigEndian)
        let heightFixed = try await reader.readUInt32(
            at: matrixOffset + 40, byteOrder: .bigEndian)
        let trackWidth = widthFixed >> 16
        let trackHeight = heightFixed >> 16

        // Find mdia -> minf -> stbl
        guard let (mdiaOffset, mdiaSize) = try? await findChildBox(named: "mdia", in: start, end: end)
        else { return nil }
        let mdiaEnd = mdiaOffset + UInt64(mdiaSize)

        guard
            let (minfOffset, minfSize) = try? await findChildBox(
                named: "minf", in: mdiaOffset + 8, end: mdiaEnd)
        else { return nil }
        let minfEnd = minfOffset + UInt64(minfSize)

        guard
            let (stblOffset, stblSize) = try? await findChildBox(
                named: "stbl", in: minfOffset + 8, end: minfEnd)
        else { return nil }
        let stblEnd = stblOffset + UInt64(stblSize)

        try await reader.prefetch(at: stblOffset, length: min(stblSize, 4096))

        // Find data offset (co64 or stco) and size (stsz)
        var dataOffset: UInt64 = 0
        var dataSize: UInt32 = 0

        var boxOff = stblOffset + 8
        while boxOff + 8 <= stblEnd {
            let bSize = try await reader.readUInt32(at: boxOff, byteOrder: .bigEndian)
            let bType = try await reader.readString(at: boxOff + 4, length: 4)
            guard bSize >= 8 else { break }

            switch bType {
            case "co64":
                // version(4) + entry_count(4) + first_offset(8)
                dataOffset = try await reader.readUInt64(at: boxOff + 16, byteOrder: .bigEndian)
            case "stco":
                dataOffset = UInt64(
                    try await reader.readUInt32(at: boxOff + 16, byteOrder: .bigEndian))
            case "stsz":
                // version(4) + sample_size(4) + sample_count(4) [+ per-sample sizes]
                let sampleSize = try await reader.readUInt32(
                    at: boxOff + 12, byteOrder: .bigEndian)
                if sampleSize != 0 {
                    dataSize = sampleSize
                } else {
                    // Variable size: read first sample
                    dataSize = try await reader.readUInt32(
                        at: boxOff + 20, byteOrder: .bigEndian)
                }
            default:
                break
            }

            boxOff += UInt64(bSize)
        }

        guard dataOffset > 0 && dataSize > 0 else { return nil }

        // Check if track data is JPEG
        let header = try await reader.read(at: dataOffset, length: 2)
        guard header[0] == 0xFF && header[1] == 0xD8 else { return nil }

        logger.debug(
            "Found JPEG track: \(trackWidth)x\(trackHeight), offset=\(dataOffset), size=\(dataSize)"
        )

        return Cr3ThumbnailEntry(
            offset: dataOffset,
            size: dataSize,
            width: trackWidth,
            height: trackHeight,
            rotation: nil,
            format: "jpeg",
            hevcEntry: nil
        )
    }

    // MARK: - Box Navigation Helpers

    private func findBox(named target: String, in start: UInt64, length: UInt64?) async throws -> (
        UInt64, UInt32
    ) {
        var offset = start
        let maxOffset = length.map { start + $0 } ?? UInt64.max

        while offset + 8 <= maxOffset {
            let size = try await reader.readUInt32(at: offset, byteOrder: .bigEndian)
            let type = try await reader.readString(at: offset + 4, length: 4)
            guard size >= 8 else { throw ImageReaderError.invalidData }
            if type == target { return (offset, size) }
            offset += UInt64(size)
        }

        throw ImageReaderError.invalidData
    }

    private func findChildBox(named target: String, in start: UInt64, end: UInt64) async throws
        -> (UInt64, UInt32)?
    {
        var offset = start
        while offset + 8 <= end {
            let size = try await reader.readUInt32(at: offset, byteOrder: .bigEndian)
            let type = try await reader.readString(at: offset + 4, length: 4)
            guard size >= 8 else { return nil }
            if type == target { return (offset, size) }
            offset += UInt64(size)
        }
        return nil
    }

    private func orientationToRotation(_ orientation: UInt16) -> Int? {
        switch orientation {
        case 1: return 0
        case 3: return 180
        case 6: return 90
        case 8: return 270
        default: return 0
        }
    }
}

// MARK: - Internal Types

private struct Cr3ThumbnailEntry {
    let offset: UInt64
    let size: UInt32
    let width: UInt32
    let height: UInt32
    let rotation: Int?
    let format: String  // "jpeg" or "heic"
    let hevcEntry: HeifThumbnailEntry?  // non-nil for HEVC thumbnails
}
