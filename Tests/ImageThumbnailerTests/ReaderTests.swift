import Foundation
@testable import ImageThumbnailer
import XCTest

final class ReaderTests: XCTestCase {
    private final class Source {
        let data = Data((0 ..< 32768).map { UInt8(truncatingIfNeeded: $0) })
        var reads: [(UInt64, UInt32)] = []
        func read(_ offset: UInt64, _ length: UInt32) -> Data {
            reads.append((offset, length))
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset) ..< min(data.count, Int(offset) + Int(length)))
        }
    }

    func testPartialHitsOnlyReadMissingRanges() async throws {
        let source = Source()
        let reader = Reader(readAt: source.read)
        try await reader.prefetch(at: 100, length: 100)
        try await reader.prefetch(at: 300, length: 100)
        let data = try await reader.read(at: 50, length: 400, readAhead: false)
        XCTAssertEqual(data, source.data.subdata(in: 50 ..< 450))
        XCTAssertEqual(source.reads.map(\.0), [100, 300, 50, 200, 400])
        XCTAssertEqual(source.reads.map(\.1), [100, 100, 50, 100, 50])
        let count = source.reads.count
        try await reader.prefetch(at: 50, length: 400)
        let again = try await reader.read(at: 50, length: 400)
        XCTAssertEqual(again, data)
        XCTAssertEqual(source.reads.count, count)
    }

    func testReadAheadStopsAtCachedRange() async throws {
        let source = Source()
        let reader = Reader(readAt: source.read)
        try await reader.prefetch(at: 100, length: 100)
        let data = try await reader.read(at: 98, length: 4)
        XCTAssertEqual(data, source.data.subdata(in: 98 ..< 102))
        XCTAssertEqual(source.reads.last?.0, 98)
        XCTAssertEqual(source.reads.last?.1, 2)
    }

    func testShortPrefetchAndEOFDoNotReadAgain() async throws {
        let source = Source()
        let reader = Reader(readAt: source.read)
        try await reader.prefetch(at: 32000, length: 4096)
        try await reader.prefetch(at: 32001, length: 4096)
        let tail = try await reader.read(at: 32760, length: 8)
        XCTAssertEqual(tail, source.data.suffix(8))
        do {
            _ = try await reader.read(at: 32760, length: 9)
            XCTFail("Truncated reads must fail")
        } catch {}
        XCTAssertEqual(source.reads.count, 1)
    }

    func testEmptyAndOverflowRanges() async throws {
        let source = Source()
        let reader = Reader(readAt: source.read)
        let empty = try await reader.read(at: UInt64.max, length: 0)
        XCTAssertTrue(empty.isEmpty)
        try await reader.prefetch(at: UInt64.max, length: 0)
        do {
            _ = try await reader.read(at: UInt64.max, length: 2)
            XCTFail("Overflow must fail")
        } catch ImageReaderError.invalidData {}
        XCTAssertTrue(source.reads.isEmpty)
    }

    func testUnalignedIntegersAcrossCacheBoundary() async throws {
        let source = Source()
        let reader = Reader(readAt: source.read)
        try await reader.prefetch(at: 0, length: 4)
        let big = try await reader.readUInt32(at: 1)
        let little = try await reader.readUInt32(at: 1, byteOrder: .littleEndian)
        XCTAssertEqual(big, 0x0102_0304)
        XCTAssertEqual(little, 0x0403_0201)
    }

    func testFactoryAndInvalidIndices() async throws {
        XCTAssertEqual(ImageReaderFactory.supportedExtensions.count, 16)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Apple_iPhone_16_Pro", withExtension: "HEIC", subdirectory: "Resources"))
        let data = try Data(contentsOf: url)
        let reader = try ImageReaderFactory.makeReader(forExtension: "HEIC") { offset, length in
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset) ..< min(data.count, Int(offset) + Int(length)))
        }
        for index in [-1, Int.max] {
            do {
                _ = try await reader.getThumbnail(at: index)
                XCTFail("Invalid index must throw")
            } catch ImageReaderError.indexOutOfBounds {}
        }
        XCTAssertThrowsError(try ImageReaderFactory.makeReader(forExtension: "png", readAt: { _, _ in Data() }))
    }
}
