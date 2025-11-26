import AppKit
import ArgumentParser
import Foundation
import ImageThumbnailer
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.wangrunji.ImageThumbnailer", category: "CLI")

@main
struct ImageThumbnailCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ImageThumbnailCLI",
        abstract:
            "A tool to generate thumbnails from various image formats including HEIF, JPEG, and Sony ARW files."
    )

    @Argument(help: "The path to the image file (HEIF, JPEG, or Sony ARW)")
    var imagePath: String

    @Option(name: .shortAndLong, help: "The length of the thumbnail's short side")
    var shortSideLength: UInt32?

    @Option(name: .shortAndLong, help: "The index of the thumbnail to extract")
    var thumbnailIndex: Int?

    @Option(name: .shortAndLong, help: "The output path for the thumbnail")
    var outputPath: String?

    func run() async throws {
        do {
            let fileURL = URL(fileURLWithPath: imagePath)
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { fileHandle.closeFile() }

            print("extracting thumbnail from \(imagePath)...")

            // create read function
            var readCount = 0
            var readBytes = 0
            let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
                readCount += 1
                readBytes += Int(length)
                try fileHandle.seek(toOffset: offset)
                let data = fileHandle.readData(ofLength: Int(length))
                logger.debug(
                    "read data: offset=\(offset), length=\(length), data=\(data.count) bytes")
                return data
            }

            // Determine file type and extract thumbnail accordingly
            let fileExtension = fileURL.pathExtension.lowercased()

            let reader: ImageReader
            switch fileExtension {
            case "heic", "heif", "hif":
                reader = HeifReader(readAt: readAt)
            case "jpg", "jpeg":
                reader = JpegReader(readAt: readAt)
            case "arw":
                reader = SonyArwReader(readAt: readAt)
            case "mp4", "mov":
                reader = Mp4Reader(readAt: readAt)
            default:
                logger.error(
                    "unsupported file format: \(fileExtension). Only HEIF, JPEG, ARW, MP4, and MOV are supported."
                )
                return
            }

            let metadata = try await reader.getMetadata()
            print("metadata:")
            print("  size: \(metadata.width)x\(metadata.height)")
            if let duration = metadata.duration {
                print("  duration: \(String(format: "%.2f", duration)) seconds")
            }
            if let location = metadata.location {
                let locationStr =
                    "  location: \(String(format: "%.6f", location.latitude)), \(String(format: "%.6f", location.longitude)), \(String(format: "%.2f", location.altitude))m"
                print(locationStr)
            }

            let thumbnailList = try await reader.getThumbnailList()
            if thumbnailList.isEmpty {
                print("no thumbnail found in file")
                return
            }

            // 显示所有找到的缩略图
            print("found \(thumbnailList.count) thumbnails:")
            for (i, info) in thumbnailList.enumerated() {
                print(
                    "  [\(i)] format: \(info.format), size: \(info.size) bytes, dimensions: \(info.width ?? 0)x\(info.height ?? 0), rotation: \(info.rotation ?? 0)"
                )
            }

            let index: Int
            if let thumbnailIndex = thumbnailIndex {
                guard thumbnailIndex >= 0 && thumbnailIndex < thumbnailList.count else {
                    print("thumbnail index out of bounds")
                    return
                }
                index = thumbnailIndex
            } else {
                var indices = Array(0..<thumbnailList.count)
                indices.sort { thumbnailList[$0].width ?? 0 < thumbnailList[$1].width ?? 0 }
                index =
                    indices.first(where: { thumbnailList[$0].width ?? 0 >= shortSideLength ?? 0 })
                    ?? 0
            }
            let info = thumbnailList[index]
            let thumbnailData = try await reader.getThumbnail(at: index)
            print("selected thumbnail index: \(index)")
            print("read count: \(readCount), bytes: \(readBytes)")

            if info.rotation != 0 {
                if let correctedData = applyOrientationCorrection(
                    to: thumbnailData, rotation: info.rotation ?? 0, flip: false)
                {
                    let outputURL = URL(fileURLWithPath: outputPath ?? "thumbnail.heic")
                    try correctedData.write(to: outputURL)
                    print("rotated thumbnail saved to: \(outputURL.path)")
                    return
                } else {
                    logger.warning(
                        "Failed to apply orientation correction, returning original data")
                }
            }

            // save thumbnail data
            let outputURL = URL(fileURLWithPath: outputPath ?? "thumbnail.\(info.format)")
            try thumbnailData.write(to: outputURL)
            print("thumbnail saved to: \(outputURL.path)")
        } catch {
            logger.error("\(error.localizedDescription)")
        }
    }
}

/// Apply orientation correction to thumbnail data and return corrected Data
/// - Parameters:
///   - thumbnailData: Original thumbnail data
///   - rotation: Rotation degrees (0, 90, 180, 270)
/// - Returns: Corrected thumbnail data, or nil if correction fails
func applyOrientationCorrection(to thumbnailData: Data, rotation: Int, flip: Bool) -> Data? {
    // If no rotation needed, return original data
    guard rotation != 0 || flip else { return thumbnailData }

    // Create CGImage from thumbnail data
    guard let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil),
        let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        logger.error("Failed to create CGImage from thumbnail data")
        return nil
    }

    // Apply rotation
    let rotatedImage = rotateCGImage(cgImage, by: rotation, flip: flip)

    // Convert back to HEIC data
    guard let mutableData = CFDataCreateMutable(nil, 0),
        let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.heic.identifier as CFString, 1, nil)
    else {
        logger.error("Failed to create image destination")
        return nil
    }

    // Set HEIC compression quality
    let options: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.8
    ]

    CGImageDestinationAddImage(destination, rotatedImage, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
        logger.error("Failed to finalize image destination")
        return nil
    }

    logger.debug("Successfully applied orientation correction")
    return mutableData as Data
}

private func rotateCGImage(_ image: CGImage, by degrees: Int, flip: Bool) -> CGImage {
    let normalizedDegrees = ((degrees % 360) + 360) % 360
    guard normalizedDegrees != 0 || flip else { return image }

    let (width, height) = (image.width, image.height)
    let (newWidth, newHeight) =
        (normalizedDegrees == 90 || normalizedDegrees == 270) ? (height, width) : (width, height)

    guard let colorSpace = image.colorSpace,
        let context = CGContext(
            data: nil, width: newWidth, height: newHeight,
            bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue
        )
    else {
        return image
    }

    context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
    if flip {
        context.scaleBy(x: -1, y: 1)
    }
    context.rotate(by: -CGFloat(normalizedDegrees) * .pi / 180)
    context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    return context.makeImage() ?? image
}
