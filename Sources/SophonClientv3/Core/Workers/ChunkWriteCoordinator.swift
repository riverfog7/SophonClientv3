import AsyncAlgorithms
import Foundation

final class ChunkWriteCoordinator: Sendable {
  private let workers: [ChunkWriteWorker]
  private let tracker: FileCompletionTracker
  private let reporter: InstallationReporter?

  init(
    plannedFiles: [PlannedFile],
    workerCount: Int,
    maxCachedFileHandles: Int = 512,
    reporter: InstallationReporter? = nil
  ) throws {
    guard workerCount > 0 else {
      throw SophonClientError.UnknownError(
        "Write worker count must be positive"
      )
    }
    guard maxCachedFileHandles >= workerCount else {
      throw SophonClientError.UnknownError(
        "File handle cache budget must allow at least one handle per disk writer"
      )
    }
    self.workers = try (0..<workerCount).map {
      try ChunkWriteWorker(index: $0, maxCachedFileHandles: maxCachedFileHandles / workerCount)
    }
    self.tracker = try FileCompletionTracker(
      plannedFiles: plannedFiles
    )
    self.reporter = reporter
  }

  internal func write(
    _ chunk: ProcessedChunk
  ) async throws {
    for application in chunk.chunkApplicationInfos {
      try Task.checkCancellation()

      let worker = worker(for: application.fileURL)
      try await worker.run(
        ChunkWriteRequest(
          data: chunk.data,
          applicationInfo: application
        )
      )
      await reporter?.record(
        .chunkWritten(
          filePath: application.fileURL, chunkID: chunk.chunkID,
          offset: application.offset, bytes: UInt64(chunk.data.count)))

      if let completedFile = try await tracker.completeWrite(
        to: application.fileURL
      ) {
        try await worker.close(completedFile.fileURL)
        await reporter?.record(.fileCompleted(filePath: completedFile.fileURL))
      }
    }
  }

  internal func ensureComplete() async throws {
    try await tracker.ensureComplete()
  }

  internal func closeAll() async {
    for worker in workers {
      await worker.closeAll()
    }
  }

  private func worker(
    for fileURL: URL
  ) -> ChunkWriteWorker {
    let path = fileURL.standardizedFileURL.path
    let hash = UInt(bitPattern: path.hashValue)
    let index = Int(hash % UInt(workers.count))

    return workers[index]
  }

  internal func run(
    _ input: AsyncChannel<ProcessedChunk>
  ) async throws {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in workers.indices {
          group.addTask { [self] in
            for await chunk in input {
              try Task.checkCancellation()
              try await write(chunk)
            }
          }
        }

        do {
          while (try await group.next()) != nil {}
        } catch {
          group.cancelAll()
          throw error
        }
      }
    } catch {
      await closeAll()
      throw error
    }

    await closeAll()
  }
}
