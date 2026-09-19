import Foundation

/// Camera wall-clock time. A missing UTC offset remains unknown, never the host's time zone.
public struct CaptureTime: Sendable, Codable, Equatable {
    public let value: String
    public let subseconds: String?
    public let utcOffset: String?

    public init(value: String, subseconds: String? = nil, utcOffset: String? = nil) {
        self.value = value
        self.subseconds = subseconds
        self.utcOffset = utcOffset
    }

    /// An absolute instant is available only if the camera recorded its UTC offset.
    public var date: Date? {
        guard let utcOffset else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        guard let date = formatter.date(from: value + utcOffset) else { return nil }
        let fraction =
            subseconds.flatMap { text -> Double? in
                guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                    return nil
                }
                return Double("0." + text)
            } ?? 0
        return date.addingTimeInterval(fraction)
    }
}

/// Standard camera metadata. Numeric values use seconds, f-number, EV and millimetres.
/// Missing tags stay nil; vendor-specific MakerNotes are not interpreted.
public struct CameraMetadata: Sendable, Codable, Equatable {
    public internal(set) var make: String?
    public internal(set) var model: String?
    public internal(set) var lensMake: String?
    public internal(set) var lensModel: String?
    public internal(set) var software: String?
    public internal(set) var artist: String?
    public internal(set) var copyright: String?
    public internal(set) var orientation: UInt16?
    public internal(set) var exposureTime: Double?
    public internal(set) var fNumber: Double?
    public internal(set) var iso: UInt32?
    public internal(set) var exposureCompensation: Double?
    public internal(set) var focalLength: Double?
    public internal(set) var focalLengthIn35mm: UInt32?
    public internal(set) var exposureProgram: UInt32?
    public internal(set) var meteringMode: UInt32?
    public internal(set) var flash: UInt32?
    public internal(set) var whiteBalance: UInt32?

    public init() {}
}

extension CameraMetadata {
    func fillingMissing(from fallback: CameraMetadata) -> CameraMetadata {
        var merged = self
        merged.make = make ?? fallback.make
        merged.model = model ?? fallback.model
        merged.lensMake = lensMake ?? fallback.lensMake
        merged.lensModel = lensModel ?? fallback.lensModel
        merged.software = software ?? fallback.software
        merged.artist = artist ?? fallback.artist
        merged.copyright = copyright ?? fallback.copyright
        merged.orientation = orientation ?? fallback.orientation
        merged.exposureTime = exposureTime ?? fallback.exposureTime
        merged.fNumber = fNumber ?? fallback.fNumber
        merged.iso = iso ?? fallback.iso
        merged.exposureCompensation = exposureCompensation ?? fallback.exposureCompensation
        merged.focalLength = focalLength ?? fallback.focalLength
        merged.focalLengthIn35mm = focalLengthIn35mm ?? fallback.focalLengthIn35mm
        merged.exposureProgram = exposureProgram ?? fallback.exposureProgram
        merged.meteringMode = meteringMode ?? fallback.meteringMode
        merged.flash = flash ?? fallback.flash
        merged.whiteBalance = whiteBalance ?? fallback.whiteBalance
        return merged
    }
}

struct ExifMetadata {
    var camera = CameraMetadata()
    var original: String?
    var digitized: String?
    var originalSubseconds: String?
    var digitizedSubseconds: String?
    var originalOffset: String?
    var digitizedOffset: String?
    var location: GPSLocation?

    var captureTime: CaptureTime? {
        if let original {
            return CaptureTime(
                value: original, subseconds: originalSubseconds, utcOffset: originalOffset)
        }
        if let digitized {
            return CaptureTime(
                value: digitized, subseconds: digitizedSubseconds, utcOffset: digitizedOffset)
        }
        return nil
    }
}
