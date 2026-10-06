import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum UpdatePhase: String, Codable, Sendable {
  case metadata
  case predownloading
  case running
  case repairing
  case deleting
}

public enum UpdateOutcome: Codable, Sendable {
  case completed
  case failed(reason: String)
  case cancelled
}

public enum UpdateEvent: Sendable {
  case planned(
    sourceVersion: String, targetVersion: String, patchBytes: UInt64, installBytes: UInt64,
    totalFiles: Int)
  case bundleDownloaded(patchID: String, bytes: UInt64)
  case fileNeedsRepair(fileURL: URL)
  case fileCompleted(fileURL: URL, bytes: UInt64, skipped: Bool)
  case fileDeleted(fileURL: URL, bytes: UInt64)
  case phaseChanged(UpdatePhase)
  case finished(UpdateOutcome)
}

public struct UpdateProgress: BaseProgress, Codable {
  public internal(set) var phase: UpdatePhase = .metadata
  public internal(set) var outcome: UpdateOutcome?
  public internal(set) var sourceVersion: String?
  public internal(set) var targetVersion: String?
  public internal(set) var totalPatchBytes: UInt64 = 0
  public internal(set) var totalInstallBytes: UInt64 = 0
  public internal(set) var totalFiles: Int = 0
  public internal(set) var downloadedBytes: UInt64 = 0
  public internal(set) var completedFiles: Int = 0
  public internal(set) var skippedFiles: Int = 0
  public internal(set) var repairFiles: Int = 0
  public internal(set) var writtenBytes: UInt64 = 0
  public internal(set) var deletedBytes: UInt64 = 0
}
