import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class ChunkCheckWorker: Sendable {
  private let baseGameDir: URL
  private let ioQueue: DispatchQueue

  init(baseGameDir: URL) {
    self.baseGameDir = baseGameDir
    self.ioQueue = DispatchQueue(
      label: "sophon.chunk-check", qos: .utility, attributes: .concurrent)
  }

  internal func run(
    _ fileInfo: FileInfo
  ) async throws -> GameFileState {
    try Task.checkCancellation()

    return try await withCheckedThrowingContinuation { continuation in
      ioQueue.async { [self] in
        continuation.resume(
          with: Result {
            try checkOnce(fileInfo)
          }
        )
      }
    }
  }

  private func checkChunk(_ chunkInfo: borrowing ChunkInfo, _ handle: FileHandle) throws -> Bool {
    let size = Int(chunkInfo.uncompressedSize)
    // seeking to greater offset than file size is permitted
    // it will just return nil as data
    try handle.seek(toOffset: chunkInfo.offset)
    let data = try handle.read(upToCount: size) ?? Data()
    let matches = data.count == size && md5Hex(data) == chunkInfo.md5

    return matches
  }

  private func checkOnce(_ fileInfo: borrowing FileInfo) throws -> GameFileState {
    let filePath = baseGameDir.appendingPathComponent(fileInfo.filename)
    guard let fileSize = UInt64(exactly: fileInfo.size) else {
      throw SophonClientError.UnknownError("Invalid file size: \(fileInfo.size)")
    }
    if fileInfo.flags == 64 {
      return GameFileState(
        filePath: filePath, needsTrimming: false, size: fileSize, md5: fileInfo.md5,
        requiredChunks: [])
    }

    let chunks = fileInfo.chunks.sorted { $0.offset < $1.offset }
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: filePath)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return GameFileState(
        filePath: filePath, needsTrimming: false, size: fileSize, md5: fileInfo.md5,
        requiredChunks: fileInfo.chunks)
    } catch {
      throw error
    }

    defer { try? handle.close() }

    let needsTrimming = try handle.seekToEnd() > fileSize
    var requiredChunks: [ChunkInfo] = []
    for chunk in chunks {
      if try !checkChunk(chunk, handle) {
        requiredChunks.append(chunk)
      }
    }

    return GameFileState(
      filePath: filePath, needsTrimming: needsTrimming, size: fileSize, md5: fileInfo.md5,
      requiredChunks: requiredChunks)
  }
}
