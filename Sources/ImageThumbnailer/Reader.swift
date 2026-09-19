import Foundation

class Reader {
    private let readAt: (UInt64, UInt32) async throws -> Data
    private var buffers: [(UInt64, Data)] = []
    private var eofOffset: UInt64?
    private var byteOrder: ByteOrder = .bigEndian
    private let minReadSize: UInt32 = 4096

    init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        self.readAt = readAt
    }

    func setByteOrder(_ byteOrder: ByteOrder) {
        self.byteOrder = byteOrder
    }

    /// Cache disjoint ranges and fetch only holes, including partial cache hits.
    /// Large payload reads are exact; small parser reads use bounded read-ahead.
    func read(at offset: UInt64, length: UInt32, readAhead: Bool = true) async throws -> Data {
        guard length > 0 else { return Data() }
        let end = try checkedEnd(offset, length)
        if let data = cachedSlice(at: offset, end: end) {
            return data
        }
        try await fill(at: offset, end: end, readAhead: readAhead && length < minReadSize)
        var result = Data()
        result.reserveCapacity(Int(length))
        var position = offset
        for (start, data) in buffers {
            let bufferEnd = start + UInt64(data.count)
            guard bufferEnd > position else { continue }
            guard start <= position else { break }
            let sliceEnd = min(end, bufferEnd)
            result.append(data.subdata(in: Int(position - start) ..< Int(sliceEnd - start)))
            position = sliceEnd
            if position == end {
                return result
            }
        }
        throw NSError(domain: "ReaderError", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Read length exceeds available data"])
    }

    /// Prefetch is best effort at EOF, but never re-reads an already cached range.
    func prefetch(at offset: UInt64, length: UInt32) async throws {
        guard length > 0 else { return }
        try await fill(at: offset, end: checkedEnd(offset, length), readAhead: false)
    }

    private func checkedEnd(_ offset: UInt64, _ length: UInt32) throws -> UInt64 {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow else { throw ImageReaderError.invalidData }
        return end
    }

    private func cachedSlice(at offset: UInt64, end: UInt64) -> Data? {
        for (start, data) in buffers where start <= offset {
            if end <= start + UInt64(data.count) {
                return data.subdata(in: Int(offset - start) ..< Int(end - start))
            }
        }
        return nil
    }

    private func fill(at offset: UInt64, end: UInt64, readAhead: Bool) async throws {
        var position = offset
        while position < end {
            if let eofOffset, position >= eofOffset {
                return
            }
            if let (start, data) = buffers.first(where: {
                $0.0 <= position && position < $0.0 + UInt64($0.1.count)
            }) {
                position = min(end, start + UInt64(data.count))
                continue
            }
            let nextStart = buffers.first(where: { $0.0 > position })?.0 ?? UInt64.max
            let required = min(end, nextStart) - position
            let wanted = readAhead ? max(required, UInt64(minReadSize)) : required
            let count = UInt32(min(wanted, nextStart - position, UInt64(UInt32.max)))
            let data = try await readAt(position, count)
            guard data.count <= Int(count) else { throw ImageReaderError.invalidData }
            if !data.isEmpty {
                let index = buffers.firstIndex(where: { $0.0 > position }) ?? buffers.endIndex
                buffers.insert((position, data), at: index)
                position += UInt64(data.count)
            }
            // Preserve readAt's short-read/EOF semantics; do not retry a truncated range.
            if data.count < Int(count) {
                eofOffset = position
                return
            }
        }
    }

    func readUInt8(at offset: UInt64) async throws -> UInt8 {
        let data = try await read(at: offset, length: 1)
        return data[0]
    }

    func readUInt16(at offset: UInt64, byteOrder: ByteOrder? = nil) async throws -> UInt16 {
        try await readInteger(at: offset, byteOrder: byteOrder)
    }

    func readUInt32(at offset: UInt64, byteOrder: ByteOrder? = nil) async throws -> UInt32 {
        try await readInteger(at: offset, byteOrder: byteOrder)
    }

    func readUInt64(at offset: UInt64, byteOrder: ByteOrder? = nil) async throws -> UInt64 {
        try await readInteger(at: offset, byteOrder: byteOrder)
    }

    func readInt32(at offset: UInt64, byteOrder: ByteOrder? = nil) async throws -> Int32 {
        try await readInteger(at: offset, byteOrder: byteOrder)
    }

    private func readInteger<T: FixedWidthInteger>(at offset: UInt64, byteOrder: ByteOrder?) async throws -> T {
        let data = try await read(at: offset, length: UInt32(MemoryLayout<T>.size))
        let value = data.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        return (byteOrder ?? self.byteOrder) == .bigEndian ? T(bigEndian: value) : T(littleEndian: value)
    }

    func readString(at offset: UInt64, length: UInt32) async throws -> String {
        try String(data: await read(at: offset, length: length), encoding: .ascii) ?? ""
    }
}

enum ByteOrder {
    case bigEndian
    case littleEndian
}
