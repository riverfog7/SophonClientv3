import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum InstallationPhase: String, Sendable {
  case metadata
  case scanning
  case trimming
  case running
}

public enum InstallationOutcome: Sendable {
  case completed
  case failed(reason: String)
  case cancelled
}

public enum InstallationEvent: Sendable {
  // metadata stage
  case metadataPlanned(totalManifests: Int)
  case manifestPulled(matchingField: String, predownload: Bool)

  // scanning stage
  case scanPlanned(totalFiles: Int, totalChunks: Int, totalBytes: UInt64)
  case fileMissing(filePath: URL, chunkCount: Int, expectedBytes: UInt64)
  case fileChunkScanned(
    filePath: URL, chunkID: String, isBroken: Bool, offset: UInt64, bytes: UInt64,
    expectedBytes: UInt64)
  case fileScanned(filePath: URL, isBroken: Bool, needsTrimming: Bool)
  case planned(downloadBytes: UInt64, writeBytes: UInt64, totalChunk: Int, totalFile: Int)

  // trimming stage
  case fileTrimmed(filePath: URL)

  // download stage
  case chunkDownloaded(chunkID: String, bytes: UInt64)
  case retryScheduled(chunkID: String, attempt: Int, reason: String)
  case chunkPostProcessed(chunkID: String, compressed_bytes: UInt64, uncompressed_bytes: UInt64)
  case chunkWritten(filePath: URL, chunkID: String, offset: UInt64, bytes: UInt64)
  case fileCompleted(filePath: URL)

  // installation phase related
  case phaseChanged(InstallationPhase)
  case finished(InstallationOutcome)
}

public struct InstallationProgress: Sendable {
  public internal(set) var phase: InstallationPhase = .metadata
  public internal(set) var totalDownloadBytes: UInt64?
  public internal(set) var totalWriteBytes: UInt64?
  public internal(set) var totalChunk: Int?
  public internal(set) var totalFile: Int?
  public internal(set) var downloadedBytes: UInt64 = 0
  public internal(set) var writtenBytes: UInt64 = 0
  public internal(set) var scannedFiles: Int = 0
  public internal(set) var completedFiles: Int = 0
  public internal(set) var completedChunks: Int = 0
  public internal(set) var outcome: InstallationOutcome?
}
