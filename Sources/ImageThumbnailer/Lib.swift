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
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct Metadata {
    public let width: UInt32
    public let height: UInt32
    public let duration: Double?  // Duration in seconds
    public let location: GPSLocation?

    public init(width: UInt32, height: UInt32, duration: Double? = nil, location: GPSLocation? = nil) {
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
