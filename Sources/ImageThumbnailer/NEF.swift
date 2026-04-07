import Foundation

// MARK: - NefReader Implementation

/// Nikon NEF (RAW) image reader
/// NEF files are TIFF-based, with main image dimensions in SubIFD (SubfileType==0)
/// JPEG thumbnails are stored in SubIFDs via JPEGInterchangeFormat/Length tags
public class NefReader: TiffReader {
    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        super.init(readAt: readAt, mainImageStrategy: .useSubIfd)
    }
}
