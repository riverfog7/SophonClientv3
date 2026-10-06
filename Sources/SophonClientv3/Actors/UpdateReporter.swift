import Foundation
import Logging

public actor UpdateReporter: OperationReportingInternal {
  public typealias Event = UpdateEvent
  public typealias Progress = UpdateProgress

  internal let logger: Logger
  internal var progress = UpdateProgress()
  internal var subscribers: [UUID: AsyncStream<UpdateEvent>.Continuation] = [:]

  public init(logger: Logger) {
    self.logger = logger
  }

  public func record(_ event: UpdateEvent) {
    guard progress.outcome == nil else {
      return
    }

    switch event {
    case .planned(let source, let target, let patchBytes, let installBytes, let totalFiles):
      progress.sourceVersion = source
      progress.targetVersion = target
      progress.totalPatchBytes = patchBytes
      progress.totalInstallBytes = installBytes
      progress.totalFiles = totalFiles
      logger.info("Update planned", metadata: ["source": "\(source)", "target": "\(target)"])
    case .bundleDownloaded(let id, let bytes):
      progress.downloadedBytes += bytes
      logger.debug("Patch bundle ready", metadata: ["patch.id": "\(id)", "bytes": "\(bytes)"])
    case .fileNeedsRepair(let fileURL):
      progress.repairFiles += 1
      logger.info("Update target queued for repair", metadata: ["file": "\(fileURL.path)"])
    case .fileCompleted(let fileURL, let bytes, let skipped):
      progress.completedFiles += 1
      if skipped { progress.skippedFiles += 1 } else { progress.writtenBytes += bytes }
      logger.debug(
        "Update target complete", metadata: ["file": "\(fileURL.path)", "skipped": "\(skipped)"])
    case .fileDeleted(let fileURL, let bytes):
      progress.deletedBytes += bytes
      logger.debug("Removed obsolete file", metadata: ["file": "\(fileURL.path)"])
    case .phaseChanged(let phase):
      progress.phase = phase
    case .finished(let outcome):
      progress.outcome = outcome
      logger.info("Update finished", metadata: ["result": "\(String(describing: outcome))"])
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
