import Foundation

public enum StorageIOPolicy: String, Codable, CaseIterable, Sendable {
  case parallel
  case serialized
}

public enum UpdateWriteMode: String, Codable, CaseIterable, Sendable {
  case temporaryReplacement = "temporary"
  case inPlace = "in-place"
}

public struct TransferSettings: Codable, Sendable {
  public var cacheDirectory: String?
  public var stateDirectory: String?
  public var memoryLimit: UInt64 = 500 * 1024 * 1024
  public var diskLimit: UInt64 = 10 * 1024 * 1024 * 1024
  public var entryLimit: Int = 500
  public var ioPolicy: StorageIOPolicy = .parallel
  public var writeMode: UpdateWriteMode = .temporaryReplacement
  public var preserveState = true

  public init() {}

  internal var cacheURL: URL {
    if let cacheDirectory { return URL(fileURLWithPath: cacheDirectory).standardizedFileURL }
    let root =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent("SophonClientv3/transfers", isDirectory: true)
  }

  internal var stateURL: URL {
    if let stateDirectory { return URL(fileURLWithPath: stateDirectory).standardizedFileURL }
    return cacheURL.appendingPathComponent("state", isDirectory: true)
  }

  private enum CodingKeys: String, CodingKey {
    case cacheDirectory, stateDirectory, memoryLimit, diskLimit, entryLimit
    case ioPolicy, writeMode, preserveState
  }

  public init(from decoder: any Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    cacheDirectory = try values.decodeIfPresent(String.self, forKey: .cacheDirectory)
    stateDirectory = try values.decodeIfPresent(String.self, forKey: .stateDirectory)
    memoryLimit = try values.decodeIfPresent(UInt64.self, forKey: .memoryLimit) ?? memoryLimit
    diskLimit = try values.decodeIfPresent(UInt64.self, forKey: .diskLimit) ?? diskLimit
    entryLimit = try values.decodeIfPresent(Int.self, forKey: .entryLimit) ?? entryLimit
    ioPolicy = try values.decodeIfPresent(StorageIOPolicy.self, forKey: .ioPolicy) ?? ioPolicy
    writeMode = try values.decodeIfPresent(UpdateWriteMode.self, forKey: .writeMode) ?? writeMode
    preserveState = try values.decodeIfPresent(Bool.self, forKey: .preserveState) ?? preserveState
  }
}
