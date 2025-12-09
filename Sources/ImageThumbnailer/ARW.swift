import Foundation

// MARK: - ArwReader Implementation

/// Sony ARW (RAW) image reader
/// ARW files are TIFF-based, with main image dimensions in IFD0 or SubIFD
public class ArwReader: TiffReader {
    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        super.init(readAt: readAt, mainImageStrategy: .useIfd0)
    }
}
