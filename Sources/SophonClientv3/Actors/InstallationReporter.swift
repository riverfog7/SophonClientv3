import Foundation
import Logging

public actor InstallationReporter: OperationReportingInternal {
  public typealias Event = InstallationEvent
  public typealias Progress = InstallationProgress

  internal let logger: Logger
  internal var progress = InstallationProgress()
  internal var subscribers: [UUID: AsyncStream<InstallationEvent>.Continuation] = [:]

  public init(logger: Logger) {
    self.logger = logger
  }

  public func record(_ event: InstallationEvent) {
    guard progress.outcome == nil else {
      return
    }

    switch event {
    case .metadataPlanned(let totalManifests):
      logger.info(
        "Installation metadata planned", metadata: ["manifests.total": "\(totalManifests)"])

    case .manifestPulled(let matchingField, let predownload):
      logger.info(
        "Sophon manifest downloaded",
        metadata: [
          "matchingField": "\(matchingField)",
          "predownload": "\(predownload)",
        ]

      )

    case .scanPlanned(let totalFiles, let totalChunks, let totalBytes):
      logger.info(
        "Installation scan planned",
        metadata: [
          "files.total": "\(totalFiles)", "chunks.total": "\(totalChunks)",
          "scan.bytes": "\(totalBytes)",
        ])

    case .fileMissing(let filePath, let chunkCount, let expectedBytes):
      logger.debug(
        "File is missing",
        metadata: [
          "file.path": "\(filePath.absoluteURL.path)", "chunks.count": "\(chunkCount)",
          "expected.bytes": "\(expectedBytes)",
        ]
      )

    case .fileChunkScanned(
      let filePath,
      let chunkID,
      let isBroken,
      let offset,
      let bytes,
      let expectedBytes
    ):
      logger.log(
        level: .debug,
        "File chunk scanned",
        metadata: [
          "file.path": "\(filePath.absoluteURL.path)",
          "chunk.id": "\(chunkID)",
          "chunk.broken": "\(isBroken)",
          "chunk.offset": "\(offset)",
          "chunk.bytes": "\(bytes)",
          "chunk.expectedBytes": "\(expectedBytes)",
        ]
      )

    case .fileScanned(let filePath, let isBroken, let needsTrimming):
      progress.scannedFiles += 1

      logger.debug(
        "File scanned",
        metadata: [
          "file.path": "\(filePath.absoluteURL.path)",
          "file.broken": "\(isBroken)",
          "file.needsTrimming": "\(needsTrimming)",
        ]
      )

    case .fileTrimmed(let filePath):
      logger.debug("File trimmed", metadata: ["file.path": "\(filePath.absoluteURL.path)"])

    case .planned(
      let downloadBytes,
      let writeBytes,
      let totalChunk,
      let totalFile
    ):
      progress.totalDownloadBytes = downloadBytes
      progress.totalWriteBytes = writeBytes
      progress.totalChunk = totalChunk
      progress.totalFile = totalFile

      logger.info(
        "Installation planned",
        metadata: [
          "download.bytes": "\(downloadBytes)",
          "write.bytes": "\(writeBytes)",
          "chunks.total": "\(totalChunk)",
          "files.total": "\(totalFile)",
        ]
      )

    case .chunkDownloaded(let chunkID, let bytes):
      progress.downloadedBytes += bytes
      progress.completedChunks += 1

      logger.debug(
        "Chunk downloaded",
        metadata: [
          "chunk.id": "\(chunkID)",
          "download.bytes": "\(bytes)",
        ]
      )

    case .retryScheduled(let chunkID, let attempt, let reason):
      logger.warning(
        "Chunk download retry scheduled",
        metadata: [
          "chunk.id": "\(chunkID)",
          "attempt": "\(attempt)",
          "reason": "\(reason)",
        ]
      )

    case .chunkPostProcessed(
      let chunkID,
      let compressedBytes,
      let uncompressedBytes
    ):
      logger.debug(
        "Chunk post-processing completed",
        metadata: [
          "chunk.id": "\(chunkID)",
          "compressed.bytes": "\(compressedBytes)",
          "uncompressed.bytes": "\(uncompressedBytes)",
        ]
      )

    case .chunkWritten(let filePath, let chunkID, let offset, let bytes):
      progress.writtenBytes += bytes

      logger.debug(
        "Chunk written",
        metadata: [
          "file.path": "\(filePath.absoluteURL.path)",
          "chunk.id": "\(chunkID)",
          "chunk.offset": "\(offset)",
          "write.bytes": "\(bytes)",
        ]
      )

    case .fileCompleted(let filePath):
      progress.completedFiles += 1

      logger.debug(
        "File completed",
        metadata: ["file.path": "\(filePath.absoluteURL.path)"]
      )

    case .phaseChanged(let phase):
      progress.phase = phase

      logger.info(
        "Installation phase changed",
        metadata: ["phase": "\(phase.rawValue)"]
      )

    case .finished(let outcome):
      progress.outcome = outcome

      switch outcome {
      case .completed:
        logger.info(
          "Installation completed",
          metadata: [
            "download.bytes": "\(progress.downloadedBytes)",
            "write.bytes": "\(progress.writtenBytes)",
            "chunks.downloaded": "\(progress.completedChunks)",
            "files.completed": "\(progress.completedFiles)",
          ]
        )

      case .failed(let reason):
        logger.error(
          "Installation failed",
          metadata: ["reason": "\(reason)"]
        )

      case .cancelled:
        logger.info("Installation cancelled")
      }
    }

    for subscriber in subscribers.values {
      subscriber.yield(event)
    }

    if progress.outcome != nil {
      for subscriber in subscribers.values {
        subscriber.finish()
      }

      subscribers.removeAll()
    }
  }

  deinit {
    for subscriber in subscribers.values {
      subscriber.finish()
    }
  }
}
