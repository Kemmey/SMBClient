import Foundation

// RUMSKROT-COPY: the payloads of the two FSCTLs that make up an SMB2
// server-side copy (MS-SMB2 2.2.31.1, 2.2.32.1, 2.2.32.3): a resume key
// for the open source file, then copy-chunk requests on the destination
// that name byte ranges of it. No file data crosses the network.
public enum ServerSideCopy {
  /// SRV_REQUEST_RESUME_KEY response: a 24-byte key naming the open
  /// source file on the server that issued it.
  public struct ResumeKey {
    public let key: Data
    public let contextLength: UInt32

    public init(data: Data) throws {
      let reader = ByteReader(data)
      key = try reader.read(count: 24)
      contextLength = try reader.read()
    }
  }

  /// SRV_COPYCHUNK: one byte range of the source, written at an offset
  /// of the destination.
  public struct Chunk: Equatable {
    public let sourceOffset: UInt64
    public let targetOffset: UInt64
    public let length: UInt32

    public init(sourceOffset: UInt64, targetOffset: UInt64, length: UInt32) {
      self.sourceOffset = sourceOffset
      self.targetOffset = targetOffset
      self.length = length
    }

    public func encoded() -> Data {
      var data = Data()
      data += sourceOffset
      data += targetOffset
      data += length
      data += UInt32(0)
      return data
    }
  }

  /// SRV_COPYCHUNK_COPY: the input of FSCTL_SRV_COPYCHUNK(_WRITE).
  public struct CopyChunkCopy {
    public let sourceKey: Data
    public let chunks: [Chunk]

    public init(sourceKey: Data, chunks: [Chunk]) {
      self.sourceKey = sourceKey
      self.chunks = chunks
    }

    public func encoded() -> Data {
      var data = Data()
      data += sourceKey
      data += UInt32(truncatingIfNeeded: chunks.count)
      data += UInt32(0)
      for chunk in chunks {
        data += chunk.encoded()
      }
      return data
    }
  }

  /// SRV_COPYCHUNK_RESPONSE. On success it says how much was written; with
  /// STATUS_INVALID_PARAMETER the same three fields carry the server's
  /// limits instead (MS-SMB2 3.3.5.15.6.2).
  public struct CopyChunkResponse {
    public let chunksWritten: UInt32
    public let chunkBytesWritten: UInt32
    public let totalBytesWritten: UInt32

    public init(data: Data) throws {
      let reader = ByteReader(data)
      chunksWritten = try reader.read()
      chunkBytesWritten = try reader.read()
      totalBytesWritten = try reader.read()
    }
  }

  /// How much one copy-chunk request may carry.
  public struct Limits: Equatable {
    public let maxChunkCount: UInt32
    public let maxChunkSize: UInt32
    public let maxTotalSize: UInt32

    public init(maxChunkCount: UInt32, maxChunkSize: UInt32, maxTotalSize: UInt32) {
      self.maxChunkCount = maxChunkCount
      self.maxChunkSize = maxChunkSize
      self.maxTotalSize = maxTotalSize
    }

    /// Within the defaults Windows and Samba both advertise (256 chunks,
    /// 1 MiB each, 16 MiB a request), so most servers never need to say.
    public static let `default` = Limits(maxChunkCount: 16, maxChunkSize: 1024 * 1024, maxTotalSize: 16 * 1024 * 1024)

    /// The limits a server reported with STATUS_INVALID_PARAMETER.
    init(_ response: CopyChunkResponse) {
      maxChunkCount = response.chunksWritten
      maxChunkSize = response.chunkBytesWritten
      maxTotalSize = response.totalBytesWritten
    }

    /// The chunks of one request starting at `offset` of a `size`-byte file.
    func chunks(from offset: UInt64, size: UInt64) -> [Chunk] {
      var chunks = [Chunk]()
      var position = offset
      var total: UInt64 = 0
      while position < size, chunks.count < Int(maxChunkCount), total < UInt64(maxTotalSize) {
        let length = min(UInt64(maxChunkSize), size - position, UInt64(maxTotalSize) - total)
        chunks.append(Chunk(sourceOffset: position, targetOffset: position, length: UInt32(length)))
        position += length
        total += length
      }
      return chunks
    }

    var isUsable: Bool {
      maxChunkCount > 0 && maxChunkSize > 0 && maxTotalSize > 0
    }
  }
}

public enum ServerSideCopyError: Error {
  /// The server would not copy within the limits it reported.
  case limitsRefused(ServerSideCopy.Limits)
  /// A copy-chunk request succeeded without writing anything.
  case noProgress(offset: UInt64)
}
