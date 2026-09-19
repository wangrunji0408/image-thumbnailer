import Foundation

/// Reads only selected TIFF/EXIF values. Explicit endianness avoids changing the enclosing reader.
struct ExifParser {
    let reader: Reader
    let base: UInt64
    let length: UInt64?
    private var order: ByteOrder = .bigEndian
    private var visited = Set<UInt32>()
    private var result = ExifMetadata()

    init(reader: Reader, offset: UInt64, length: UInt64? = nil) {
        self.reader = reader
        base = offset
        self.length = length
    }

    mutating func parse(gps: Bool = false, into metadata: ExifMetadata = ExifMetadata())
        async throws -> ExifMetadata
    {
        result = metadata
        let mark = try await data(0, 2)
        guard mark == Data([0x49, 0x49]) || mark == Data([0x4D, 0x4D]) else {
            throw ImageReaderError.invalidData
        }
        order = mark[0] == 0x49 ? .littleEndian : .bigEndian
        let magic = try await u16(2)
        guard [42, 0x4F52, 0x55].contains(magic) else { throw ImageReaderError.invalidData }
        let first = try await u32(4)
        try await ifd(first, gps: gps)
        return result
    }

    private func data(_ offset: UInt64, _ size: UInt32) async throws -> Data {
        guard offset <= UInt64.max - base, base + offset <= UInt64.max - UInt64(size) else {
            throw ImageReaderError.invalidData
        }
        if let length {
            guard offset <= length, UInt64(size) <= length - offset else {
                throw ImageReaderError.invalidData
            }
        }
        return try await reader.read(at: base + offset, length: size)
    }

    private func u16(_ offset: UInt64) async throws -> UInt16 {
        let d = try await data(offset, 2)
        return order == .littleEndian
            ? UInt16(d[0]) | UInt16(d[1]) << 8 : UInt16(d[0]) << 8 | UInt16(d[1])
    }

    private func u32(_ offset: UInt64) async throws -> UInt32 {
        let d = try await data(offset, 4)
        return (order == .littleEndian ? Array(d.reversed()) : Array(d)).reduce(0) {
            ($0 << 8) | UInt32($1)
        }
    }

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let offset: UInt64
    }

    private func string(_ e: Entry) async throws -> String? {
        guard e.type == 2, e.count > 0, e.count <= 4096 else { return nil }
        let d = try await data(e.offset, e.count)
        let text = String(data: d.prefix(while: { $0 != 0 }), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func integer(_ e: Entry) async throws -> UInt32? {
        guard e.count > 0 else { return nil }
        switch e.type {
        case 1: return UInt32(try await data(e.offset, 1)[0])
        case 3: return UInt32(try await u16(e.offset))
        case 4, 13: return try await u32(e.offset)
        default: return nil
        }
    }

    private func rational(_ e: Entry, index: UInt32 = 0) async throws -> Double? {
        guard e.type == 5 || e.type == 10, index < e.count else { return nil }
        let offset = e.offset + UInt64(index) * 8
        let numerator = try await u32(offset)
        let denominator = try await u32(offset + 4)
        guard denominator != 0 else { return nil }
        if e.type == 10 {
            return Double(Int32(bitPattern: numerator)) / Double(Int32(bitPattern: denominator))
        }
        return Double(numerator) / Double(denominator)
    }

    private mutating func ifd(_ offset: UInt32, gps: Bool) async throws {
        guard offset >= 8, visited.count < 8, visited.insert(offset).inserted else {
            throw ImageReaderError.invalidData
        }
        let count = try await u16(UInt64(offset))
        guard count <= 1024 else { throw ImageReaderError.invalidData }
        // Validate and buffer the directory once; never fetch unselected payloads or MakerNotes.
        _ = try await data(UInt64(offset) + 2, UInt32(count) * 12)
        var exifPointer: UInt32?
        var gpsPointer: UInt32?
        var gpsValues: [UInt16: Entry] = [:]
        let selected: Set<UInt16> = [
            0x10F, 0x110, 0x112, 0x131, 0x13B, 0x8298, 0x8769, 0x8825,
            0x829A, 0x829D, 0x8822, 0x8827, 0x8833, 0x9003, 0x9004, 0x9011, 0x9012,
            0x9204, 0x9207, 0x9209, 0x920A, 0x9291, 0x9292, 0xA403, 0xA405, 0xA433, 0xA434,
        ]
        for i in 0..<UInt32(count) {
            let p = UInt64(offset) + 2 + UInt64(i) * 12
            let tag = try await u16(p)
            guard gps ? tag <= 6 : selected.contains(tag) else { continue }
            let type = try await u16(p + 2)
            let count = try await u32(p + 4)
            let sizes: [UInt16: UInt64] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 9: 4, 10: 8, 13: 4]
            guard let unit = sizes[type], count > 0 else { continue }
            let bytes = unit * UInt64(count)
            let valueOffset = bytes <= 4 ? p + 8 : UInt64(try await u32(p + 8))
            let e = Entry(tag: tag, type: type, count: count, offset: valueOffset)
            if gps {
                gpsValues[tag] = e
                continue
            }
            switch tag {
            case 0x10F: result.camera.make = try await string(e)
            case 0x110: result.camera.model = try await string(e)
            case 0x112:
                if let n = try await integer(e), (1...8).contains(n) {
                    result.camera.orientation = UInt16(n)
                }
            case 0x131: result.camera.software = try await string(e)
            case 0x13B: result.camera.artist = try await string(e)
            case 0x8298: result.camera.copyright = try await string(e)
            case 0x8769: exifPointer = try await integer(e)
            case 0x8825: gpsPointer = try await integer(e)
            case 0x829A: result.camera.exposureTime = try await rational(e)
            case 0x829D: result.camera.fNumber = try await rational(e)
            case 0x8822: result.camera.exposureProgram = try await integer(e)
            case 0x8827: result.camera.iso = try await integer(e)
            case 0x8833:
                if result.camera.iso == nil || result.camera.iso == 65535 {
                    result.camera.iso = try await integer(e)
                }
            case 0x9003: result.original = try await string(e)
            case 0x9004: result.digitized = try await string(e)
            case 0x9011: result.originalOffset = try await string(e)
            case 0x9012: result.digitizedOffset = try await string(e)
            case 0x9291: result.originalSubseconds = try await string(e)
            case 0x9292: result.digitizedSubseconds = try await string(e)
            case 0x9204: result.camera.exposureCompensation = try await rational(e)
            case 0x9207: result.camera.meteringMode = try await integer(e)
            case 0x9209: result.camera.flash = try await integer(e)
            case 0x920A: result.camera.focalLength = try await rational(e)
            case 0xA403: result.camera.whiteBalance = try await integer(e)
            case 0xA405: result.camera.focalLengthIn35mm = try await integer(e)
            case 0xA433: result.camera.lensMake = try await string(e)
            case 0xA434: result.camera.lensModel = try await string(e)
            default: break
            }
        }
        if let exifPointer, exifPointer != 0 { try await ifd(exifPointer, gps: false) }
        if let gpsPointer, gpsPointer != 0 { try await ifd(gpsPointer, gps: true) }
        if gps { result.location = try await location(gpsValues) }
    }

    private func location(_ values: [UInt16: Entry]) async throws -> GPSLocation? {
        guard let lat = values[2], let lon = values[4], lat.count == 3, lon.count == 3,
            let latRef = values[1], let lonRef = values[3],
            let latitudeRef = try await string(latRef), let longitudeRef = try await string(lonRef),
            ["N", "S"].contains(latitudeRef), ["E", "W"].contains(longitudeRef)
        else { return nil }
        func degrees(_ e: Entry) async throws -> Double? {
            guard let d = try await rational(e), let m = try await rational(e, index: 1),
                let s = try await rational(e, index: 2)
            else { return nil }
            return d + m / 60 + s / 3600
        }
        guard let latitude = try await degrees(lat), let longitude = try await degrees(lon),
            latitude <= 90, longitude <= 180
        else { return nil }
        var altitude = 0.0
        if let e = values[6] { altitude = try await rational(e) ?? 0 }
        if let e = values[5], try await integer(e) == 1 { altitude = -altitude }
        return GPSLocation(
            latitude: Float(latitude * (latitudeRef == "S" ? -1 : 1)),
            longitude: Float(longitude * (longitudeRef == "W" ? -1 : 1)), altitude: Float(altitude))
    }
}
