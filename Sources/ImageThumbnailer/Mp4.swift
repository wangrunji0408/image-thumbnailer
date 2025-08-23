import Foundation
import OSLog

private let logger = Logger(subsystem: "com.wangrunji.ImageThumbnailer", category: "Mp4Reader")

// MARK: - Mp4Reader Implementation

public class Mp4Reader: ImageReader {
    private let reader: Reader
    private var imageInfos: [Mp4ImageInfo]?
    private var metadata: Metadata?

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        reader = Reader(readAt: readAt)
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if imageInfos == nil {
            try await loadMetadata()
        }

        return imageInfos?.map { info in
            // For thumbnail list, we estimate size based on available information
            let estimatedSize: UInt32
            let format: String

            if let embeddedData = info.embeddedData {
                estimatedSize = UInt32(embeddedData.count)
                format = detectImageFormat(data: embeddedData)
            } else if let frameSize = info.frameSize {
                estimatedSize = frameSize * 2  // Estimate HEIC will be roughly 2x HEVC frame size
                format = "heic"
            } else {
                estimatedSize = 0
                format = "unknown"
            }

            return ThumbnailInfo(
                size: estimatedSize,
                format: format,
                width: info.width,
                height: info.height,
                rotation: info.rotation.map { Int($0) }
            )
        } ?? []
    }

    public func getThumbnail(at index: Int) async throws -> Data {
        if imageInfos == nil {
            try await loadMetadata()
        }

        guard let infos = imageInfos, index < infos.count else {
            throw ImageReaderError.indexOutOfBounds
        }

        let info = infos[index]

        // Return embedded thumbnail data directly
        if let embeddedData = info.embeddedData {
            return embeddedData
        }

        // Extract and convert first frame to HEIC
        guard let frameOffset = info.frameOffset,
            let frameSize = info.frameSize,
            let videoTrackInfo = info.videoTrackInfo
        else {
            throw ImageReaderError.invalidData
        }

        // Read frame data
        let frameData = try await reader.read(at: frameOffset, length: frameSize)

        // Convert to HEIC
        guard
            let heicData = try await convertHevcFrameToHeic(
                frameData: frameData, trackInfo: videoTrackInfo)
        else {
            throw ImageReaderError.invalidData
        }

        return heicData
    }

    public func getMetadata() async throws -> Metadata {
        if metadata == nil {
            try await loadMetadata()
        }
        guard let metadata = metadata else {
            logger.error("Metadata not found")
            throw ImageReaderError.invalidData
        }
        return metadata
    }

    private func loadMetadata() async throws {
        // Read file header with prefetch for better performance
        try await reader.prefetch(at: 0, length: 2048)

        // Validate MP4 format
        guard try await validateMp4Format(reader: reader) else {
            logger.error("Invalid MP4 format")
            throw ImageReaderError.invalidData
        }

        // Find moov box
        guard let (moovOffset, moovSize) = try await findMoovBox(reader: reader) else {
            logger.error("Moov box not found")
            throw ImageReaderError.invalidData
        }

        // Prefetch moov box data for efficient parsing
        try await reader.prefetch(at: moovOffset + 8, length: moovSize - 8)

        // Parse everything in one pass to avoid redundant operations
        let parsedInfo = try await parseAllMoovInfo(
            moovOffset: moovOffset + 8, moovSize: moovSize - 8)

        // If no thumbnails found, create placeholder for first frame extraction
        var finalThumbnails = parsedInfo.thumbnails
        if parsedInfo.thumbnails.isEmpty && parsedInfo.videoTrackInfo != nil {
            logger.info("No embedded thumbnails found, preparing first frame extraction info")
            if let firstFrameInfo = try await prepareFirstFrameInfo(
                videoTrackInfo: parsedInfo.videoTrackInfo!)
            {
                finalThumbnails = [firstFrameInfo]
                logger.info("Successfully prepared first frame extraction info")
            }
        }

        imageInfos = finalThumbnails
        if let trackDimensions = parsedInfo.trackDimensions {
            metadata = Metadata(
                width: trackDimensions.width,
                height: trackDimensions.height,
                duration: parsedInfo.duration
            )
        } else {
            throw ImageReaderError.invalidData
        }
    }

    // Consolidated parsing structure to avoid redundant operations
    private struct ParsedMoovInfo {
        let thumbnails: [Mp4ImageInfo]
        let trackDimensions: (width: UInt32, height: UInt32)?
        let duration: Double?
        let videoTrackInfo: VideoTrackInfo?
    }

    private func parseAllMoovInfo(moovOffset: UInt64, moovSize: UInt32) async throws
        -> ParsedMoovInfo
    {
        logger.debug("Parsing moov box, size: \(moovSize)")
        var imageInfos: [Mp4ImageInfo] = []
        var trackDimensions: (width: UInt32, height: UInt32)?
        var rotation: Double?
        var videoTrackInfo: VideoTrackInfo?
        let moovEndOffset = moovOffset + UInt64(moovSize)

        // Parse duration from mvhd box
        let duration = try await parseDuration(moovOffset: moovOffset, moovEndOffset: moovEndOffset)

        // Single pass through all tracks to find video track info and dimensions
        var offset: UInt64 = moovOffset
        var trackIndex = 0

        while offset + 8 <= moovEndOffset {
            let boxSize = try await reader.readUInt32(at: offset)
            let boxType = try await reader.readString(at: offset + 4, length: 4)

            guard boxSize > 8 && offset + UInt64(boxSize) <= moovEndOffset else {
                offset += 8
                continue
            }

            if boxType == "trak" {
                trackIndex += 1
                let trakOffset = offset + 8
                let trakEndOffset = offset + UInt64(boxSize)

                // Parse track info in one pass
                if let trackInfo = try await parseTrackInfoComplete(
                    trakOffset: trakOffset, trakEndOffset: trakEndOffset, trackIndex: trackIndex)
                {
                    // Use first video track for dimensions and rotation
                    if trackDimensions == nil && trackInfo.isVideo {
                        trackDimensions = (trackInfo.width, trackInfo.height)
                        rotation = trackInfo.rotation

                        // Create video track info for first frame extraction if needed
                        if trackInfo.stblOffset != 0, let hevcConfig = trackInfo.hevcConfig {
                            videoTrackInfo = VideoTrackInfo(
                                width: trackInfo.width,
                                height: trackInfo.height,
                                stblOffset: trackInfo.stblOffset,
                                stblSize: trackInfo.stblSize,
                                hevcConfig: hevcConfig,
                                rotation: trackInfo.rotation
                            )
                        }
                    }
                }
            }

            offset += UInt64(boxSize)
        }

        // Parse thumbnails from udta box
        if let udtaBox = try await findBox(offset: moovOffset, length: moovSize, boxType: "udta") {
            logger.debug("Found udta box, size: \(udtaBox.size)")

            if let metaBox = try await findBox(
                offset: udtaBox.offset, length: udtaBox.size, boxType: "meta")
            {
                logger.debug("Found meta box in udta, size: \(metaBox.size)")

                if let ilstBox = try await findBox(
                    offset: metaBox.offset, length: metaBox.size, boxType: "ilst")
                {
                    logger.debug("Found ilst box in udta/meta, size: \(ilstBox.size)")
                    let ilstThumbnails = try await parseIlstBox(
                        ilstOffset: ilstBox.offset, ilstSize: ilstBox.size, rotation: rotation)
                    imageInfos.append(contentsOf: ilstThumbnails)
                }
            } else {
                logger.debug("No meta box found in udta, searching for thumbnails directly")
                let udtaThumbnails = try await parseUdtaForThumbnails(
                    udtaOffset: udtaBox.offset, udtaSize: udtaBox.size, rotation: rotation)
                imageInfos.append(contentsOf: udtaThumbnails)
            }
        }

        return ParsedMoovInfo(
            thumbnails: imageInfos,
            trackDimensions: trackDimensions,
            duration: duration,
            videoTrackInfo: videoTrackInfo
        )
    }

    // Comprehensive track information structure
    private struct TrackInfoComplete {
        let width: UInt32
        let height: UInt32
        let rotation: Double?
        let isVideo: Bool
        let stblOffset: UInt64
        let stblSize: UInt32
        let hevcConfig: Data?
    }

    // Parse all track information in a single pass
    private func parseTrackInfoComplete(trakOffset: UInt64, trakEndOffset: UInt64, trackIndex: Int)
        async throws -> TrackInfoComplete?
    {
        // Get basic boxes we need
        guard
            let tkhdBox = try await findBox(
                offset: trakOffset, length: UInt32(trakEndOffset - trakOffset), boxType: "tkhd"),
            let mdiaBox = try await findBox(
                offset: trakOffset, length: UInt32(trakEndOffset - trakOffset), boxType: "mdia"),
            tkhdBox.size >= 84
        else {
            return nil
        }

        guard
            let hdlrBox = try await findBox(
                offset: mdiaBox.offset, length: mdiaBox.size, boxType: "hdlr"),
            hdlrBox.size >= 16
        else {
            return nil
        }

        // Check if this is a video track
        let handlerType = try await reader.readString(at: hdlrBox.offset + 8, length: 4)
        let isVideo = handlerType == "vide"

        if isVideo {
            logger.debug("Track \(trackIndex) is a video track, checking for rotation")
        }

        // Parse dimensions from tkhd
        let width = try await reader.readUInt32(at: tkhdBox.offset + 76) >> 16
        let height = try await reader.readUInt32(at: tkhdBox.offset + 80) >> 16

        // Parse rotation if this is a video track
        var rotation: Double?
        if isVideo {
            rotation = try await parseRotationFromTkhdData(
                tkhdOffset: tkhdBox.offset, tkhdSize: tkhdBox.size, trackIndex: trackIndex)
            if let rotation = rotation {
                logger.debug("Found rotation \(rotation)° in track \(trackIndex)")
            }
        }

        // Get sample table offset and size if this is a video track
        var stblOffset: UInt64 = 0
        var stblSize: UInt32 = 0
        var hevcConfig: Data?

        if isVideo {
            if let minfBox = try await findBox(
                offset: mdiaBox.offset, length: mdiaBox.size, boxType: "minf")
            {
                if let stblBox = try await findBox(
                    offset: minfBox.offset, length: minfBox.size, boxType: "stbl")
                {
                    stblOffset = stblBox.offset
                    stblSize = stblBox.size
                    hevcConfig = try await extractHevcConfig(
                        stblOffset: stblOffset, stblSize: stblSize)
                    if let config = hevcConfig {
                        logger.debug("Using extracted HEVC config, size: \(config.count)")
                    }
                }
            }
        }

        return TrackInfoComplete(
            width: width,
            height: height,
            rotation: rotation,
            isVideo: isVideo,
            stblOffset: stblOffset,
            stblSize: stblSize,
            hevcConfig: hevcConfig
        )
    }

    // Simplified rotation parsing from tkhd data
    private func parseRotationFromTkhdData(tkhdOffset: UInt64, tkhdSize: UInt32, trackIndex: Int)
        async throws -> Double?
    {
        guard tkhdSize >= 76 else {
            logger.debug("Track \(trackIndex) tkhd box too small for matrix: \(tkhdSize)")
            return nil
        }

        // Check version to determine matrix offset
        let version = try await reader.readUInt8(at: tkhdOffset)
        let matrixOffset: UInt64 = version == 0 ? 40 : 52

        guard tkhdSize >= matrixOffset + 36 else {
            logger.debug(
                "Track \(trackIndex) tkhd box too small for matrix at offset \(matrixOffset): \(tkhdSize)"
            )
            return nil
        }

        // Extract matrix elements a and b for rotation calculation
        let a = Double(try await reader.readInt32(at: tkhdOffset + matrixOffset)) / 65536.0
        let b = Double(try await reader.readInt32(at: tkhdOffset + matrixOffset + 4)) / 65536.0

        guard a != 0 || b != 0 else {
            logger.debug("Track \(trackIndex) matrix elements a and b are both zero")
            return nil
        }

        let angleRadians = atan2(b, a)
        var angleDegrees = angleRadians * 180.0 / Double.pi

        // Normalize to 0-360 range
        if angleDegrees < 0 {
            angleDegrees += 360
        }

        // Round to nearest common rotation angle (0, 90, 180, 270)
        let commonRotations = [0.0, 90.0, 180.0, 270.0]
        let roundedAngle =
            commonRotations.min(by: { abs($0 - angleDegrees) < abs($1 - angleDegrees) })
            ?? round(angleDegrees)

        logger.debug(
            "Track \(trackIndex) calculated rotation: \(angleDegrees)° (rounded: \(roundedAngle)°)")
        return roundedAngle
    }

    /// Parse video duration from mvhd box in moov
    private func parseDuration(moovOffset: UInt64, moovEndOffset: UInt64) async throws -> Double? {
        // Look for mvhd box
        guard
            let mvhdBox = try await findBox(
                offset: moovOffset, length: UInt32(moovEndOffset - moovOffset), boxType: "mvhd")
        else {
            return nil
        }

        // mvhd box structure:
        // version(1) + flags(3) + creation_time(4) + modification_time(4) +
        // timescale(4) + duration(4) + ...
        guard mvhdBox.size >= 20 else { return nil }

        // Get timescale (sample rate)
        let timescale = try await reader.readUInt32(at: mvhdBox.offset + 12)

        // Get duration in timescale units
        let durationInTimescale = try await reader.readUInt32(at: mvhdBox.offset + 16)

        // Convert to seconds
        return Double(durationInTimescale) / Double(timescale)
    }

    /// Prepare first frame info without reading actual data
    private func prepareFirstFrameInfo(videoTrackInfo: VideoTrackInfo) async throws -> Mp4ImageInfo?
    {
        logger.debug("Preparing first frame extraction info")

        // Find the media data offset for the first frame
        guard let firstFrameOffset = try await findFirstFrameOffset(trackInfo: videoTrackInfo)
        else {
            logger.error("Could not locate first frame")
            return nil
        }

        // Get the first frame size without reading the data
        guard let frameSize = try await getFirstFrameSize(trackInfo: videoTrackInfo)
        else {
            logger.error("Could not get first frame size")
            return nil
        }

        logger.debug("Prepared first frame info: offset=\(firstFrameOffset), size=\(frameSize)")

        return Mp4ImageInfo(
            width: videoTrackInfo.width,
            height: videoTrackInfo.height,
            rotation: videoTrackInfo.rotation,
            embeddedData: nil,
            frameOffset: firstFrameOffset,
            frameSize: frameSize,
            videoTrackInfo: videoTrackInfo
        )
    }

    /// Find the offset of the first video frame
    private func findFirstFrameOffset(trackInfo: VideoTrackInfo) async throws -> UInt64? {
        // Look for stco (chunk offset) or co64 (64-bit chunk offset)
        var chunkOffset: UInt64?

        if let stcoBox = try await findBox(
            offset: trackInfo.stblOffset, length: trackInfo.stblSize, boxType: "stco"),
            stcoBox.size >= 8
        {
            // 32-bit chunk offsets
            let entryCount = try await reader.readUInt32(at: stcoBox.offset + 4)
            if entryCount > 0 && stcoBox.size >= 12 {
                let firstChunkOffset32 = try await reader.readUInt32(at: stcoBox.offset + 8)
                chunkOffset = UInt64(firstChunkOffset32)
            }
        } else if let co64Box = try await findBox(
            offset: trackInfo.stblOffset, length: trackInfo.stblSize, boxType: "co64"),
            co64Box.size >= 8
        {
            // 64-bit chunk offsets
            let entryCount = try await reader.readUInt32(at: co64Box.offset + 4)
            if entryCount > 0 && co64Box.size >= 16 {
                chunkOffset = try await reader.readUInt64(at: co64Box.offset + 8)
            }
        }

        return chunkOffset
    }

    /// Get the first frame size without reading data
    private func getFirstFrameSize(trackInfo: VideoTrackInfo) async throws -> UInt32? {
        // Look for sample size information in stsz box
        guard
            let stszBox = try await findBox(
                offset: trackInfo.stblOffset, length: trackInfo.stblSize, boxType: "stsz"),
            stszBox.size >= 12
        else {
            logger.error("Sample size table not found")
            return nil
        }

        let sampleSize = try await reader.readUInt32(at: stszBox.offset + 4)

        let frameSize: UInt32
        if sampleSize != 0 {
            // Fixed sample size
            frameSize = sampleSize
        } else {
            // Variable sample sizes - read first entry
            let sampleCount = try await reader.readUInt32(at: stszBox.offset + 8)
            guard sampleCount > 0 && stszBox.size >= 16 else {
                logger.error("No samples found")
                return nil
            }
            frameSize = try await reader.readUInt32(at: stszBox.offset + 12)
        }

        logger.debug("First frame size: \(frameSize)")
        return frameSize
    }

    /// Convert HEVC frame data to HEIC format
    private func convertHevcFrameToHeic(frameData: Data, trackInfo: VideoTrackInfo) async throws
        -> Data?
    {
        logger.debug("Converting HEVC frame to HEIC, frame size: \(frameData.count)")

        // For HEIC format, we need to use the original length-prefixed format
        // but ensure parameter sets are included in the HEVC configuration
        let hevcData = frameData

        logger.debug("Using original HEVC frame data for HEIC, size: \(hevcData.count)")

        // Create a basic HEIC container for the HEVC frame
        let thumbnail = HeifThumbnailEntry(
            itemId: 1,
            offset: 0,
            size: UInt32(hevcData.count),
            rotation: trackInfo.rotation.map { Int($0) },
            width: trackInfo.width,
            height: trackInfo.height,
            type: "hvc1",
            properties: createBasicHevcProperties(
                width: trackInfo.width, height: trackInfo.height, hevcConfig: trackInfo.hevcConfig,
                rotation: trackInfo.rotation)
        )

        logger.debug("Creating HEIC container for \(trackInfo.width)x\(trackInfo.height) image")
        let heicData = try await createHEICFromHEVC(thumbnail, hevcData: hevcData)

        if let heicData = heicData {
            logger.debug("Successfully created HEIC data, size: \(heicData.count)")
        } else {
            logger.error("Failed to create HEIC data")
        }

        return heicData
    }

    /// Extract HEVC configuration from sample description table
    private func extractHevcConfig(stblOffset: UInt64, stblSize: UInt32) async throws -> Data? {
        // Look for sample description (stsd) box
        guard
            let stsdBox = try await findBox(offset: stblOffset, length: stblSize, boxType: "stsd"),
            stsdBox.size >= 16
        else {
            logger.error("Could not find stsd box or box too small")
            return nil
        }

        logger.debug("stsd box data size: \(stsdBox.size)")

        // Parse stsd box: version(1) + flags(3) + entry_count(4) + entries...
        guard stsdBox.size >= 8 else {
            logger.error("stsd box too small for header")
            return nil
        }

        let entryCount = try await reader.readUInt32(at: stsdBox.offset + 4)
        logger.debug("Sample description entry count: \(entryCount)")

        guard entryCount > 0 else {
            logger.error("No sample entries found")
            return nil
        }

        // Start parsing from offset 8 (after stsd header)
        let entryOffset = stsdBox.offset + 8
        let stsdEndOffset = stsdBox.offset + UInt64(stsdBox.size)
        guard entryOffset + 8 <= stsdEndOffset else {
            logger.error("stsd data too small for sample entry")
            return nil
        }

        // Read first sample entry size
        let entrySize = try await reader.readUInt32(at: entryOffset)

        // Read codec type (format)
        let codecType = try await reader.readString(at: entryOffset + 4, length: 4)
        logger.debug("Found codec type: '\(codecType)', entry size: \(entrySize)")

        guard codecType == "hvc1" || codecType == "hev1" else {
            logger.error("Not an HEVC codec: '\(codecType)'")
            return nil
        }

        // For HEVC sample entry, the structure is:
        // size(4) + type(4) + reserved(6) + data_reference_index(2) + pre_defined(2) + reserved(2) +
        // pre_defined(12) + width(2) + height(2) + ... + compressorname(32) + depth(2) + pre_defined(2) +
        // then extension boxes including hvcC

        // The hvcC box should be after the standard video sample entry fields
        // Standard video sample entry is 78 bytes, then comes extension boxes
        let videoSampleEntrySize: UInt64 = 78
        let extensionOffset = entryOffset + videoSampleEntrySize
        let sampleEntryEndOffset = entryOffset + UInt64(entrySize)

        guard extensionOffset < sampleEntryEndOffset else {
            logger.error("Sample entry too small for video sample entry + extensions")
            return nil
        }

        // Look for hvcC in the extension area
        logger.debug(
            "Searching for hvcC in extension data, range: \(extensionOffset)-\(sampleEntryEndOffset)"
        )

        if let hvcCBox = try await findBox(
            offset: extensionOffset, length: UInt32(sampleEntryEndOffset - extensionOffset),
            boxType: "hvcC")
        {
            logger.debug("Found hvcC configuration, size: \(hvcCBox.size)")
            let hvcCData = try await reader.read(at: hvcCBox.offset, length: hvcCBox.size)
            return hvcCData
        } else {
            logger.error("hvcC configuration not found in sample entry")
            return nil
        }
    }

    /// Create HEVC properties for HEIC container
    private func createBasicHevcProperties(
        width: UInt32, height: UInt32, hevcConfig: Data?, rotation: Double?
    )
        -> [ItemProperty]
    {
        var properties: [ItemProperty] = []
        var propertyIndex: UInt32 = 1

        // Image spatial extents property (ispe)
        var ispeData = Data()
        ispeData.append(0)  // version = 0
        ispeData.append(0)  // flags[0]
        ispeData.append(0)  // flags[1]
        ispeData.append(0)  // flags[2]
        ispeData.append(contentsOf: withUnsafeBytes(of: width.bigEndian) { Data($0) })
        ispeData.append(contentsOf: withUnsafeBytes(of: height.bigEndian) { Data($0) })
        properties.append(
            ItemProperty(
                propertyIndex: propertyIndex,
                propertyType: "ispe",
                rotation: nil,
                width: width,
                height: height,
                rawData: ispeData
            ))
        propertyIndex += 1

        // HEVC configuration property (hvcC)
        let hvcCData: Data
        if let hevcConfig = hevcConfig, hevcConfig.count > 0 {
            // Use extracted HEVC configuration
            logger.debug("Using extracted HEVC config, size: \(hevcConfig.count)")
            hvcCData = hevcConfig
        } else {
            // Fallback to minimal HEVC configuration
            logger.warning("No HEVC config found, using fallback configuration")
            hvcCData = Data([
                0x01,  // configuration version
                0x01,  // general_profile_space, general_tier_flag, general_profile_idc
                0x40, 0x00, 0x00, 0x00,  // general_profile_compatibility_flags
                0x90, 0x00, 0x00, 0x00, 0x00, 0x00,  // general_constraint_indicator_flags
                0x5d,  // general_level_idc
                0xf0, 0x00,  // min_spatial_segmentation_idc
                0xfc,  // parallelismType
                0xfd,  // chromaFormat
                0xf8,  // bitDepthLumaMinus8
                0xf8,  // bitDepthChromaMinus8
                0x00, 0x00,  // avgFrameRate
                0x0f,  // constantFrameRate, numTemporalLayers, temporalIdNested, lengthSizeMinusOne
                0x00,  // numOfArrays (no parameter sets)
            ])
        }

        properties.append(
            ItemProperty(
                propertyIndex: propertyIndex,
                propertyType: "hvcC",
                rotation: nil,
                width: nil,
                height: nil,
                rawData: hvcCData
            ))
        propertyIndex += 1

        // Add rotation property (irot) if rotation is specified
        if let rotation = rotation, rotation != 0.0 {
            logger.debug("Adding rotation property: \(rotation)°")

            // Convert rotation angle to HEIF irot format
            // HEIF irot property format: 1 byte with rotation in 90-degree increments
            // 0 = 0°, 1 = 90° CCW, 2 = 180°, 3 = 270° CCW (90° CW)
            // QuickTime rotation is clockwise, HEIF irot is counter-clockwise
            // So we need to convert: CW 90° -> CCW 270° (irot=3), CW 270° -> CCW 90° (irot=1)
            let normalizedRotation = Int(rotation) % 360
            let irotValue: UInt8
            switch normalizedRotation {
            case 90:
                irotValue = 3  // CW 90° -> CCW 270°
            case 180:
                irotValue = 2  // 180° is same in both directions
            case 270:
                irotValue = 1  // CW 270° -> CCW 90°
            default:
                irotValue = 0  // 0° or unsupported angle
            }

            var irotData = Data()
            irotData.append(irotValue)

            properties.append(
                ItemProperty(
                    propertyIndex: propertyIndex,
                    propertyType: "irot",
                    rotation: Int(rotation),
                    width: nil,
                    height: nil,
                    rawData: irotData
                ))
            propertyIndex += 1
        }

        return properties
    }

    // Find box within a range using class reader
    private func findBox(offset: UInt64, length: UInt32, boxType: String) async throws -> BoxInfo? {
        let endOffset = offset + UInt64(length)
        logger.debug(
            "Searching for box type '\(boxType, privacy: .public)' in range \(offset)-\(endOffset)")
        var currentOffset: UInt64 = offset
        var boxCount = 0

        while currentOffset + 8 <= endOffset {
            let boxSize = try await reader.readUInt32(at: currentOffset)
            let foundType = try await reader.readString(at: currentOffset + 4, length: 4)

            boxCount += 1
            if boxCount <= 20 {
                logger.debug(
                    "Box #\(boxCount): type='\(foundType, privacy: .public)', size=\(boxSize), offset=\(currentOffset)"
                )
            }

            if foundType == boxType {
                let dataOffset = currentOffset + 8
                var dataSize = UInt64(boxSize) - 8

                guard dataOffset + dataSize <= endOffset else {
                    logger.debug("Box '\(boxType)' found but data size invalid")
                    return nil
                }

                // For meta box, skip 4 bytes of version/flags
                var actualDataOffset = dataOffset
                if boxType == "meta", dataSize >= 4 {
                    actualDataOffset += 4
                    dataSize -= 4
                    logger.debug("Skipping 4 bytes version/flags in meta box")
                }

                logger.debug("Found box '\(boxType, privacy: .public)' with data size \(dataSize)")
                return BoxInfo(offset: actualDataOffset, size: UInt32(dataSize))
            }

            if boxSize <= 8 {
                currentOffset += 8
            } else {
                currentOffset += UInt64(boxSize)
            }

            if currentOffset >= endOffset {
                break
            }
        }

        logger.debug("Box '\(boxType)' not found after checking \(boxCount) boxes")
        return nil
    }

    private func parseIlstBox(ilstOffset: UInt64, ilstSize: UInt32, rotation: Double?) async throws
        -> [Mp4ImageInfo]
    {
        logger.debug("Parsing ilst box, size: \(ilstSize)")
        var imageInfos: [Mp4ImageInfo] = []
        var offset: UInt64 = ilstOffset
        var itemCount = 0
        let ilstEndOffset = ilstOffset + UInt64(ilstSize)

        while offset + 8 <= ilstEndOffset {
            let itemSize = try await reader.readUInt32(at: offset)

            guard itemSize > 8, offset + UInt64(itemSize) <= ilstEndOffset else {
                offset += 8
                continue
            }

            let itemName = try await reader.readString(at: offset + 4, length: 4)
            let itemDataOffset = offset + 8
            let itemDataSize = itemSize - 8

            itemCount += 1
            if itemCount <= 10 {  // 只显示前10个item
                logger.debug(
                    "Item #\(itemCount): name='\(itemName, privacy: .public)', size=\(itemSize), offset=\(offset)"
                )
            }

            if itemName == "covr" {
                // Cover Art
                logger.debug("Processing Cover Art item")
                if let imageData = try await extractImageFromItem(
                    itemOffset: itemDataOffset, itemSize: itemDataSize, rotation: rotation)
                {
                    imageInfos.append(imageData)
                    logger.debug(
                        "Added Cover Art: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
                }
            } else if itemName == "snal" {
                // PreviewImage
                logger.debug("Processing PreviewImage item")
                if let imageData = try await extractImageFromItem(
                    itemOffset: itemDataOffset, itemSize: itemDataSize, rotation: rotation)
                {
                    imageInfos.append(imageData)
                    logger.debug(
                        "Added PreviewImage: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
                }
            } else if itemName == "tnal" {
                // ThumbnailImage
                logger.debug("Processing ThumbnailImage item")
                if let imageData = try await extractImageFromItem(
                    itemOffset: itemDataOffset, itemSize: itemDataSize, rotation: rotation)
                {
                    imageInfos.append(imageData)
                    logger.debug(
                        "Added ThumbnailImage: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
                }
            }

            offset += UInt64(itemSize)
        }

        return imageInfos
    }

    private func extractImageFromItem(itemOffset: UInt64, itemSize: UInt32, rotation: Double?)
        async throws -> Mp4ImageInfo?
    {
        logger.debug("extractImageFromItem: size=\(itemSize)")
        var offset: UInt64 = itemOffset
        let itemEndOffset = itemOffset + UInt64(itemSize)

        while offset + 8 <= itemEndOffset {
            let boxSize = try await reader.readUInt32(at: offset)
            let boxType = try await reader.readString(at: offset + 4, length: 4)

            if boxType == "data", boxSize > 16 {
                // data box contains the actual image
                let imageDataOffset = offset + 16
                let imageDataSize = boxSize - 16
                let imageData = try await reader.read(at: imageDataOffset, length: imageDataSize)
                if isJpegData(imageData) {
                    let (width, height) = extractJpegDimensions(data: imageData)
                    return Mp4ImageInfo(
                        width: width,
                        height: height,
                        rotation: rotation,
                        embeddedData: imageData,
                        frameOffset: nil,
                        frameSize: nil,
                        videoTrackInfo: nil
                    )
                }
            }

            if boxSize <= 8 {
                offset += 8
            } else {
                offset += UInt64(boxSize)
            }
        }

        return nil
    }

    private func parseUdtaForThumbnails(udtaOffset: UInt64, udtaSize: UInt32, rotation: Double?)
        async throws -> [Mp4ImageInfo]
    {
        logger.debug("Parsing udta box for thumbnails, size: \(udtaSize)")
        var imageInfos: [Mp4ImageInfo] = []
        var offset: UInt64 = udtaOffset
        var boxCount = 0
        let udtaEndOffset = udtaOffset + UInt64(udtaSize)

        while offset + 8 <= udtaEndOffset {
            let boxSize = try await reader.readUInt32(at: offset)
            let boxType = try await reader.readString(at: offset + 4, length: 4)

            boxCount += 1
            logger.debug(
                "Box #\(boxCount): type='\(boxType, privacy: .public)', size=\(boxSize), offset=\(offset)"
            )

            // 检查是否是缩略图相关的box
            if boxType == "thmb" {
                let boxDataOffset = offset + 8
                let boxDataSize = boxSize - 8
                if let thumbnailData = try await extractThumbnailFromBox(
                    boxOffset: boxDataOffset, boxSize: boxDataSize, rotation: rotation)
                {
                    imageInfos.append(thumbnailData)
                    logger.debug(
                        "Added thumbnail from \(boxType): \(thumbnailData.width ?? 0)x\(thumbnailData.height ?? 0)"
                    )
                }
            }

            if boxSize <= 8 {
                offset += 8
            } else {
                offset += UInt64(boxSize)
            }

            if offset >= udtaEndOffset {
                break
            }
        }

        return imageInfos
    }

    private func extractThumbnailFromBox(boxOffset: UInt64, boxSize: UInt32, rotation: Double?)
        async throws -> Mp4ImageInfo?
    {
        logger.debug("Extracting thumbnail from box, size: \(boxSize)")

        // Read the box data to search for JPEG markers
        let boxData = try await reader.read(at: boxOffset, length: boxSize)

        // 查找JPEG开始标记
        for i in 0..<boxData.count - 1 {
            if boxData[i] == 0xFF && boxData[i + 1] == 0xD8 {
                logger.debug("Found JPEG start marker at offset \(i)")
                let jpegData = boxData.subdata(in: i..<boxData.count)

                // 查找JPEG结束标记
                for j in stride(from: jpegData.count - 1, to: 0, by: -1) {
                    if jpegData[j - 1] == 0xFF && jpegData[j] == 0xD9 {
                        let finalJpegData = jpegData.subdata(in: 0..<j + 1)
                        logger.debug("Found complete JPEG data, size: \(finalJpegData.count)")
                        let (width, height) = extractJpegDimensions(data: finalJpegData)
                        return Mp4ImageInfo(
                            width: width,
                            height: height,
                            rotation: rotation,
                            embeddedData: finalJpegData,
                            frameOffset: nil,
                            frameSize: nil,
                            videoTrackInfo: nil
                        )
                    }
                }

                // 如果没有找到结束标记，使用剩余数据
                logger.debug("No JPEG end marker found, using remaining data")
                let (width, height) = extractJpegDimensions(data: jpegData)
                return Mp4ImageInfo(
                    width: width,
                    height: height,
                    rotation: rotation,
                    embeddedData: jpegData,
                    frameOffset: nil,
                    frameSize: nil,
                    videoTrackInfo: nil
                )
            }
        }

        return nil
    }
}

// MARK: - MP4 Data Structures

private struct Mp4ImageInfo {
    let width: UInt32?
    let height: UInt32?
    let rotation: Double?
    // For embedded thumbnails
    let embeddedData: Data?
    // For first frame extraction
    let frameOffset: UInt64?
    let frameSize: UInt32?
    let videoTrackInfo: VideoTrackInfo?
}

private struct VideoTrackInfo {
    let width: UInt32
    let height: UInt32
    let stblOffset: UInt64
    let stblSize: UInt32
    let hevcConfig: Data?
    let rotation: Double?
}

// MARK: - Private Implementation

private func validateMp4Format(reader: Reader) async throws -> Bool {
    let size = try await reader.readUInt32(at: 0)
    let type = try await reader.readString(at: 4, length: 4)
    return size >= 8 && type == "ftyp"
}

private func findMoovBox(reader: Reader) async throws -> (UInt64, UInt32)? {
    var offset: UInt64 = 0

    while true {
        try await reader.prefetch(at: offset, length: 16)
        // Ensure we have header data
        let boxSize32 = try await reader.readUInt32(at: offset)
        let boxType = try await reader.readString(at: offset + 4, length: 4)

        let actualBoxSize: UInt64
        if boxSize32 == 1 {
            // 64-bit box size follows
            actualBoxSize = try await reader.readUInt64(at: offset + 8)
        } else {
            actualBoxSize = UInt64(boxSize32)
        }

        if boxType == "moov" {
            return (offset, UInt32(actualBoxSize))
        }

        offset += actualBoxSize
    }
}

private struct BoxInfo {
    let offset: UInt64
    let size: UInt32
}

// MARK: - Utility Functions

private func isJpegData(_ data: Data) -> Bool {
    return data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
}

private func extractJpegDimensions(data: Data) -> (width: UInt32?, height: UInt32?) {
    guard data.count >= 10 else { return (nil, nil) }

    var offset = 2  // Skip JPEG SOI marker (FF D8)

    while offset + 4 < data.count {
        guard data[offset] == 0xFF else { break }

        let marker = data[offset + 1]
        offset += 2

        // Skip padding
        while offset < data.count && data[offset] == 0xFF {
            offset += 1
        }

        if marker == 0xC0 || marker == 0xC2 {  // SOF0 or SOF2
            guard offset + 6 < data.count else { break }

            let length = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            guard length >= 8, offset + Int(length) <= data.count else { break }

            let height = UInt32(data[offset + 3]) << 8 | UInt32(data[offset + 4])
            let width = UInt32(data[offset + 5]) << 8 | UInt32(data[offset + 6])

            return (width, height)
        } else {
            // Skip this segment
            guard offset + 2 <= data.count else { break }
            let length = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            offset += Int(length)
        }
    }

    return (nil, nil)
}

/// Detect image format based on data header
private func detectImageFormat(data: Data) -> String {
    guard data.count >= 8 else { return "unknown" }

    // Check for JPEG
    if data[0] == 0xFF && data[1] == 0xD8 {
        return "jpeg"
    }

    // Check for HEIC/HEIF
    if data.count >= 12 {
        let ftyp = String(data: data.subdata(in: 4..<8), encoding: .ascii) ?? ""
        if ftyp == "ftyp" {
            let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
            if brand == "heic" || brand == "heix" || brand == "heif" {
                return "heic"
            }
        }
    }

    return "unknown"
}
