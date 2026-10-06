import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct CachedDownload: Sendable {
  let fileURL: URL
  let size: UInt64
  // Protect the payload from eviction until the last consumer releases it.
  fileprivate let fileLock: TransferFileLock
}

private enum DownloadCacheError: Error {
  case rangeUnsupported
  case capacityBusy
}

actor DownloadCache {
  private let directory: URL
  private let diskLimit: UInt64
  private let maxRetries: Int
  private let retryInterval: Int
  private let http: RangeDownloadSession
  private let requests: WorkLimiter

  init(
    directory: URL, diskLimit: UInt64, maxConcurrentDownloads: Int,
    maxRetries: Int, retryInterval: Int, configuration: URLSessionConfiguration = .ephemeral
  ) {
    self.directory = directory
    self.diskLimit = diskLimit
    self.maxRetries = maxRetries
    self.retryInterval = retryInterval
    configuration.httpMaximumConnectionsPerHost = maxConcurrentDownloads
    configuration.urlCache = nil
    http = RangeDownloadSession(configuration: configuration)
    requests = WorkLimiter(limit: maxConcurrentDownloads)
  }

  deinit { http.invalidate() }

  // Decision checks do not fetch data or change the cache. Usage still verifies MD5.
  func contains(_ request: DownloadRequest) async throws -> Bool {
    let key = transferKey("\(request.md5.lowercased()):\(request.size)")
    let path = DownloadPaths(directory: directory, key: key).ready
    return try await runTransferIO {
      do {
        let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return size.flatMap(UInt64.init(exactly:)) == request.size
      } catch {
        if isMissingFile(error) { return false }
        throw error
      }
    }
  }

  func get(_ request: DownloadRequest, waitForSpace: Bool = true) async throws -> CachedDownload {
    try Task.checkCancellation()
    let key = transferKey("\(request.md5.lowercased()):\(request.size)")
    return try await fetch(request, key: key, waitForSpace: waitForSpace)
  }

  private func fetch(_ request: DownloadRequest, key: String, waitForSpace: Bool) async throws
    -> CachedDownload
  {
    guard request.size <= diskLimit, request.size <= UInt64(Int64.max) else {
      throw BinaryCacheError.entryTooLarge(request.size)
    }
    let paths = DownloadPaths(directory: directory, key: key)
    let (fileLock, readyExists) = try await acquirePayloadLock(paths)
    defer { withExtendedLifetime(fileLock) {} }

    // Another process can finish or evict the payload while this lock is acquired.
    if let digest = try await runTransferIO({ try digestFile(paths.ready) }),
      digest.size == request.size, digest.md5 == request.md5.lowercased()
    {
      try fileLock.makeShared()
      return CachedDownload(fileURL: paths.ready, size: request.size, fileLock: fileLock)
    }
    if readyExists {
      while true {
        do {
          try await runTransferIO { try fileLock.makeExclusive() }
          break
        } catch TransferLockError.busy {
          // A competing caller may repair the entry and keep it pinned for reading.
          do { try fileLock.makeShared() } catch TransferLockError.busy {
            try await Task.sleep(for: .milliseconds(20))
            continue
          }
          if let digest = try await runTransferIO({ try digestFile(paths.ready) }),
            digest.size == request.size, digest.md5 == request.md5.lowercased()
          {
            return CachedDownload(fileURL: paths.ready, size: request.size, fileLock: fileLock)
          }
          try await Task.sleep(for: .milliseconds(20))
        }
      }
      if let digest = try await runTransferIO({ try digestFile(paths.ready) }),
        digest.size == request.size, digest.md5 == request.md5.lowercased()
      {
        try fileLock.makeShared()
        return CachedDownload(fileURL: paths.ready, size: request.size, fileLock: fileLock)
      }
    }
    if FileManager.default.fileExists(atPath: paths.ready.path) {
      let budgetLock = try await acquireLock(directory.appendingPathComponent("budget.lock"))
      try await runTransferIO {
        try removeOwnedFile(paths.ready)
        try removeOwnedFile(paths.partial)
        try removeOwnedFile(paths.index)
        withExtendedLifetime(budgetLock) {}
      }
    }

    while true {
      do {
        try await reserveSpace(request.size, key: key, paths: paths)
        break
      } catch DownloadCacheError.capacityBusy {
        guard waitForSpace else {
          throw SophonClientError.UnknownError(
            "The download cache has insufficient unpinned space for the predownload")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
    }
    let context = try await runTransferIO { try DownloadContext(paths: paths, request: request) }
    defer { context.close() }
    var lastError: (any Error)?

    for attempt in 0...maxRetries {
      try Task.checkCancellation()
      do {
        if context.useWholeRequest {
          try await transferWhole(request, context: context)
        } else {
          do { try await transferRanges(request, context: context) } catch DownloadCacheError
            .rangeUnsupported
          {
            try await runTransferIO { try context.disableRanges() }
            try await transferWhole(request, context: context)
          }
        }
        let digest = try await runTransferIO { try digestFile(paths.partial) }
        guard digest?.size == request.size, digest?.md5 == request.md5.lowercased() else {
          try await runTransferIO { try context.reset() }
          throw SophonClientError.InvalidChecksumError(
            expected: request.md5, actual: digest?.md5 ?? "missing payload")
        }
        try await finish(context: context, paths: paths)
        try fileLock.makeShared()
        return CachedDownload(fileURL: paths.ready, size: request.size, fileLock: fileLock)
      } catch {
        try Task.checkCancellation()
        if let error = error as? SophonClientError,
          case .InvalidHTTPStatus(let code) = error,
          (400..<500).contains(code), code != 408, code != 429
        {
          throw error
        }
        lastError = error
        if attempt < maxRetries { try await Task.sleep(for: .seconds(retryInterval)) }
      }
    }
    throw lastError ?? SophonClientError.UnknownError("Download failed")
  }

  private func transferRanges(_ request: DownloadRequest, context: DownloadContext) async throws {
    let pending = context.pendingRanges()
    try await withThrowingTaskGroup(of: Void.self) { group in
      var next = 0
      func addNext() {
        guard next < pending.count else { return }
        let index = pending[next]
        next += 1
        group.addTask { [requests, http] in
          try await requests.withPermit {
            let transfer = RangeTransfer(request: request, context: context, index: index)
            try await transfer.run(http)
          }
        }
      }
      for _ in 0..<min(8, pending.count) { addNext() }
      do { while try await group.next() != nil { addNext() } } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  private func transferWhole(_ request: DownloadRequest, context: DownloadContext) async throws {
    guard request.size > 0 else { return }
    try await requests.withPermit { [http] in
      try await RangeTransfer(request: request, context: context, index: nil).run(http)
    }
  }

  private func acquireLock(_ path: URL, shared: Bool = false) async throws -> TransferFileLock {
    while true {
      do {
        return try await runTransferIO { try TransferFileLock(path, shared: shared) }
      } catch TransferLockError.busy { try await Task.sleep(for: .milliseconds(20)) }
    }
  }

  // Waiting callers can share a newly completed payload without waiting for its consumers.
  private func acquirePayloadLock(_ paths: DownloadPaths) async throws -> (TransferFileLock, Bool) {
    while true {
      let ready = FileManager.default.fileExists(atPath: paths.ready.path)
      do {
        return (try await runTransferIO { try TransferFileLock(paths.lock, shared: ready) }, ready)
      } catch TransferLockError.busy { try await Task.sleep(for: .milliseconds(20)) }
    }
  }

  private func reserveSpace(_ size: UInt64, key: String, paths: DownloadPaths) async throws {
    let budgetLock = try await acquireLock(directory.appendingPathComponent("budget.lock"))
    defer { withExtendedLifetime(budgetLock) {} }
    let directory = directory
    let diskLimit = diskLimit
    try await runTransferIO {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
      var used: UInt64 = 0
      var activeCapacity = false
      var candidates: [(URL, UInt64, Date)] = []
      for file in files where ["bin", "partial"].contains(file.pathExtension) {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let bytes = UInt64(values.fileSize ?? 0)
        used += bytes
        if file.pathExtension == "bin", file.deletingPathExtension().lastPathComponent != key {
          candidates.append((file, bytes, values.contentModificationDate ?? .distantPast))
        } else if file.pathExtension == "partial",
          file.deletingPathExtension().lastPathComponent != key
        {
          let path = file.deletingPathExtension().appendingPathExtension("lock")
          do {
            let lock = try TransferFileLock(path)
            withExtendedLifetime(lock) {}
          } catch TransferLockError.busy { activeCapacity = true }
        }
      }
      let existing = FileManager.default.fileExists(atPath: paths.partial.path)
      let required = existing ? 0 : size
      for candidate in candidates.sorted(by: { $0.2 < $1.2 }) where used > diskLimit - required {
        let key = candidate.0.deletingPathExtension().lastPathComponent
        let other = DownloadPaths(directory: directory, key: key)
        let lock: TransferFileLock
        do { lock = try TransferFileLock(other.lock) } catch TransferLockError.busy {
          activeCapacity = true
          continue
        }
        defer { withExtendedLifetime(lock) {} }
        try removeOwnedFile(candidate.0)
        try removeOwnedFile(other.index)
        used -= candidate.1
      }
      guard used <= diskLimit - required else {
        if activeCapacity { throw DownloadCacheError.capacityBusy }
        throw SophonClientError.UnknownError(
          "Download cache is full of active or partial downloads; increase its limit or resume them"
        )
      }
      if !existing {
        guard FileManager.default.createFile(atPath: paths.partial.path, contents: nil) else {
          throw SophonClientError.UnknownError("Cannot create \(paths.partial.path)")
        }
        let handle = try FileHandle(forUpdating: paths.partial)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
      }
    }
  }

  private func finish(context: DownloadContext, paths: DownloadPaths) async throws {
    let budgetLock = try await acquireLock(directory.appendingPathComponent("budget.lock"))
    defer { withExtendedLifetime(budgetLock) {} }
    try await runTransferIO(checkCancellation: false) {
      context.close()
      try FileManager.default.moveItem(at: paths.partial, to: paths.ready)
      // The ready payload is already verified; an old journal is no longer used.
      try? removeOwnedFile(paths.index)
    }
  }
}

private struct DownloadPaths: Sendable {
  let partial: URL
  let ready: URL
  let index: URL
  let lock: URL

  init(directory: URL, key: String) {
    partial = directory.appendingPathComponent(key + ".partial")
    ready = directory.appendingPathComponent(key + ".bin")
    index = directory.appendingPathComponent(key + ".jsonl")
    lock = directory.appendingPathComponent(key + ".lock")
  }
}

private final class DownloadContext: @unchecked Sendable {
  static let blockSize: UInt64 = 4 * 1024 * 1024
  private struct Record: Codable {
    var range: Int?
    var bytes: UInt64?
    var wholeRequest: Bool?
  }
  private let lock = NSLock()
  private let data: FileHandle
  private let index: FileHandle
  private let encoder = JSONEncoder()
  let size: UInt64
  private var prefixes: [UInt64]
  private var wholeRequest = false
  private var closed = false

  init(paths: DownloadPaths, request: DownloadRequest) throws {
    size = request.size
    prefixes = Array(
      repeating: 0, count: Int(size / Self.blockSize + (size % Self.blockSize == 0 ? 0 : 1)))
    data = try FileHandle(forUpdating: paths.partial)
    if !FileManager.default.fileExists(atPath: paths.index.path) {
      guard FileManager.default.createFile(atPath: paths.index.path, contents: nil) else {
        try? data.close()
        throw SophonClientError.UnknownError("Cannot create download progress journal")
      }
    }
    index = try FileHandle(forUpdating: paths.index)
    let saved = try Data(contentsOf: paths.index)
    var validLength = 0
    for line in saved.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
      let record = try JSONDecoder().decode(Record.self, from: Data(line))
      if let range = record.range, let bytes = record.bytes {
        guard prefixes.indices.contains(range), bytes <= length(of: range) else {
          throw SophonClientError.UnknownError("Invalid download progress journal")
        }
        prefixes[range] = bytes
      }
      if let whole = record.wholeRequest { wholeRequest = whole }
      validLength += line.count + 1
    }
    try index.truncate(atOffset: UInt64(validLength))
    try index.seekToEnd()
  }

  var useWholeRequest: Bool { lock.withLock { wholeRequest } }

  func length(of range: Int) -> UInt64 {
    min(Self.blockSize, size - UInt64(range) * Self.blockSize)
  }

  func pendingRanges() -> [Int] {
    lock.withLock { prefixes.indices.filter { prefixes[$0] < length(of: $0) } }
  }

  func start(of range: Int) -> UInt64 {
    lock.withLock { UInt64(range) * Self.blockSize + prefixes[range] }
  }

  func write(_ bytes: Data, at position: UInt64, allowExisting: Bool) throws {
    try lock.withLock {
      guard !closed, position <= size, UInt64(bytes.count) <= size - position else {
        throw BinaryCacheError.outOfBounds
      }
      var offset = position
      let end = position + UInt64(bytes.count)
      while offset < end {
        let range = Int(offset / Self.blockSize)
        let base = UInt64(range) * Self.blockSize
        let next = min(end, base + length(of: range))
        let savedEnd = base + prefixes[range]
        guard offset <= savedEnd, allowExisting || offset == savedEnd else {
          throw SophonClientError.UnknownError("Noncontiguous download range")
        }
        let writeFrom = max(offset, savedEnd)
        if writeFrom < next {
          let lower = Int(writeFrom - position)
          let upper = Int(next - position)
          try data.seek(toOffset: writeFrom)
          try data.write(contentsOf: bytes.subdata(in: lower..<upper))
          try append(Record(range: range, bytes: next - base))
          prefixes[range] = next - base
        }
        offset = next
      }
    }
  }

  func disableRanges() throws {
    try lock.withLock {
      try append(Record(wholeRequest: true))
      wholeRequest = true
    }
  }

  func reset() throws {
    try lock.withLock {
      try data.truncate(atOffset: 0)
      try data.truncate(atOffset: size)
      try index.truncate(atOffset: 0)
      try index.seek(toOffset: 0)
      prefixes = Array(repeating: 0, count: prefixes.count)
      if wholeRequest { try append(Record(wholeRequest: true)) }
    }
  }

  private func append(_ record: Record) throws {
    var bytes = try encoder.encode(record)
    bytes.append(10)
    let offset = try index.offset()
    do { try index.write(contentsOf: bytes) } catch {
      try? index.truncate(atOffset: offset)
      try? index.seek(toOffset: offset)
      throw error
    }
  }

  func close() {
    lock.withLock {
      if closed { return }
      closed = true
      try? data.close()
      try? index.close()
    }
  }

  deinit { close() }
}

private final class RangeTransfer: @unchecked Sendable {
  let request: URLRequest
  private let context: DownloadContext
  private let position: UInt64
  private let length: UInt64
  private let totalSize: UInt64
  private let whole: Bool
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var task: URLSessionDataTask?
  private var cancelled = false
  private var failure: (any Error)?
  private var received: UInt64 = 0

  init(request: DownloadRequest, context: DownloadContext, index: Int?) {
    self.context = context
    totalSize = request.size
    whole = index == nil
    let position = index.map { context.start(of: $0) } ?? 0
    self.position = position
    length =
      index.map {
        UInt64($0) * DownloadContext.blockSize + context.length(of: $0) - position
      } ?? request.size
    var urlRequest = URLRequest(url: request.url)
    urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
    urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if index != nil {
      urlRequest.setValue("bytes=\(position)-\(position + length - 1)", forHTTPHeaderField: "Range")
    }
    self.request = urlRequest
  }

  func run(_ session: RangeDownloadSession) async throws {
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = session.makeTask(self)
        let cancelled = lock.withLock {
          self.continuation = continuation
          self.task = task
          return self.cancelled
        }
        if cancelled { task.cancel() } else { task.resume() }
      }
    } onCancel: {
      cancel()
    }
  }

  func accept(_ response: URLResponse) -> Bool {
    do {
      guard let response = response as? HTTPURLResponse else {
        throw SophonClientError.InvalidHTTPResponse
      }
      if response.statusCode == 200 {
        guard whole || (position == 0 && length == totalSize) else {
          throw DownloadCacheError.rangeUnsupported
        }
      } else if response.statusCode == 206 {
        let value = response.value(forHTTPHeaderField: "Content-Range") ?? ""
        guard value == "bytes \(position)-\(position + length - 1)/\(totalSize)" else {
          throw SophonClientError.UnknownError("Invalid HTTP Content-Range: \(value)")
        }
      } else {
        throw SophonClientError.InvalidHTTPStatus(response.statusCode)
      }
      guard response.expectedContentLength < 0 || UInt64(response.expectedContentLength) == length
      else {
        throw SophonClientError.UnknownError("HTTP range length does not match the requested bytes")
      }
      return true
    } catch {
      lock.withLock { failure = error }
      return false
    }
  }

  func receive(_ data: Data) {
    guard lock.withLock({ failure == nil && !cancelled }) else { return }
    do {
      guard UInt64(data.count) <= length - received else { throw BinaryCacheError.outOfBounds }
      try context.write(data, at: position + received, allowExisting: whole)
      received += UInt64(data.count)
    } catch {
      lock.withLock { failure = error }
      lock.withLock { task }?.cancel()
    }
  }

  func complete(_ error: (any Error)?) {
    let state = lock.withLock {
      let continuation = continuation
      self.continuation = nil
      task = nil
      return (continuation, failure, cancelled)
    }
    guard let continuation = state.0 else { return }
    if state.2 {
      continuation.resume(throwing: CancellationError())
    } else if let error = state.1 ?? error {
      continuation.resume(throwing: error)
    } else if received != length {
      continuation.resume(
        throwing: SophonClientError.SizeMismatch(expected: length, actual: received))
    } else {
      continuation.resume()
    }
  }

  private func cancel() {
    let task = lock.withLock {
      cancelled = true
      return self.task
    }
    task?.cancel()
  }
}

private final class RangeDownloadSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var transfers: [Int: RangeTransfer] = [:]
  private var session: URLSession!

  init(configuration: URLSessionConfiguration) {
    super.init()
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }

  func makeTask(_ transfer: RangeTransfer) -> URLSessionDataTask {
    let task = session.dataTask(with: transfer.request)
    lock.withLock { transfers[task.taskIdentifier] = transfer }
    return task
  }

  func invalidate() { session.invalidateAndCancel() }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let transfer = lock.withLock { transfers[dataTask.taskIdentifier] }
    completionHandler(transfer?.accept(response) == true ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.withLock { transfers[dataTask.taskIdentifier] }?.receive(data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    lock.withLock { transfers.removeValue(forKey: task.taskIdentifier) }?.complete(error)
  }
}
