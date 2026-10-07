import Foundation

// A single budget covers this operation's downloads, original inputs and processing buffers.
final class TransferWorkspace: Sendable {
  let directory: URL
  let cache: BinaryCache
  let telemetry: TransferTelemetry
  let transport: DownloadCache
  let io: WorkLimiter
  let settings: TransferSettings

  init(
    settings: TransferSettings, gameDirectory: URL, operation: String,
    transport: DownloadCache, io: WorkLimiter? = nil
  ) async throws {
    self.settings = settings
    self.transport = transport
    self.io = io ?? WorkLimiter(limit: Int.max)
    directory = settings.cacheURL.appendingPathComponent("working", isDirectory: true)
      .appendingPathComponent(transferKey(gameDirectory.path), isDirectory: true)
      .appendingPathComponent(operation, isDirectory: true)
    telemetry = TransferTelemetry(
      memoryLimit: settings.memoryLimit,
      diskLimit: settings.diskCacheEnabled ? settings.diskLimit : 0)
    telemetry.register(gameDirectory, role: "Target")
    telemetry.register(directory, role: "Cache")
    if !settings.preserveState {
      try await runTransferIO { [directory] in try removeOwnedFile(directory) }
    }
    cache = try BinaryCache(
      directory: directory.appendingPathComponent("inputs", isDirectory: true),
      memoryLimit: settings.memoryLimit,
      diskLimit: settings.diskCacheEnabled ? settings.diskLimit : 0,
      entryLimit: settings.entryLimit, telemetry: telemetry)
  }

  func download(
    _ request: DownloadRequest,
    purpose: BinaryCache.Purpose = .download(memoryHeadroom: 0, diskHeadroom: 0),
    category: String = "patch"
  ) async throws -> CachedBinary {
    try await transport.getWorking(
      request, directory: directory.appendingPathComponent("downloads", isDirectory: true),
      cache: cache, purpose: purpose, telemetry: telemetry, io: io, category: category)
  }

  func retainedBytes(_ request: DownloadRequest) async throws -> UInt64 {
    try await transport.retainedBytes(
      request, directory: directory.appendingPathComponent("downloads", isDirectory: true))
  }

  func consumed(_ binary: CachedBinary, request: DownloadRequest) async throws {
    try await runTransferIO(checkCancellation: false) {
      try binary.removeFile()
      let key = transferKey("\(request.md5.lowercased()):\(request.size)")
      try removeOwnedFile(self.directory.appendingPathComponent("downloads/\(key).partial"))
      try removeOwnedFile(self.directory.appendingPathComponent("downloads/\(key).jsonl"))
    }
  }

  func finish(completed: Bool) async throws {
    await cache.waitUntilUnused()
    if completed {
      try await runTransferIO(checkCancellation: false) { [directory] in
        try removeOwnedFile(directory)
      }
    }
  }
}
