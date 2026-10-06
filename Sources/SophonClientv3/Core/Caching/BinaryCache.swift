// TODO: Un-vibecode this
import Foundation

enum BinaryCacheError: Error {
  case invalidConfiguration
  case entryTooLarge(UInt64)
  case outOfBounds
  case incomplete
  case closed
  case invalidBufferSize
  case unexpectedEndOfFile
}

actor BinaryCache {
  // The backing owns this reservation, including while slices or readers use it.
  final class Reservation: Sendable {
    private let cache: BinaryCache
    let size: UInt64
    let inMemory: Bool

    fileprivate init(cache: BinaryCache, size: UInt64, inMemory: Bool) {
      self.cache = cache
      self.size = size
      self.inMemory = inMemory
    }

    deinit {
      let cache = cache
      let size = size
      let inMemory = inMemory
      Task {
        await cache.release(size: size, inMemory: inMemory)
      }
    }
  }

  private struct Waiter {
    let id: UUID
    let size: UInt64
    let continuation: CheckedContinuation<Reservation, any Error>
  }

  private let directory: URL
  private let memoryLimit: UInt64
  private let diskLimit: UInt64
  private let entryLimit: Int
  private var memoryBytes: UInt64 = 0
  private var diskBytes: UInt64 = 0
  private var entryCount = 0
  private var waiters: [Waiter] = []

  init(directory: URL, memoryLimit: UInt64, diskLimit: UInt64, entryLimit: Int) throws {
    guard directory.isFileURL, entryLimit > 0 else {
      throw BinaryCacheError.invalidConfiguration
    }
    self.directory = directory
    self.memoryLimit = min(memoryLimit, UInt64(Int.max))
    self.diskLimit = min(diskLimit, UInt64(Int64.max))
    self.entryLimit = entryLimit
  }

  internal func makeWriter(expectedSize: UInt64) async throws -> CachedBinaryWriter {
    try Task.checkCancellation()
    guard expectedSize <= memoryLimit || expectedSize <= diskLimit else {
      throw BinaryCacheError.entryTooLarge(expectedSize)
    }

    let id = UUID()
    let reservation: Reservation = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters.append(Waiter(id: id, size: expectedSize, continuation: continuation))
        admitWaiters()
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }

    return try await CachedBinaryWriter.make(reservation: reservation, directory: directory)
  }

  private func admitWaiters() {
    while entryCount < entryLimit, let waiter = waiters.first {
      let inMemory: Bool
      if waiter.size <= memoryLimit - memoryBytes {
        inMemory = true
        memoryBytes += waiter.size
      } else if waiter.size <= diskLimit - diskBytes {
        inMemory = false
        diskBytes += waiter.size
      } else {
        return
      }

      entryCount += 1
      waiters.removeFirst()
      waiter.continuation.resume(
        returning: Reservation(cache: self, size: waiter.size, inMemory: inMemory)
      )
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
    admitWaiters()
  }

  private func release(size: UInt64, inMemory: Bool) {
    if inMemory {
      memoryBytes -= size
    } else {
      diskBytes -= size
    }
    entryCount -= 1
    admitWaiters()
  }
}
