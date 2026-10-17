import Foundation

// RUMSKROT-HARDEN: the typed error every response parser throws when the
// bytes a server sent cannot be what it claims to be.
public enum ResponseDecodingError: Error, Equatable, Sendable {
  /// A field, or a buffer an offset/length pair points at, runs past the
  /// end of the bytes that were actually received.
  case outOfBounds(offset: Int, count: Int, available: Int)
  /// A field holds a value the protocol does not allow here.
  case invalidValue(field: String, value: UInt64)
  /// A compound or multi-part reply did not carry the parts it promised.
  case missingResponse(expected: Int, received: Int)
}

extension ResponseDecodingError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .outOfBounds(offset, count, available):
      return "Malformed response: \(count) bytes at offset \(offset) exceed the \(available) bytes received"
    case let .invalidValue(field, value):
      return "Malformed response: invalid \(field) (\(value))"
    case let .missingResponse(expected, received):
      return "Malformed response: expected \(expected) replies, received \(received)"
    }
  }
}
