import Foundation

final class ChunkWriteWorker: @unchecked Sendable {
  private let ioQueue: DispatchQueue
  private var handles: [URL: FileHandle] = [:]

  init(index: Int) {
    self.ioQueue = DispatchQueue(
      label: "sophon.chunk-write.\(index)",
      qos: .utility
    )
  }

  internal func run(_ request: ChunkWriteRequest) async throws {
    try Task.checkCancellation()

    try await withCheckedThrowingContinuation({
      continuation in
      ioQueue.async {
        [self] in
        continuation.resume(
          with: Result {
            try write(request)
          })
      }
    })
  }

  private func getHandle(
    for fileURL: URL
  ) throws -> FileHandle {
    if let handle = handles[fileURL] {
      return handle
    }

    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if !FileManager.default.fileExists(atPath: fileURL.path) {
      guard
        FileManager.default.createFile(
          atPath: fileURL.path,
          contents: nil
        )
      else {
        throw SophonClientError.UnknownError(
          "Failed to create \(fileURL.path)"
        )
      }
    }

    // can do both read and write
    let handle = try FileHandle(forUpdating: fileURL)
    handles[fileURL] = handle
    return handle
  }

  internal func close(
    _ fileURL: URL
  ) async throws {
    let fileURL = fileURL.standardizedFileURL

    try await withCheckedThrowingContinuation { continuation in
      ioQueue.async { [self] in
        continuation.resume(
          with: Result {
            if let handle = handles.removeValue(forKey: fileURL) {
              try handle.close()
            }
          }
        )
      }
    }
  }

  internal func closeAll() async {
    await withCheckedContinuation { continuation in
      ioQueue.async { [self] in
        for handle in handles.values {
          try? handle.close()
        }

        handles.removeAll()
        continuation.resume()
      }
    }
  }

  private func write(_ request: ChunkWriteRequest) throws {
    let application = request.applicationInfo
    let fileURL = application.fileURL.standardizedFileURL
    let handle = try getHandle(for: fileURL)

    do {
      try handle.seek(toOffset: application.offset)
      try handle.write(contentsOf: request.data)
    } catch {
      if let handle = handles.removeValue(forKey: fileURL) {
        try? handle.close()
      }
      throw error
    }
  }
}
