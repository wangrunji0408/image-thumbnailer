import Foundation

public protocol ImageReader {
    init(readAt: @escaping (UInt64, UInt32) async throws -> Data)
    func getThumbnailList() async throws -> [ThumbnailInfo]
    func getThumbnail(at index: Int) async throws -> Data
    func getMetadata() async throws -> Metadata
}

public struct ThumbnailInfo: Sendable, Codable {
    public let size: UInt32
    public let format: String
    public let width: UInt32?
    public let height: UInt32?
    // Rotation in degrees (0, 90, 180, 270) that should be applied to display the image correctly
    public let rotation: Int?
}

public struct GPSLocation: Sendable, Codable {
    public let latitude: Float
    public let longitude: Float
    public let altitude: Float

    public init(latitude: Float, longitude: Float, altitude: Float) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct Metadata: Sendable, Codable {
    public let width: UInt32
    public let height: UInt32
    public let duration: Float?  // Duration in seconds
    public let location: GPSLocation?
    public let captureTime: CaptureTime?
    public let camera: CameraMetadata?
    /// QuickTime container creation timestamp (1904 epoch), not necessarily capture time.
    public let creationTime: Date?

    public init(
        width: UInt32, height: UInt32, duration: Float? = nil, location: GPSLocation? = nil,
        captureTime: CaptureTime? = nil, camera: CameraMetadata? = nil, creationTime: Date? = nil
    ) {
        self.width = width
        self.height = height
        self.duration = duration
        self.location = location
        self.captureTime = captureTime
        self.camera = camera
        self.creationTime = creationTime
    }
}

public enum ImageReaderError: Error {
    case indexOutOfBounds
    case invalidData
    case unsupportedFormat
}
