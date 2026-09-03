import AsyncAlgorithms
import Foundation

final class ChunkWriteCoordinator: Sendable {
  private let workers: [ChunkWriteWorker]
  private let tracker: FileCompletionTracker

  init(
    plannedFiles: [PlannedFile],
    workerCount: Int
  ) throws {
    guard workerCount > 0 else {
      throw SophonClientError.UnknownError(
        "Write worker count must be positive"
      )
    }
    self.workers = (0..<workerCount).map {
      ChunkWriteWorker(index: $0)
    }
    self.tracker = try FileCompletionTracker(
      plannedFiles: plannedFiles
    )
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

      if let completedFile = try await tracker.completeWrite(
        to: application.fileURL
      ) {
        try await worker.close(completedFile.fileURL)
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
