import ArgumentParser
import CryptoKit
import Foundation
import ImageIO
import ImageThumbnailer

struct ReadEvent: Encodable {
    let offset: UInt64
    let requestedBytes: UInt32
    let returnedBytes: Int
}

struct Performance: Encodable {
    var readCount = 0
    var requestedBytes: UInt64 = 0
    var returnedBytes: UInt64 = 0
    var elapsedMilliseconds: Double = 0

    mutating func add(_ other: Performance) {
        readCount += other.readCount
        requestedBytes += other.requestedBytes
        returnedBytes += other.returnedBytes
        elapsedMilliseconds += other.elapsedMilliseconds
    }
}

/// Measures calls at the library's readAt boundary, not filesystem cache misses.
final class MeasuredFile {
    let handle: FileHandle
    var events: [ReadEvent] = []

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, length: UInt32) throws -> Data {
        // Include failed attempts in the count and requested-byte total.
        let index = events.count
        events.append(ReadEvent(offset: offset, requestedBytes: length, returnedBytes: 0))
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        events[index] = ReadEvent(offset: offset, requestedBytes: length, returnedBytes: data.count)
        return data
    }

    func performance(since index: Int, start: UInt64) -> Performance {
        Performance(
            readCount: events.count - index,
            requestedBytes: events[index...].reduce(0) { $0 + UInt64($1.requestedBytes) },
            returnedBytes: events[index...].reduce(0) { $0 + UInt64($1.returnedBytes) },
            elapsedMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        )
    }
}

struct ThumbnailResult: Encodable {
    let index: Int
    let info: ThumbnailInfo
    var output: String?
    var outputBytes: Int?
    var sha256: String?
    var decodedWidth: Int?
    var decodedHeight: Int?
    var error: String?
    var performance = Performance()
}

struct FileResult: Encodable {
    let path: String
    var fileBytes: UInt64?
    var metadata: Metadata?
    var metadataPerformance = Performance()
    var thumbnailListPerformance = Performance()
    var thumbnails: [ThumbnailResult] = []
    var errors: [String] = []
    var performance = Performance()
    var reads: [ReadEvent] = []
}

struct Summary: Encodable {
    var fileCount = 0
    var failedFiles = 0
    var filesWithoutThumbnails = 0
    var thumbnailCount = 0
    var performance = Performance()
    var metadataPerformance = Performance()

    mutating func add(_ file: FileResult) {
        fileCount += 1
        failedFiles += file.errors.isEmpty ? 0 : 1
        filesWithoutThumbnails += file.errors.isEmpty && file.thumbnails.isEmpty ? 1 : 0
        thumbnailCount += file.thumbnails.count
        performance.add(file.performance)
        metadataPerformance.add(file.metadataPerformance)
    }
}

struct Report: Encodable {
    let schemaVersion = 1
    let inputDirectory: String
    let generatedAt = Date()
    let supportedExtensions = ImageReaderFactory.supportedExtensions
    var files: [FileResult] = []
    var skippedFiles = 0
    var summary = Summary()
}

@main
struct Benchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Recursively extract every embedded thumbnail and metadata, validate decoding, and measure readAt I/O."
    )

    @Argument(help: "Input directory (recursively scanned, case-insensitive extensions).")
    var directory: String

    @Option(name: .shortAndLong, help: "New or empty output directory. Must be outside the input directory.")
    var output: String

    func run() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
        let destination = URL(fileURLWithPath: output).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("Input must be an existing directory.")
        }
        guard destination != root, !destination.path.hasPrefix(root.path + "/") else {
            throw ValidationError("Output must be outside the input directory.")
        }
        if fm.fileExists(atPath: destination.path), try !(fm.contentsOfDirectory(atPath: destination.path)).isEmpty {
            throw ValidationError("Output directory must be empty; use a fresh directory for each run.")
        }
        var enumerationErrors: [String] = []
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [], errorHandler: { url, error in
                enumerationErrors.append("\(url.path): \(error.localizedDescription)")
                return true
            }
        ) else { throw ValidationError("Cannot enumerate input directory.") }
        var inputs: [URL] = []
        var skipped = 0
        let enumeratedURLs = enumerator.allObjects.compactMap { $0 as? URL }
        for url in enumeratedURLs {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if ImageReaderFactory.supportedExtensions.contains(url.pathExtension.lowercased()) {
                inputs.append(url)
            } else {
                skipped += 1
            }
        }
        guard enumerationErrors.isEmpty else { throw ValidationError(enumerationErrors.joined(separator: "\n")) }
        guard !inputs.isEmpty else { throw ValidationError("No supported files found.") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var report = Report(inputDirectory: root.path)
        report.skippedFiles = skipped
        for url in inputs.sorted(by: { $0.path < $1.path }) {
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            // A directory per complete source filename keeps duplicate stems/extensions distinct.
            let fileOutput = destination.appendingPathComponent("files").appendingPathComponent(relativePath)
            try fm.createDirectory(at: fileOutput, withIntermediateDirectories: true)
            let result = await process(url: url, relativePath: relativePath, output: fileOutput)
            try encoder.encode(result).write(to: fileOutput.appendingPathComponent("metadata.json"), options: .atomic)
            report.files.append(result)
            report.summary.add(result)
            print("\(result.errors.isEmpty ? "OK" : "FAIL") \(relativePath): \(result.thumbnails.count) thumbnails, \(result.performance.readCount) reads, \(result.performance.returnedBytes) bytes")
        }
        try encoder.encode(report).write(to: destination.appendingPathComponent("report.json"), options: .atomic)
        let count = report.files.reduce(0) { $0 + $1.performance.readCount }
        let bytes = report.files.reduce(UInt64(0)) { $0 + $1.performance.returnedBytes }
        print("\(report.files.count) files, \(report.summary.failedFiles) failed, \(skipped) skipped; \(count) reads, \(bytes) bytes. Report: \(destination.path)/report.json")
        if report.summary.failedFiles > 0 {
            throw ExitCode.failure
        }
    }

    private func process(url: URL, relativePath: String, output: URL) async -> FileResult {
        var result = FileResult(path: relativePath)
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            result.fileBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(UInt64.init)
            let file = try MeasuredFile(url: url)
            defer {
                result.performance = file.performance(since: 0, start: start)
                result.reads = file.events
            }
            let reader = try ImageReaderFactory.makeReader(forExtension: url.pathExtension) { offset, length in
                try file.read(at: offset, length: length)
            }
            var stageStart = DispatchTime.now().uptimeNanoseconds
            do { result.metadata = try await reader.getMetadata() }
            catch { result.errors.append("metadata: \(error)") }
            result.metadataPerformance = file.performance(since: 0, start: stageStart)
            let listStart = file.events.count
            stageStart = DispatchTime.now().uptimeNanoseconds
            var thumbnails: [ThumbnailInfo] = []
            do { thumbnails = try await reader.getThumbnailList() }
            catch { result.errors.append("thumbnail list: \(error)") }
            result.thumbnailListPerformance = file.performance(since: listStart, start: stageStart)
            for (index, info) in thumbnails.enumerated() {
                let readStart = file.events.count
                stageStart = DispatchTime.now().uptimeNanoseconds
                var thumbnail = ThumbnailResult(index: index, info: info)
                do {
                    let data = try await reader.getThumbnail(at: index)
                    let name = String(format: "%02d", index) + "." + info.format
                    try data.write(to: output.appendingPathComponent(name), options: .atomic)
                    thumbnail.output = name
                    thumbnail.outputBytes = data.count
                    thumbnail.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                    else {
                        throw ValidationError("Extracted thumbnail cannot be decoded by ImageIO.")
                    }
                    thumbnail.decodedWidth = image.width
                    thumbnail.decodedHeight = image.height
                } catch {
                    thumbnail.error = String(describing: error)
                    result.errors.append("thumbnail \(index): \(error)")
                }
                thumbnail.performance = file.performance(since: readStart, start: stageStart)
                result.thumbnails.append(thumbnail)
            }
        } catch { result.errors.append(String(describing: error)) }
        return result
    }
}
