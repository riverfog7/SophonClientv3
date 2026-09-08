import Foundation
import Logging

actor InstallationReporter: OperationReporting {
  private let logger: Logger
  private var progress = InstallationProgress()

  private var subscribers: [UUID: AsyncStream<InstallationEvent>.Continuation] = [:]

  init(logger: Logger) {
    self.logger = logger
  }

  func snapshot() -> InstallationProgress {
    progress
  }

  func subscribe() -> (
    id: UUID,
    progress: InstallationProgress,
    events: AsyncStream<InstallationEvent>
  ) {
    let id = UUID()
    let pair = AsyncStream<InstallationEvent>.makeStream(
      bufferingPolicy: .unbounded
    )

    if progress.outcome == nil {
      pair.continuation.onTermination = { [weak self] _ in
        Task {
          await self?.unsubscribe(id)
        }
      }

      subscribers[id] = pair.continuation
    } else {
      pair.continuation.finish()
    }

    return (id, progress, pair.stream)
  }

  func unsubscribe(_ id: UUID) {
    subscribers.removeValue(forKey: id)?.finish()
  }

  func record(_ event: InstallationEvent) {
    guard progress.outcome == nil else {
      return
    }

    switch event {
    case .metadataPulled:
      logger.info("Installation metadata loaded")

    case .fileMissing(let filePath):
      logger.debug(
        "File is missing",
        metadata: ["file.path": "\(filePath.absoluteURL.path)"]
      )

    case .fileChunkScanned(
      let filePath,
      let chunkID,
      let isBroken,
      let offset,
      let bytes
    ):
      logger.log(
        level: isBroken ? .warning : .debug,
        "File chunk scanned",
        metadata: [
          "file.path": "\(filePath.absoluteURL.path)",
          "chunk.id": "\(chunkID)",
          "chunk.broken": "\(isBroken)",
          "chunk.offset": "\(offset)",
          "chunk.bytes": "\(bytes)",
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
