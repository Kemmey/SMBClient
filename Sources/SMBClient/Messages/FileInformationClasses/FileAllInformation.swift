import Foundation

public struct FileAllInformation {
  public let basicInformation: FileBasicInformation
  public let standardInformation: FileStandardInformation
  public let internalInformation: FileInternalInformation
  public let eaInformation: FileEaInformation
  public let accessInformation: FileAccessInformation
  public let positionInformation: FilePositionInformation
  public let modeInformation: FileModeInformation
  public let alignmentInformation: FileAlignmentInformation
  public let nameInformation: FileNameInformation

  public init(data: Data) throws {
    let reader = ByteReader(data)

    basicInformation = try reader.read()
    standardInformation = try reader.read()
    internalInformation = try reader.read()
    eaInformation = try reader.read()
    accessInformation = try reader.read()
    positionInformation = try reader.read()
    modeInformation = try reader.read()
    alignmentInformation = try reader.read()
    nameInformation = try reader.read()
  }
}
