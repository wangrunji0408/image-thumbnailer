import CoreGraphics
import Foundation
import ImageIO
import OSLog

private let logger = Logger(subsystem: "com.wangrunji.ImageThumbnailer", category: "HeifReader")

// MARK: - HeifReader Implementation

public class HeifReader: ImageReader {
    private let reader: Reader
    private var thumbnailInfos: [HeifThumbnailEntry]?
    private var metadata: Metadata?

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        self.reader = Reader(readAt: readAt)
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if thumbnailInfos == nil {
            try await loadMetadata()
        }

        return thumbnailInfos?.map { info in
            let format = info.type == "hvc1" ? "heic" : "jpeg"
            return ThumbnailInfo(
                size: info.size,
                format: format,
                width: info.width,
                height: info.height,
                // JPEG thumbnails need rotation correction, but HEIC thumbnails already contain rotation metadata
                rotation: format == "jpeg" ? info.rotation : nil
            )
        } ?? []
    }

    public func getThumbnail(at index: Int) async throws -> Data {
        if thumbnailInfos == nil {
            try await loadMetadata()
        }

        guard let infos = thumbnailInfos, index < infos.count else {
            throw ImageReaderError.indexOutOfBounds
        }

        let info = infos[index]
        let data = try await reader.read(at: UInt64(info.offset), length: info.size)
        return try await createThumbnail(from: info, data: data)
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
        guard let (metaOffset, metaSize) = try await readMetaBox() else {
            logger.error("Meta box not found")
            throw ImageReaderError.invalidData
        }

        // Parse the meta box once to get both thumbnails and primary image metadata
        let (thumbnails, primaryMetadata, exifLocationInfo) = try await parseMetaBoxForBoth(
            offset: metaOffset, size: metaSize)

        thumbnailInfos = thumbnails

        // Extract GPS location from EXIF if available
        var gpsLocation: GPSLocation? = nil
        if let exifInfo = exifLocationInfo {
            do {
                gpsLocation = try await parseExifForGPS(exifOffset: UInt64(exifInfo.offset))
            } catch {
                logger.error("Failed to parse EXIF GPS data: \(error)")
            }
        }

        if let width = primaryMetadata.width, let height = primaryMetadata.height {
            metadata = Metadata(width: width, height: height, location: gpsLocation)
        } else {
            throw ImageReaderError.invalidData
        }
    }

    // MARK: - Meta Box Parsing

    private func parseMetaBoxForBoth(offset: UInt64, size: UInt32) async throws -> (
        [HeifThumbnailEntry], (width: UInt32?, height: UInt32?), ItemLocation?
    ) {
        var currentOffset: UInt64 = offset + 12  // Skip meta box header + version/flags

        var items: [ItemInfo] = []
        var locations: [ItemLocation] = []
        var primaryItemId: UInt32 = 0
        var thumbnailReferences: [(from: UInt32, to: [UInt32])] = []
        var properties: [ItemProperty] = []
        var propertyAssociations: [ItemPropertyAssociation] = []

        logger.debug("Parsing meta box at offset \(offset), size: \(size) bytes")

        let endOffset = offset + UInt64(size)

        // Parse all sub-boxes
        while currentOffset + 8 < endOffset {
            let boxHeaderOffset = currentOffset
            guard let (boxSize, boxType) = try await parseBoxHeader(offset: currentOffset) else {
                break
            }
            currentOffset += 8

            let boxDataOffset = currentOffset
            let boxDataSize = boxSize > 8 ? boxSize - 8 : 0

            switch boxType {
            case "pitm":
                primaryItemId =
                    try await parsePrimaryItem(offset: boxDataOffset, size: boxDataSize) ?? 0
                logger.debug("Primary item ID: \(primaryItemId)")

            case "iinf":
                items = try await parseItemInfo(offset: boxDataOffset, size: boxDataSize)
                logger.debug("Found \(items.count) items")

            case "iloc":
                locations = try await parseItemLocation(offset: boxDataOffset, size: boxDataSize)
                logger.debug("Found \(locations.count) locations")

            case "iref":
                thumbnailReferences = try await parseItemReference(
                    offset: boxDataOffset, size: boxDataSize)
                logger.debug("Found \(thumbnailReferences.count) references")

            case "iprp":
                (properties, propertyAssociations) = try await parseItemProperties(
                    offset: boxDataOffset, size: boxDataSize)
                logger.debug(
                    "Found \(properties.count) properties, \(propertyAssociations.count) associations"
                )

            default:
                logger.debug("Skipping box type: \(boxType)")
            }

            currentOffset = boxSize > 8 ? boxHeaderOffset + UInt64(boxSize) : endOffset
        }

        // Build thumbnail infos
        let thumbnails = buildThumbnailInfos(
            items: items,
            locations: locations,
            primaryItemId: primaryItemId,
            thumbnailReferences: thumbnailReferences,
            properties: properties,
            propertyAssociations: propertyAssociations
        )

        // Get primary image metadata
        let (_, width, height, _) = extractItemProperties(
            itemId: primaryItemId,
            properties: properties,
            propertyAssociations: propertyAssociations
        )

        // Find EXIF metadata item location
        var exifLocationInfo: ItemLocation? = nil
        if let exifItem = items.first(where: { $0.itemType == "Exif" }),
            let exifLocation = locations.first(where: { $0.itemId == exifItem.itemId })
        {
            logger.debug(
                "Found EXIF item at offset \(exifLocation.offset), size \(exifLocation.length)")
            exifLocationInfo = exifLocation
        }

        return (thumbnails, (width, height), exifLocationInfo)
    }

    // MARK: - EXIF Parsing

    private func parseExifForGPS(exifOffset: UInt64) async throws -> GPSLocation? {
        // HEIF EXIF data starts with a 4-byte offset header
        let offsetHeader = try await reader.readUInt32(at: exifOffset)
        let tiffOffset = exifOffset + 4 + UInt64(offsetHeader)

        // Parse TIFF header to determine byte order
        let byteOrderMark = try await reader.readString(at: tiffOffset, length: 2)
        if byteOrderMark == "II" {  // little endian
            reader.setByteOrder(.littleEndian)
        } else if byteOrderMark == "MM" {  // big endian
            reader.setByteOrder(.bigEndian)
        } else {
            return nil
        }

        // Read IFD offset
        let ifd0Offset = try await reader.readUInt32(at: tiffOffset + 4)

        // Find GPS IFD in IFD0
        if let gpsIFDOffset = try await findGPSIFDInIFD(
            ifdOffset: tiffOffset + UInt64(ifd0Offset))
        {
            // Parse GPS IFD
            return try await parseGPSIFD(
                reader: reader,
                exifOffset: tiffOffset,
                gpsIFDOffset: UInt64(gpsIFDOffset)
            )
        }

        return nil
    }

    private func findGPSIFDInIFD(ifdOffset: UInt64) async throws -> UInt32? {
        let entryCount = try await reader.readUInt16(at: ifdOffset)

        for i in 0..<Int(entryCount) {
            let entryOffset = ifdOffset + 2 + UInt64(i) * 12
            let tag = try await reader.readUInt16(at: entryOffset)

            if tag == 0x8825 {  // GPS IFD tag
                let gpsIFDOffset = try await reader.readUInt32(at: entryOffset + 8)
                return gpsIFDOffset
            }
        }

        return nil
    }

    // MARK: - Box Parsing Utilities

    private func parseBoxHeader(offset: UInt64) async throws -> (UInt32, String)? {
        let size = try await reader.readUInt32(at: offset)
        let type = try await reader.readString(at: offset + 4, length: 4)

        return (size, type)
    }

    private func parsePrimaryItem(offset: UInt64, size: UInt32) async throws -> UInt32? {
        guard size >= 6 else { return nil }
        return UInt32(try await reader.readUInt16(at: offset + 4))
    }

    private func parseItemInfo(offset: UInt64, size: UInt32) async throws -> [ItemInfo] {
        var items: [ItemInfo] = []
        var currentOffset = offset + 4  // Skip version/flags

        guard size >= 6 else { return items }

        let entryCount = try await reader.readUInt16(at: currentOffset)
        currentOffset += 2

        for _ in 0..<entryCount {
            let boxHeaderOffset = currentOffset
            guard let (infeSize, infeType) = try await parseBoxHeader(offset: currentOffset),
                infeType == "infe", infeSize > 8
            else {
                break
            }

            let infeDataOffset = currentOffset + 8
            let infeDataSize = infeSize - 8

            if let item = try await parseInfeBox(offset: infeDataOffset, size: infeDataSize) {
                items.append(item)
            }

            currentOffset = boxHeaderOffset + UInt64(infeSize)
        }

        return items
    }

    private func parseInfeBox(offset: UInt64, size: UInt32) async throws -> ItemInfo? {
        guard size >= 12 else { return nil }

        let itemId = UInt32(try await reader.readUInt16(at: offset + 4))
        let itemType = try await reader.readString(at: offset + 8, length: 4)

        return ItemInfo(itemId: itemId, itemType: itemType, itemName: nil)
    }

    private func parseItemLocation(offset: UInt64, size: UInt32) async throws -> [ItemLocation] {
        var locations: [ItemLocation] = []
        var currentOffset = offset + 4  // Skip version/flags

        guard size > 0 else { return locations }

        let version = try await reader.readUInt8(at: offset)
        let values4 = try await reader.readUInt16(at: currentOffset)

        let offsetSize = (values4 >> 12) & 0xF
        let lengthSize = (values4 >> 8) & 0xF
        let baseOffsetSize = (values4 >> 4) & 0xF
        let indexSize = (version >= 1) ? (values4 & 0xF) : 0

        currentOffset += 2

        // Read item count
        let itemCount: UInt32
        if version < 2 {
            itemCount = UInt32(try await reader.readUInt16(at: currentOffset))
            currentOffset += 2
        } else {
            itemCount = try await reader.readUInt32(at: currentOffset)
            currentOffset += 4
        }

        for _ in 0..<itemCount {
            if let location = try await parseItemLocationEntry(
                offset: currentOffset,
                version: version,
                offsetSize: offsetSize,
                lengthSize: lengthSize,
                baseOffsetSize: baseOffsetSize,
                indexSize: indexSize,
                nextOffset: &currentOffset
            ) {
                locations.append(location)
            } else {
                break
            }
        }

        return locations
    }

    private func parseItemLocationEntry(
        offset: UInt64,
        version: UInt8,
        offsetSize: UInt16,
        lengthSize: UInt16,
        baseOffsetSize: UInt16,
        indexSize: UInt16,
        nextOffset: inout UInt64
    ) async throws -> ItemLocation? {
        var currentOffset = offset

        // Read item ID
        let itemId: UInt32
        if version < 2 {
            itemId = UInt32(try await reader.readUInt16(at: currentOffset))
            currentOffset += 2
        } else {
            itemId = try await reader.readUInt32(at: currentOffset)
            currentOffset += 4
        }

        // Skip construction_method, data_reference_index, base_offset
        let skipSize = UInt64((version >= 1 ? 2 : 0) + 2 + Int(baseOffsetSize))
        currentOffset += skipSize

        // Read extent count
        let extentCount = try await reader.readUInt16(at: currentOffset)
        currentOffset += 2

        guard extentCount > 0 else { return nil }

        // Skip extent_index
        currentOffset += UInt64(indexSize)

        // Read extent_offset
        let itemOffset: UInt32
        if offsetSize == 4 {
            itemOffset = try await reader.readUInt32(at: currentOffset)
            currentOffset += 4
        } else if offsetSize == 8 {
            let offset64 = try await reader.readUInt64(at: currentOffset)
            itemOffset = UInt32(offset64 & 0xFFFF_FFFF)
            currentOffset += 8
        } else {
            return nil
        }

        // Read extent_length
        let itemLength: UInt32
        if lengthSize == 4 {
            itemLength = try await reader.readUInt32(at: currentOffset)
            currentOffset += 4
        } else if lengthSize == 8 {
            let length64 = try await reader.readUInt64(at: currentOffset)
            itemLength = UInt32(length64 & 0xFFFF_FFFF)
            currentOffset += 8
        } else {
            return nil
        }

        // Skip remaining extents
        let extentSize = UInt64(indexSize + offsetSize + lengthSize)
        let remainingExtents = Int(extentCount) - 1
        if remainingExtents > 0 {
            currentOffset += UInt64(remainingExtents) * extentSize
        }

        nextOffset = currentOffset
        return ItemLocation(itemId: itemId, offset: itemOffset, length: itemLength)
    }

    private func parseItemReference(offset: UInt64, size: UInt32) async throws -> [(
        from: UInt32, to: [UInt32]
    )] {
        var references: [(from: UInt32, to: [UInt32])] = []
        var currentOffset = offset + 4  // Skip version/flags

        let version = try await reader.readUInt8(at: offset)
        let idSize = (version == 0) ? 2 : 4

        let endOffset = offset + UInt64(size)

        while currentOffset + 8 < endOffset {
            let refBoxSize = try await reader.readUInt32(at: currentOffset)
            let refBoxType = try await reader.readString(at: currentOffset + 4, length: 4)

            currentOffset += 8

            if refBoxType == "thmb" {
                if let reference = try await parseThumbnailReference(
                    offset: currentOffset,
                    idSize: idSize,
                    nextOffset: &currentOffset
                ) {
                    references.append(reference)
                }
            } else if refBoxSize > 8 {
                currentOffset += UInt64(refBoxSize) - 8
            } else {
                break
            }
        }

        return references
    }

    private func parseThumbnailReference(
        offset: UInt64,
        idSize: Int,
        nextOffset: inout UInt64
    ) async throws -> (from: UInt32, to: [UInt32])? {
        var currentOffset = offset

        // Read from_item_ID
        let fromItemId: UInt32 =
            if idSize == 2 {
                UInt32(try await reader.readUInt16(at: currentOffset))
            } else {
                try await reader.readUInt32(at: currentOffset)
            }
        currentOffset += UInt64(idSize)

        // Read reference count
        let refCount = try await reader.readUInt16(at: currentOffset)
        currentOffset += 2

        // Read to_item_IDs
        var toItemIds: [UInt32] = []
        for _ in 0..<refCount {
            let toItemId: UInt32 =
                if idSize == 2 {
                    UInt32(try await reader.readUInt16(at: currentOffset))
                } else {
                    try await reader.readUInt32(at: currentOffset)
                }
            toItemIds.append(toItemId)
            currentOffset += UInt64(idSize)
        }

        nextOffset = currentOffset
        return (from: fromItemId, to: toItemIds)
    }

    private func parseItemProperties(offset: UInt64, size: UInt32) async throws -> (
        [ItemProperty], [ItemPropertyAssociation]
    ) {
        var properties: [ItemProperty] = []
        var associations: [ItemPropertyAssociation] = []
        var currentOffset = offset

        let endOffset = offset + UInt64(size)

        while currentOffset + 8 < endOffset {
            let boxHeaderOffset = currentOffset
            guard let (boxSize, boxType) = try await parseBoxHeader(offset: currentOffset) else {
                break
            }

            let boxDataOffset = currentOffset + 8
            let boxDataSize = boxSize > 8 ? boxSize - 8 : 0

            switch boxType {
            case "ipco":
                properties = try await parseItemPropertyContainer(
                    offset: boxDataOffset, size: boxDataSize)
            case "ipma":
                associations = try await parseItemPropertyAssociation(
                    offset: boxDataOffset, size: boxDataSize)
            default:
                break
            }

            currentOffset = boxHeaderOffset + UInt64(boxSize)
        }

        return (properties, associations)
    }

    private func parseItemPropertyContainer(offset: UInt64, size: UInt32) async throws
        -> [ItemProperty]
    {
        var properties: [ItemProperty] = []
        var currentOffset = offset
        var propertyIndex: UInt32 = 1

        let endOffset = offset + UInt64(size)

        while currentOffset + 8 < endOffset {
            let boxHeaderOffset = currentOffset
            guard let (boxSize, boxType) = try await parseBoxHeader(offset: currentOffset) else {
                break
            }

            let boxDataOffset = currentOffset + 8
            let boxDataSize = boxSize > 8 ? boxSize - 8 : 0

            let rotation =
                (boxType == "irot")
                ? try await parseIrotBox(offset: boxDataOffset, size: boxDataSize) : nil
            let boxSize2D =
                (boxType == "ispe")
                ? try await parseIspeBox(offset: boxDataOffset, size: boxDataSize) : nil

            // Read raw data for this property box
            let rawData = try await reader.read(at: boxDataOffset, length: boxDataSize)

            let property = ItemProperty(
                propertyIndex: propertyIndex,
                propertyType: boxType,
                rotation: rotation,
                width: boxSize2D?.width,
                height: boxSize2D?.height,
                rawData: rawData
            )
            properties.append(property)

            propertyIndex += 1
            currentOffset = boxHeaderOffset + UInt64(boxSize)
        }

        return properties
    }

    private func parseIrotBox(offset: UInt64, size: UInt32) async throws -> Int? {
        guard size >= 1 else { return nil }
        let data = try await reader.readUInt8(at: offset)
        return Int(data & 0x03) * 90
    }

    private func parseIspeBox(offset: UInt64, size: UInt32) async throws -> (
        width: UInt32, height: UInt32
    )? {
        guard size >= 12 else { return nil }

        let width = try await reader.readUInt32(at: offset + 4)
        let height = try await reader.readUInt32(at: offset + 8)

        return (width: width, height: height)
    }

    private func parseItemPropertyAssociation(offset: UInt64, size: UInt32) async throws
        -> [ItemPropertyAssociation]
    {
        var associations: [ItemPropertyAssociation] = []
        var currentOffset = offset + 4  // Skip version/flags

        guard size >= 8 else { return associations }

        let entryCount = try await reader.readUInt32(at: currentOffset)
        currentOffset += 4

        for _ in 0..<entryCount {
            let itemId = UInt32(try await reader.readUInt16(at: currentOffset))
            currentOffset += 2

            let associationCount = try await reader.readUInt8(at: currentOffset)
            currentOffset += 1

            var propertyIndices: [UInt32] = []
            for _ in 0..<associationCount {
                let propertyIndexData = try await reader.readUInt8(at: currentOffset)
                let propertyIndex = UInt32(propertyIndexData & 0x7F)
                propertyIndices.append(propertyIndex)
                currentOffset += 1
            }

            associations.append(
                ItemPropertyAssociation(itemId: itemId, propertyIndices: propertyIndices))
        }

        return associations
    }

    // MARK: - Thumbnail Building

    private func buildThumbnailInfos(
        items: [ItemInfo],
        locations: [ItemLocation],
        primaryItemId: UInt32,
        thumbnailReferences: [(from: UInt32, to: [UInt32])],
        properties: [ItemProperty],
        propertyAssociations: [ItemPropertyAssociation]
    ) -> [HeifThumbnailEntry] {
        var thumbnailCandidates: [HeifThumbnailEntry] = []

        for (thumbnailId, masterIds) in thumbnailReferences {
            guard masterIds.contains(primaryItemId),
                let item = items.first(where: { $0.itemId == thumbnailId }),
                let location = locations.first(where: { $0.itemId == thumbnailId })
            else {
                continue
            }

            let (rotation, width, height, associatedProperties) = extractItemProperties(
                itemId: thumbnailId,
                properties: properties,
                propertyAssociations: propertyAssociations
            )

            let thumbnail = HeifThumbnailEntry(
                itemId: thumbnailId,
                offset: location.offset,
                size: location.length,
                rotation: rotation,
                width: width ?? 0,
                height: height ?? 0,
                type: item.itemType,
                properties: associatedProperties
            )

            thumbnailCandidates.append(thumbnail)
            logger.debug(
                "Found thumbnail: itemId=\(thumbnailId), type=\(item.itemType), size=\(width ?? 0)x\(height ?? 0)"
            )
        }

        return thumbnailCandidates
    }

    private func extractItemProperties(
        itemId: UInt32,
        properties: [ItemProperty],
        propertyAssociations: [ItemPropertyAssociation]
    ) -> (rotation: Int?, width: UInt32?, height: UInt32?, properties: [ItemProperty]) {
        guard let association = propertyAssociations.first(where: { $0.itemId == itemId }) else {
            return (nil, nil, nil, [])
        }

        var rotation: Int?
        var width: UInt32?
        var height: UInt32?
        var associatedProperties: [ItemProperty] = []

        for propertyIndex in association.propertyIndices {
            guard let property = properties.first(where: { $0.propertyIndex == propertyIndex })
            else {
                continue
            }

            associatedProperties.append(property)

            switch property.propertyType {
            case "irot":
                rotation = property.rotation
            case "ispe":
                width = property.width
                height = property.height
            default:
                break
            }
        }

        return (rotation, width, height, associatedProperties)
    }

    // MARK: - Meta Box Location

    private func readMetaBox() async throws -> (offset: UInt64, size: UInt32)? {
        // Read initial header with prefetch for better performance
        try await reader.prefetch(at: 0, length: 4096)
        let data = try await reader.read(at: 0, length: 4096)
        guard data.count >= 8 else { return nil }

        var offset: UInt64 = 0

        // Validate ftyp box
        guard let (ftypSize, ftypType) = try await parseBoxHeader(offset: offset),
            ftypType == "ftyp"
        else {
            logger.error("Invalid HEIC file: missing ftyp box")
            return nil
        }

        // Verify HEIC brand
        if ftypSize >= 12 {
            let brand = try await reader.readString(at: offset + 8, length: 4)
            guard brand.hasPrefix("hei") else {
                logger.error("Not a HEIC file, brand: \(brand)")
                return nil
            }
            logger.debug("Detected HEIC file, brand: \(brand)")
        }

        offset = UInt64(ftypSize)

        // Search for meta box with optimized reading
        while offset + 8 < 65536 {  // Limit search to reasonable file header size
            // Ensure we have enough data in buffer
            if offset + 8 > data.count {
                try await reader.prefetch(at: offset, length: 8192)
            }

            guard let (boxSize, boxType) = try await parseBoxHeader(offset: offset) else {
                break
            }

            if boxType == "meta" {
                logger.debug("Found meta box: offset=\(offset), size=\(boxSize)")

                // Prefetch the entire meta box for efficient parsing
                try await reader.prefetch(at: offset, length: boxSize)
                return (offset, boxSize)
            }

            if boxSize <= 8 {
                offset += 8
            } else {
                offset += UInt64(boxSize)
            }
        }

        return nil
    }

    // MARK: - Thumbnail Creation

    private func createThumbnail(from info: HeifThumbnailEntry, data: Data) async throws -> Data {
        switch info.type {
        case "jpeg":
            logger.debug("Processing JPEG thumbnail")
            return data

        case "hvc1":
            logger.debug("Processing HEVC thumbnail")
            guard let heicData = try await createHEICFromHEVC(info, hevcData: data) else {
                logger.error("Failed to create HEIC from HEVC")
                throw ImageReaderError.invalidData
            }
            return heicData

        default:
            logger.error("Unsupported thumbnail type: \(info.type)")
            throw ImageReaderError.unsupportedFormat
        }
    }
}

// MARK: - Internal Types

struct HeifThumbnailEntry {
    let itemId: UInt32
    let offset: UInt32
    let size: UInt32
    let rotation: Int?
    let width: UInt32?
    let height: UInt32?
    let type: String
    let properties: [ItemProperty]
}

struct ItemProperty {
    let propertyIndex: UInt32
    let propertyType: String
    let rotation: Int?
    let width: UInt32?
    let height: UInt32?
    let rawData: Data
}

private struct ItemInfo {
    let itemId: UInt32
    let itemType: String
    let itemName: String?
}

private struct ItemLocation {
    let itemId: UInt32
    let offset: UInt32
    let length: UInt32
}

private struct ItemPropertyAssociation {
    let itemId: UInt32
    let propertyIndices: [UInt32]
}
