import Foundation

// MARK: - DngReader Implementation

/// Adobe DNG (Digital Negative) image reader
/// DNG files are TIFF-based, with main image dimensions in SubIFD
/// Preview images are stored in IFD0 with PreviewImageStart/PreviewImageLength tags
public class DngReader: TiffReader {
    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        super.init(readAt: readAt, mainImageStrategy: .useSubIfd)
    }
}
