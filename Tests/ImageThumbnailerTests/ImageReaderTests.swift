import XCTest

@testable import ImageThumbnailer

final class ImageReaderTests: XCTestCase {
    func testHeifReader() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "iPhone", withExtension: "HEIC") else {
            XCTFail("Test file not found")
            return
        }

        var readCount = 0
        var totalBytes: UInt64 = 0

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            readCount += 1
            totalBytes += UInt64(length)

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = HeifReader(readAt: readAt)

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnailList.isEmpty, "Should find at least one thumbnail")

        // Test getMetadata
        let metadata = try await reader.getMetadata()
        XCTAssertGreaterThan(metadata.width, 0, "Width should be greater than 0")
        XCTAssertGreaterThan(metadata.height, 0, "Height should be greater than 0")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")

        // Assert reasonable limits for HEIF files
        XCTAssertLessThanOrEqual(readCount, 5, "HEIF reader should not make more than 5 read calls")
        XCTAssertLessThanOrEqual(
            totalBytes, 100 * 1024, "HEIF reader should not read more than 100KB total")

        print("HEIF Reader - Read count: \(readCount), Total bytes: \(totalBytes)")

        // Test invalid index
        do {
            _ = try await reader.getThumbnail(at: 999)
            XCTFail("Should throw error for invalid index")
        } catch ImageReaderError.indexOutOfBounds {
            // Expected
        } catch {
            XCTFail("Should throw indexOutOfBounds error, got \(error)")
        }
    }

    func testJpegReader() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "iPhone5", withExtension: "JPG") else {
            XCTFail("Test file not found")
            return
        }

        var readCount = 0
        var totalBytes: UInt64 = 0

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            readCount += 1
            totalBytes += UInt64(length)

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = JpegReader(readAt: readAt)

        // Test getMetadata
        let metadata = try await reader.getMetadata()
        XCTAssertGreaterThan(metadata.width, 0, "Width should be greater than 0")
        XCTAssertGreaterThan(metadata.height, 0, "Height should be greater than 0")

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnailList.isEmpty, "Should find at least one thumbnail")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")

        // Assert reasonable limits for JPEG files
        XCTAssertLessThanOrEqual(readCount, 3, "JPEG reader should not make more than 5 read calls")
        XCTAssertLessThanOrEqual(
            totalBytes, 50 * 1024, "JPEG reader should not read more than 50KB total")

        print("JPEG Reader - Read count: \(readCount), Total bytes: \(totalBytes)")
    }

    func testArwReader() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "DSC04618", withExtension: "ARW") else {
            XCTFail("Test file not found")
            return
        }

        var readCount = 0
        var totalBytes: UInt64 = 0

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            readCount += 1
            totalBytes += UInt64(length)

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = ArwReader(readAt: readAt)

        // Test getMetadata
        let metadata = try await reader.getMetadata()
        XCTAssertGreaterThan(metadata.width, 0, "Width should be greater than 0")
        XCTAssertGreaterThan(metadata.height, 0, "Height should be greater than 0")

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnailList.isEmpty, "Should find at least one thumbnail")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")

        // Assert reasonable limits for Sony ARW files
        XCTAssertLessThanOrEqual(
            readCount, 10, "Sony ARW reader should not make more than 10 read calls")
        XCTAssertLessThanOrEqual(
            totalBytes, 1024 * 1024, "Sony ARW reader should not read more than 1MB total")

        print("Sony ARW Reader - Read count: \(readCount), Total bytes: \(totalBytes)")
    }

    func testNefReaderEfficient() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "高效压缩raw", withExtension: "NEF") else {
            XCTFail("Test file not found")
            return
        }

        var readCount = 0
        var totalBytes: UInt64 = 0

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            readCount += 1
            totalBytes += UInt64(length)

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = NefReader(readAt: readAt)

        // Test getMetadata
        let metadata = try await reader.getMetadata()
        XCTAssertEqual(metadata.width, 6064, "Width should be 6064")
        XCTAssertEqual(metadata.height, 4040, "Height should be 4040")

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertGreaterThanOrEqual(thumbnailList.count, 2, "Should find at least 2 thumbnails")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")

        // Assert reasonable limits for NEF files (thumbnails can be large ~1.4MB)
        XCTAssertLessThanOrEqual(
            readCount, 15, "NEF reader should not make more than 15 read calls")
        XCTAssertLessThanOrEqual(
            totalBytes, 2 * 1024 * 1024, "NEF reader should not read more than 2MB total")

        print(
            "NEF Reader (Efficient) - Read count: \(readCount), Total bytes: \(totalBytes), Thumbnails: \(thumbnailList.count)"
        )
    }

    func testNefReaderLossless() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "无损压缩raw", withExtension: "NEF") else {
            XCTFail("Test file not found")
            return
        }

        var readCount = 0
        var totalBytes: UInt64 = 0

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            readCount += 1
            totalBytes += UInt64(length)

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = NefReader(readAt: readAt)

        // Test getMetadata
        let metadata = try await reader.getMetadata()
        XCTAssertEqual(metadata.width, 6040, "Width should be 6040")
        XCTAssertEqual(metadata.height, 4032, "Height should be 4032")

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertGreaterThanOrEqual(thumbnailList.count, 2, "Should find at least 2 thumbnails")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")

        // Assert reasonable limits for NEF files (thumbnails can be large ~2.2MB)
        XCTAssertLessThanOrEqual(
            readCount, 15, "NEF reader should not make more than 15 read calls")
        XCTAssertLessThanOrEqual(
            totalBytes, 3 * 1024 * 1024, "NEF reader should not read more than 3MB total")

        print(
            "NEF Reader (Lossless) - Read count: \(readCount), Total bytes: \(totalBytes), Thumbnails: \(thumbnailList.count)"
        )
    }

    func testMp4Reader() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "Pocket3", withExtension: "MP4") else {
            XCTFail("Test file not found")
            return
        }

        var readCount = 0
        var totalBytes: UInt64 = 0

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            readCount += 1
            totalBytes += UInt64(length)

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = Mp4Reader(readAt: readAt)

        // Test getMetadata
        let metadata = try await reader.getMetadata()
        XCTAssertGreaterThan(metadata.width, 0, "Width should be greater than 0")
        XCTAssertGreaterThan(metadata.height, 0, "Height should be greater than 0")
        XCTAssertNotNil(metadata.duration, "Duration should be parsed")

        // Additional assertions based on exiftool output
        // Duration should be around 3.75 seconds (allowing for small variations)
        if let duration = metadata.duration {
            XCTAssertTrue(
                duration > 3.5 && duration < 4.0, "Duration should be around 3.75 seconds")
        }

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnailList.isEmpty, "Should find at least one thumbnail")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")

        // Assert reasonable limits for MP4 files
        XCTAssertLessThanOrEqual(readCount, 10, "MP4 reader should not make more than 10 read calls")
        XCTAssertLessThanOrEqual(
            totalBytes, 1024 * 1024, "MP4 reader should not read more than 1MB total")

        print("MP4 Reader - Read count: \(readCount), Total bytes: \(totalBytes)")
    }

    func testMp4ReaderH264() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "IMG_0772", withExtension: "MOV") else {
            XCTFail("Test file not found")
            return
        }

        var readCount = 0
        var totalBytes: UInt64 = 0

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            readCount += 1
            totalBytes += UInt64(length)

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = Mp4Reader(readAt: readAt)

        // Test getMetadata
        let metadata = try await reader.getMetadata()
        XCTAssertGreaterThan(metadata.width, 0, "Width should be greater than 0")
        XCTAssertGreaterThan(metadata.height, 0, "Height should be greater than 0")
        XCTAssertNotNil(metadata.duration, "Duration should be parsed")

        // Additional assertions based on exiftool output for IMG_0772.MOV
        // Image dimensions: 1920x1080
        XCTAssertEqual(metadata.width, 1920, "Width should be 1920")
        XCTAssertEqual(metadata.height, 1080, "Height should be 1080")

        // Duration should be around 3.25 seconds
        if let duration = metadata.duration {
            XCTAssertTrue(
                duration > 3.2 && duration < 3.3, "Duration should be around 3.25 seconds")
        }

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnailList.isEmpty, "Should find at least one thumbnail")
        XCTAssertEqual(thumbnailList[0].format, "heic", "Thumbnail format should be heic")
        XCTAssertEqual(thumbnailList[0].width, 1920, "Thumbnail width should be 1920")
        XCTAssertEqual(thumbnailList[0].height, 1080, "Thumbnail height should be 1080")

        // Test getThumbnail (extract first frame)
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")
        XCTAssertGreaterThan(
            thumbnailData.count, 100 * 1024, "Thumbnail should be larger than 100KB")

        // Assert reasonable limits for H.264 MP4 files
        XCTAssertLessThanOrEqual(
            readCount, 5, "MP4 H.264 reader should not make more than 5 read calls")
        XCTAssertLessThanOrEqual(
            totalBytes, 1024 * 1024, "MP4 H.264 reader should not read more than 1MB total")

        print("MP4 H.264 Reader - Read count: \(readCount), Total bytes: \(totalBytes)")
    }
}
