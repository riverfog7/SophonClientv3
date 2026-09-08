import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum InstallationPhase: String, Sendable {
  case metadata
  case scanning
  case trimming
  case running
}

enum InstallationOutcome: Sendable {
  case completed
  case failed(reason: String)
  case cancelled
}

enum InstallationEvent: Sendable {
  // metadata stage
  case metadataPulled

  // scanning stage
  case fileMissing(filePath: URL)
  case fileChunkScanned(
    filePath: URL, chunkID: String, isBroken: Bool, offset: UInt64, bytes: UInt64)
  case fileScanned(filePath: URL, isBroken: Bool, needsTrimming: Bool)
  case planned(downloadBytes: UInt64, writeBytes: UInt64, totalChunk: Int, totalFile: Int)

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

struct InstallationProgress: Sendable {
  var phase: InstallationPhase = .metadata
  var totalDownloadBytes: UInt64?
  var totalWriteBytes: UInt64?
  var totalChunk: Int?
  var totalFile: Int?
  var downloadedBytes: UInt64 = 0
  var writtenBytes: UInt64 = 0
  var scannedFiles: Int = 0
  var completedFiles: Int = 0
  var completedChunks: Int = 0
  var outcome: InstallationOutcome?
}
