import Foundation

/// The extension registry shared by clients and command-line tools.
public enum ImageReaderFactory {
    private static let readers: [String: ImageReader.Type] = [
        "heic": HeifReader.self, "heif": HeifReader.self, "hif": HeifReader.self,
        "jpg": JpegReader.self, "jpeg": JpegReader.self,
        "arw": ArwReader.self, "raf": RafReader.self, "dng": DngReader.self,
        "nef": NefReader.self, "pef": PefReader.self, "orf": OrfReader.self,
        "rw2": Rw2Reader.self, "cr2": Cr2Reader.self, "cr3": Cr3Reader.self,
        "mp4": Mp4Reader.self, "mov": Mp4Reader.self,
    ]

    public static var supportedExtensions: [String] {
        readers.keys.sorted()
    }

    public static func makeReader(
        forExtension fileExtension: String,
        readAt: @escaping (UInt64, UInt32) async throws -> Data
    ) throws -> any ImageReader {
        guard let type = readers[fileExtension.lowercased()] else {
            throw ImageReaderError.unsupportedFormat
        }
        return type.init(readAt: readAt)
    }
}
