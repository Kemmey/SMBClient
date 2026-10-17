import Foundation

public class FileReader {
  private let session: Session
  private let path: String

  private var createResponse: Create.Response?

  public var fileSize: UInt64 {
    get async throws {
      let fileProxy = try await fileProxy()
      return fileProxy.size
    }
  }

  init(session: Session, path: String) {
    self.session = session
    self.path = path
  }

  public func read(offset: UInt64) async throws -> Data {
    try await read(offset: offset, length: session.maxReadSize)
  }

  public func read(offset: UInt64, length: UInt32) async throws -> Data {
    // RUMSKROT-HARDEN: nothing to read is not a stalled read.
    guard length > 0 else { return Data() }
    let readSize = min(length, session.maxReadSize)
    let fileProxy = try await fileProxy()

    var buffer = Data()

    var response: Read.Response
    repeat {
      response = try await session.read(
        fileId: fileProxy.id,
        offset: offset + UInt64(buffer.count),
        length: min(readSize, length - UInt32(truncatingIfNeeded: buffer.count))
      )

      try requireProgress(response)
      buffer.append(response.buffer)
    } while NTStatus(response.header.status) != .endOfFile && buffer.count < length && offset + UInt64(buffer.count) < fileProxy.size

    return buffer
  }

  public func download(progressHandler: (_ progress: Double) -> Void = { _ in }) async throws -> Data {
    let fileProxy = try await fileProxy()

    var offset: UInt64 = 0
    var buffer = Data()

    var response: Read.Response
    repeat {
      response = try await session.read(
        fileId: fileProxy.id,
        offset: offset
      )

      try requireProgress(response)
      buffer.append(response.buffer)
      offset = UInt64(buffer.count)
      progressHandler(fraction(offset, of: fileProxy.size))
    } while NTStatus(response.header.status) != .endOfFile && buffer.count < fileProxy.size

    progressHandler(1.0)
    return buffer
  }

  public func download(to localPath: URL, overwrite: Bool = false, progressHandler: (_ progress: Double) -> Void = { _ in }) async throws {
    let fileManger = FileManager()
    let fileExists = fileManger.fileExists(atPath: localPath.path)

    if fileExists {
      if overwrite {
        try Data().write(to: localPath)
      } else {
        throw CocoaError(.fileWriteFileExists)
      }
    }

    if !fileExists {
      try Data().write(to: localPath)
    }
    guard let fileHandle = FileHandle(forWritingAtPath: localPath.path) else {
      throw URLError(.cannotWriteToFile)
    }

    defer {
      fileHandle.closeFile()
    }

    try await download(fileHandle: fileHandle, progressHandler: progressHandler)
  }

  public func download(fileHandle: FileHandle, progressHandler: (_ progress: Double) -> Void = { _ in }) async throws {
    let fileProxy = try await fileProxy()

    var offset: UInt64 = 0
    var response: Read.Response
    repeat {
      response = try await session.read(
        fileId: fileProxy.id,
        offset: offset
      )

      try requireProgress(response)
      fileHandle.seekToEndOfFile()
      fileHandle.write(response.buffer)
      offset += UInt64(response.buffer.count)

      let progress = fraction(offset, of: fileProxy.size)
      progressHandler(progress)
    } while NTStatus(response.header.status) != .endOfFile && offset < fileProxy.size

    progressHandler(1.0)
  }

  public func close() async throws {
    if let createResponse {
      try await session.close(fileId: createResponse.fileId)
    }
    createResponse = nil
  }

  private func fileProxy() async throws -> FileProxy {
    guard let createResponse else {
      let response = try await session.create(
        desiredAccess: [.genericRead],
        fileAttributes: [],
        shareAccess: [.read],
        createDisposition: .open,
        createOptions: [],
        name: path
      )
      createResponse = response
      return FileProxy(id: response.fileId, size: response.endOfFile)
    }

    return FileProxy(id: createResponse.fileId, size: createResponse.endOfFile)
  }
}

// RUMSKROT-HARDEN: a successful READ that returns no bytes before the end
// of the file would otherwise repeat forever.
private func requireProgress(_ response: Read.Response) throws {
  guard response.buffer.isEmpty, NTStatus(response.header.status) != .endOfFile else { return }
  throw ResponseDecodingError.invalidValue(field: "Read.dataLength", value: 0)
}

// RUMSKROT-HARDEN: an empty file is complete, not 0/0 = NaN.
private func fraction(_ done: UInt64, of total: UInt64) -> Double {
  guard total > 0 else { return 1.0 }
  return min(1.0, Double(done) / Double(total))
}
