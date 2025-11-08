import Foundation
import OSLog

private let logger = Logger(subsystem: "com.wangrunji.ImageThumbnailer", category: "GPSParser")

// MARK: - GPS Parsing Utilities

/// Parse GPS IFD using Reader for async file reading
func parseGPSIFD(reader: Reader, exifOffset: UInt64, gpsIFDOffset: UInt64) async throws
    -> GPSLocation?
{
    let offset = exifOffset + gpsIFDOffset
    let entryCount = try await reader.readUInt16(at: offset)
    logger.debug("Parsing GPS IFD at offset \(offset), entryCount: \(entryCount)")

    var latitudeRef: String?
    var latitudeData: [Double]?
    var longitudeRef: String?
    var longitudeData: [Double]?
    var altitudeRef: UInt8?
    var altitude: Double?

    for i in 0..<Int(entryCount) {
        let entryOffset = offset + 2 + UInt64(i) * 12

        let tag = try await reader.readUInt16(at: entryOffset)
        let type = try await reader.readUInt16(at: entryOffset + 2)
        let count = try await reader.readUInt32(at: entryOffset + 4)
        let valueOffset = try await reader.readUInt32(at: entryOffset + 8)

        switch tag {
        case 0x0001:  // GPSLatitudeRef (N/S)
            if type == 2, count == 2 {  // ASCII string
                if let data = try? await reader.read(at: entryOffset + 8, length: 1) {
                    latitudeRef = String(data: data, encoding: .ascii)
                }
            }
        case 0x0002:  // GPSLatitude (degrees, minutes, seconds)
            if type == 5, count == 3 {  // 3 RATIONAL values
                latitudeData = try? await parseRationalArray(
                    reader: reader, at: exifOffset + UInt64(valueOffset), count: 3)
            }
        case 0x0003:  // GPSLongitudeRef (E/W)
            if type == 2, count == 2 {  // ASCII string
                if let data = try? await reader.read(at: entryOffset + 8, length: 1) {
                    longitudeRef = String(data: data, encoding: .ascii)
                }
            }
        case 0x0004:  // GPSLongitude (degrees, minutes, seconds)
            if type == 5, count == 3 {  // 3 RATIONAL values
                longitudeData = try? await parseRationalArray(
                    reader: reader, at: exifOffset + UInt64(valueOffset), count: 3)
            }
        case 0x0005:  // GPSAltitudeRef (0 = above sea level, 1 = below)
            if type == 1 {  // BYTE
                altitudeRef = UInt8(valueOffset & 0xFF)
            }
        case 0x0006:  // GPSAltitude
            if type == 5 {  // RATIONAL
                if let rational = try? await parseRational(
                    reader: reader, at: exifOffset + UInt64(valueOffset))
                {
                    altitude = rational
                    if altitudeRef == 1 {
                        altitude = -rational  // Below sea level
                    }
                }
            }
        default:
            break
        }
    }

    // Convert GPS coordinates to decimal degrees
    guard let latRef = latitudeRef, let latData = latitudeData, latData.count == 3,
        let lonRef = longitudeRef, let lonData = longitudeData, lonData.count == 3
    else {
        logger.debug("GPS data incomplete")
        return nil
    }

    let latitude = convertToDecimalDegrees(
        degrees: latData[0], minutes: latData[1], seconds: latData[2], ref: latRef)
    let longitude = convertToDecimalDegrees(
        degrees: lonData[0], minutes: lonData[1], seconds: lonData[2], ref: lonRef)

    logger.debug("Parsed GPS location: lat=\(latitude), lon=\(longitude), alt=\(altitude ?? 0)")

    return GPSLocation(latitude: latitude, longitude: longitude, altitude: altitude)
}

/// Parse RATIONAL value (numerator/denominator)
private func parseRational(reader: Reader, at offset: UInt64) async throws -> Double {
    let numerator = try await reader.readUInt32(at: offset)
    let denominator = try await reader.readUInt32(at: offset + 4)
    guard denominator != 0 else { return 0 }
    return Double(numerator) / Double(denominator)
}

/// Parse array of RATIONAL values
private func parseRationalArray(reader: Reader, at offset: UInt64, count: Int) async throws
    -> [Double]
{
    var result: [Double] = []
    for i in 0..<count {
        let rational = try await parseRational(reader: reader, at: offset + UInt64(i * 8))
        result.append(rational)
    }
    return result
}

/// Convert GPS degrees/minutes/seconds to decimal degrees
private func convertToDecimalDegrees(degrees: Double, minutes: Double, seconds: Double, ref: String)
    -> Double
{
    var decimal = degrees + minutes / 60.0 + seconds / 3600.0
    if ref == "S" || ref == "W" {
        decimal = -decimal
    }
    return decimal
}
