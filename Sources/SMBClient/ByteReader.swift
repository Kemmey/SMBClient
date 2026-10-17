import Foundation

// RUMSKROT-HARDEN: every read is bounds-checked and throws instead of
// trapping, so a truncated or hostile response can never crash the client.
class ByteReader {
  private let data: Data
  private(set) var offset: Data.Index

  var availableBytes: Int {
    return max(0, data.endIndex - offset)
  }

  init(_ data: Data) {
    self.data = data
    offset = data.startIndex
  }

  func read<T: FixedWidthInteger>() throws -> T {
    let size = MemoryLayout<T>.size
    let value = try slice(count: size).to(type: T.self)
    offset += size
    return value
  }

  func read(count: Int) throws -> Data {
    let value = try slice(count: count)
    offset += count
    return Data(value)
  }

  func read(from: Int, count: Int) throws -> Data {
    guard from >= 0 else {
      throw ResponseDecodingError.outOfBounds(offset: from, count: count, available: data.count)
    }
    seek(to: from)
    return try read(count: count)
  }

  func seek(to: Int) {
    offset = data.startIndex + to
  }

  func remaining() -> Data {
    guard offset >= data.startIndex, offset < data.endIndex else { return Data() }
    return Data(data[offset...])
  }

  private func slice(count: Int) throws -> Data {
    guard count >= 0,
          offset >= data.startIndex,
          offset <= data.endIndex,
          count <= data.endIndex - offset
    else {
      throw ResponseDecodingError.outOfBounds(
        offset: offset - data.startIndex,
        count: count,
        available: data.count
      )
    }
    return data[offset..<(offset + count)]
  }
}

extension ByteReader {
  func read() throws -> Bool {
    let value: UInt8 = try read()
    return value == 1
  }

  func read() throws -> UUID {
    try read(count: 16).to(type: UUID.self)
  }
}
