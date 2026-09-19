import Foundation

/// Fujifilm RAF container reader. Extracts camera-rendered JPEGs without decoding the sensor data.
public final class RafReader: ImageReader {
    private let reader: Reader
    private let readAt: (UInt64, UInt32) async throws -> Data
    private var jpegReader: JpegReader?
    private var previewOffset: UInt64 = 0
    private var previewLength: UInt32 = 0
    private var thumbnails: [ThumbnailInfo]?
    private var metadata: Metadata?

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        self.readAt = readAt
        reader = Reader(readAt: readAt)
    }

    public func getMetadata() async throws -> Metadata {
        try await loadMetadata()
        guard let metadata else { throw ImageReaderError.invalidData }
        return metadata
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        try await loadMetadata()
        return thumbnails ?? []
    }

    public func getThumbnail(at index: Int) async throws -> Data {
        try await loadMetadata()
        guard let thumbnails, thumbnails.indices.contains(index), let jpegReader else {
            throw ImageReaderError.indexOutOfBounds
        }
        // The full embedded JPEG follows its smaller EXIF/MPF thumbnails.
        if index == thumbnails.count - 1 {
            return try await reader.read(at: previewOffset, length: previewLength)
        }
        return try await jpegReader.getThumbnail(at: index)
    }

    private func loadMetadata() async throws {
        guard metadata == nil else { return }
        guard try await reader.readString(at: 0, length: 16) == "FUJIFILMCCD-RAW " else {
            throw ImageReaderError.invalidData
        }

        // RAF's container fields and tag directory are always big endian.
        let offset = UInt64(try await reader.readUInt32(at: 84))
        let length = try await reader.readUInt32(at: 88)
        guard offset >= 108, length >= 4 else { throw ImageReaderError.invalidData }

        // Keep every nested JPEG read inside the declared preview, including prefetches.
        let source = readAt
        let jpeg = JpegReader { relativeOffset, requestedLength in
            guard relativeOffset < UInt64(length) else { throw ImageReaderError.invalidData }
            let available = UInt32(UInt64(length) - relativeOffset)
            return try await source(offset + relativeOffset, min(requestedLength, available))
        }
        let previewMetadata = try await jpeg.getMetadata()
        guard previewMetadata.width > 0, previewMetadata.height > 0 else {
            throw ImageReaderError.invalidData
        }
        var entries = try await jpeg.getThumbnailList()
        let rotation = try await jpeg.getImageRotation()
        entries.append(ThumbnailInfo(
            size: length, format: "jpeg",
            width: previewMetadata.width, height: previewMetadata.height, rotation: rotation
        ))

        let dimensions = try await rawDimensions()
        previewOffset = offset
        previewLength = length
        jpegReader = jpeg
        thumbnails = entries
        metadata = Metadata(
            width: dimensions?.width ?? previewMetadata.width,
            height: dimensions?.height ?? previewMetadata.height,
            location: previewMetadata.location,
            captureTime: previewMetadata.captureTime, camera: previewMetadata.camera
        )
    }

    private func rawDimensions() async throws -> (width: UInt32, height: UInt32)? {
        let offset = UInt64(try await reader.readUInt32(at: 92))
        let length = UInt64(try await reader.readUInt32(at: 96))
        if offset == 0, length == 0 { return nil }
        guard offset >= 108, length >= 4 else { throw ImageReaderError.invalidData }
        let end = offset + length
        let count = try await reader.readUInt32(at: offset)
        guard UInt64(count) <= (length - 4) / 4 else { throw ImageReaderError.invalidData }
        var position = offset + 4
        var fullSize: (width: UInt32, height: UInt32)?
        var croppedSize: (width: UInt32, height: UInt32)?
        var isSuperCCD = false
        for _ in 0..<count {
            guard position + 4 <= end else { throw ImageReaderError.invalidData }
            let tag = try await reader.readUInt16(at: position)
            let valueLength = UInt64(try await reader.readUInt16(at: position + 2))
            position += 4
            guard valueLength <= end - position else { throw ImageReaderError.invalidData }
            if tag == 0x0130, valueLength >= 2 {
                isSuperCCD = try await reader.readUInt8(at: position + 1) & 8 == 0
            }
            if tag == 0x0100 || tag == 0x0111 {
                guard valueLength == 4 else { throw ImageReaderError.invalidData }
                let height = UInt32(try await reader.readUInt16(at: position))
                let width = UInt32(try await reader.readUInt16(at: position + 2))
                if width > 0, height > 0 {
                    if tag == 0x0111 { croppedSize = (width, height) }
                    else { fullSize = (width, height) }
                }
            }
            position += valueLength
        }
        // The crop excludes sensor borders; JPEG SOF dimensions describe only the preview.
        // SuperCCD's diagonal sensor grid is not a rendered image rectangle.
        // Use the camera-rendered JPEG dimensions for those older cameras.
        return isSuperCCD ? nil : (croppedSize ?? fullSize)
    }
}
