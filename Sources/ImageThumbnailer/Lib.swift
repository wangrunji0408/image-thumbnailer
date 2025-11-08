import Foundation

public protocol ImageReader {
    init(readAt: @escaping (UInt64, UInt32) async throws -> Data)
    func getThumbnailList() async throws -> [ThumbnailInfo]
    func getThumbnail(at index: Int) async throws -> Data
    func getMetadata() async throws -> Metadata
}

public struct ThumbnailInfo {
    public let size: UInt32
    public let format: String
    public let width: UInt32?
    public let height: UInt32?
    public let rotation: Int?
}

public struct GPSLocation {
    public let latitude: Float
    public let longitude: Float
    public let altitude: Float

    public init(latitude: Float, longitude: Float, altitude: Float) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct Metadata {
    public let width: UInt32
    public let height: UInt32
    public let duration: Float?  // Duration in seconds
    public let location: GPSLocation?

    public init(
        width: UInt32, height: UInt32, duration: Float? = nil, location: GPSLocation? = nil
    ) {
        self.width = width
        self.height = height
        self.duration = duration
        self.location = location
    }
}

public enum ImageReaderError: Error {
    case indexOutOfBounds
    case invalidData
    case unsupportedFormat
}
