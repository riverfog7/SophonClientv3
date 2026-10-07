import Foundation
import HYPAPIClient
import Testing

@testable import SophonClientv3

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

func getTestDataPath() -> URL {
  return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".testData")
}

private struct HDiffFixture: Decodable {
  let old: Data
  let new: Data
  let patch: Data
}

private func loadHDiffFixture() throws -> HDiffFixture {
  let fixtureURL = try #require(
    Bundle.module.url(forResource: "HDiffFixture", withExtension: "json", subdirectory: "Fixtures"))
  return try JSONDecoder().decode(HDiffFixture.self, from: Data(contentsOf: fixtureURL))
}

@Test(arguments: [UInt64(0), UInt64(500 * 1024)])
func testStreamedPatchWithCachedInputs(memoryLimit: UInt64) async throws {
  let fixture = try loadHDiffFixture()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let cache = try BinaryCache(
    directory: root.appendingPathComponent("cache"), memoryLimit: memoryLimit,
    diskLimit: 2 * 1024 * 1024, entryLimit: 4)
  let originalWriter = try await cache.makeWriter(expectedSize: UInt64(fixture.old.count))
  try await originalWriter.write(fixture.old, at: 0)
  let original = try await originalWriter.finish()
  let bundle = Data(repeating: 0xCC, count: 17) + fixture.patch + Data([0xFF])
  let patchWriter = try await cache.makeWriter(expectedSize: UInt64(bundle.count))
  try await patchWriter.write(bundle, at: 0)
  let patchBundle = try await patchWriter.finish()
  let patch = try patchBundle.slice(offset: 17, length: UInt64(fixture.patch.count))
  let targetURL = root.appendingPathComponent("target.bin")
  try fixture.old.write(to: targetURL)
  let temporary = root.appendingPathComponent("output.bin")
  let target = PlannedUpdateFile(
    fileURL: targetURL, size: UInt64(fixture.new.count), md5: md5Hex(fixture.new), installChunks: []
  )
  let worker = PatchApplyWorker(index: 0)
  try await worker.run(
    PatchApplyRequest(
      original: .cached(original), patch: .cached(patch), target: target, outputURL: temporary))
  #expect(try Data(contentsOf: temporary) == fixture.new)
  #expect(try Data(contentsOf: targetURL) == fixture.old)

  let invalidTarget = PlannedUpdateFile(
    fileURL: targetURL, size: target.size, md5: String(repeating: "0", count: 32), installChunks: []
  )
  await #expect(throws: SophonClientError.self) {
    try await worker.run(
      PatchApplyRequest(
        original: .cached(original), patch: .cached(patch), target: invalidTarget,
        outputURL: temporary))
  }
  #expect(try Data(contentsOf: targetURL) == fixture.old)
}

@Test(arguments: [UInt64(0), UInt64(16)])
func testTransferCacheBudgets(memoryLimit: UInt64) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let lockURL = root.appendingPathComponent("contended.lock")
  let lock = try TransferFileLock(lockURL)
  for _ in 0..<3 {
    #expect(throws: TransferLockError.self) { _ = try TransferFileLock(lockURL) }
  }
  withExtendedLifetime(lock) {}
  let cache = try BinaryCache(
    directory: root, memoryLimit: memoryLimit, diskLimit: 16, entryLimit: 2)
  let first = try await cache.makeWriter(expectedSize: 16)
  let usage = await cache.usage
  #expect(usage.memory == memoryLimit)
  #expect(usage.disk == (memoryLimit == 0 ? 16 : 0))
  #expect(usage.entries == 1)
  await #expect(throws: BinaryCacheError.self) { _ = try await cache.makeWriter(expectedSize: 17) }
  // Full pools wait, and a cancelled waiter must not consume bytes or an entry.
  if memoryLimit == 0 {
    let waiting = Task { try await cache.makeWriter(expectedSize: 1) }
    try await Task.sleep(for: .milliseconds(20))
    waiting.cancel()
    await #expect(throws: CancellationError.self) { _ = try await waiting.value }
  } else {
    let second = try await cache.makeWriter(expectedSize: 16)
    let both = await cache.usage
    #expect(both.memory == 16 && both.disk == 16 && both.entries == 2)
    try await second.abort()
  }
  try await first.abort()
  for _ in 0..<100 {
    if await cache.usage.entries == 0 { break }
    try await Task.sleep(for: .milliseconds(1))
  }
  let released = await cache.usage
  #expect(released.memory == 0 && released.disk == 0 && released.entries == 0)
}

private final class TransferHTTPFixture: @unchecked Sendable {
  struct Reply {
    let data: Data
    let headers: [String: String]
    let status: Int
    let fail: Bool
  }

  let data: Data
  private let lock = NSLock()
  private var failurePrefix: Int?
  private let ignoreRanges: Bool
  private let invalidRange: Bool
  private let observe: @Sendable () -> Bool
  private var requests: [String?] = []
  private var observations: [Bool] = []

  init(
    _ data: Data, failurePrefix: Int? = nil, ignoreRanges: Bool = false,
    invalidRange: Bool = false, observe: @escaping @Sendable () -> Bool = { true }
  ) {
    self.data = data
    self.failurePrefix = failurePrefix
    self.ignoreRanges = ignoreRanges
    self.invalidRange = invalidRange
    self.observe = observe
  }

  var ranges: [String?] { lock.withLock { requests } }
  var observed: [Bool] { lock.withLock { observations } }

  func reply(_ request: URLRequest) -> Reply {
    lock.withLock {
      let range = request.value(forHTTPHeaderField: "Range")
      requests.append(range)
      observations.append(observe())
      let parts = range?.dropFirst(6).split(separator: "-")
      let start = !ignoreRanges ? parts.flatMap { Int($0[0]) } ?? 0 : 0
      let end = !ignoreRanges ? parts.flatMap { Int($0[1]) } ?? (data.count - 1) : data.count - 1
      let full = range == nil || ignoreRanges
      let bytes = data.subdata(in: start..<(end + 1))
      let headers =
        full
        ? ["Content-Length": String(data.count)]
        : [
          "Content-Length": String(bytes.count),
          "Content-Range": "bytes \(start)-\(end)/\(data.count + (invalidRange ? 1 : 0))",
        ]
      if let prefix = failurePrefix {
        failurePrefix = nil
        return Reply(
          data: Data(bytes.prefix(prefix)), headers: headers, status: full ? 200 : 206, fail: true)
      }
      return Reply(data: bytes, headers: headers, status: full ? 200 : 206, fail: false)
    }
  }
}

private final class TransferURLProtocol: URLProtocol {
  private final class Registry: @unchecked Sendable {
    let lock = NSLock()
    var entries: [URL: TransferHTTPFixture] = [:]
  }
  private static let registry = Registry()

  static func register(_ fixture: TransferHTTPFixture, at url: URL) {
    registry.lock.withLock { registry.entries[url] = fixture }
  }

  static func remove(_ url: URL) {
    _ = registry.lock.withLock { registry.entries.removeValue(forKey: url) }
  }
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "transfer.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url,
      let fixture = Self.registry.lock.withLock({ Self.registry.entries[url] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let reply = fixture.reply(request)
    let response = HTTPURLResponse(
      url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.data)
    if reply.fail {
      client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    } else {
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}

private func transferTestCache(_ directory: URL, diskLimit: UInt64 = 16 * 1024 * 1024)
  -> DownloadCache
{
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [TransferURLProtocol.self]
  return DownloadCache(
    directory: directory, diskLimit: diskLimit, maxConcurrentDownloads: 1,
    maxRetries: 0, retryInterval: 0, configuration: configuration)
}

@Test(arguments: [
  "resume", "ignored-ranges", "invalid-range", "capacity", "tampered", "shrink", "shared-budget",
])
func testTransferDownloadRecovery(scenario: String) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let bytes = Data(
    repeating: 0xA7, count: scenario == "ignored-ranges" ? 5 * 1024 * 1024 : 256 * 1024)
  let url = URL(string: "https://transfer.invalid/\(UUID().uuidString)")!
  let fixture = TransferHTTPFixture(
    bytes,
    ignoreRanges: scenario == "ignored-ranges", invalidRange: scenario == "invalid-range")
  TransferURLProtocol.register(fixture, at: url)
  defer { TransferURLProtocol.remove(url) }
  let request = DownloadRequest(
    chunkID: "test", url: url, md5: md5Hex(bytes), size: UInt64(bytes.count))

  if scenario == "resume" {
    // Darwin can discard buffered URLProtocol data when didFail follows didLoad synchronously.
    // Seed the persisted prefix to test restart independently of that delivery behavior.
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let key = transferKey("\(request.md5):\(request.size)")
    let partial = root.appendingPathComponent(key + ".partial")
    try Data(bytes.prefix(8192)).write(to: partial)
    let handle = try FileHandle(forUpdating: partial)
    try handle.truncate(atOffset: request.size)
    try handle.close()
    try Data("{\"range\":0,\"bytes\":8192}\n{\"range\":".utf8)
      .write(to: root.appendingPathComponent(key + ".jsonl"))
  }
  let cache = transferTestCache(
    root, diskLimit: scenario == "capacity" ? request.size : 16 * 1024 * 1024)
  if scenario == "invalid-range" {
    await #expect(throws: (any Error).self) { _ = try await cache.get(request) }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
        !$0.hasSuffix(".bin")
      })
    return
  }
  var downloaded: CachedDownload? = try await cache.get(request)
  #expect(try Data(contentsOf: #require(downloaded).fileURL) == bytes)
  let payloadURL = try #require(downloaded).fileURL
  let metadata = try transferFileMetadata(payloadURL.path)
  let attributes = try FileManager.default.attributesOfItem(atPath: payloadURL.path)
  let modified = try #require(attributes[.modificationDate] as? Date)
  #expect(metadata.size == request.size)
  #expect(abs(metadata.modified.timeIntervalSince(modified)) < 0.000001)
  if scenario == "resume" { #expect(fixture.ranges.contains("bytes=8192-\(bytes.count - 1)")) }
  if scenario == "ignored-ranges" { #expect(fixture.ranges.contains(nil)) }
  if scenario == "tampered" {
    let path = try #require(downloaded).fileURL
    downloaded = nil
    try Data(repeating: 0, count: bytes.count).write(to: path)
    async let first = cache.get(request)
    async let second = cache.get(request)
    let (verified, shared) = try await (first, second)
    #expect(try Data(contentsOf: verified.fileURL) == bytes)
    #expect(shared.fileURL == verified.fileURL)
    #expect(fixture.ranges.count == 2)
  }
  if scenario == "shared-budget" {
    downloaded = nil
    let firstCache = transferTestCache(root, diskLimit: request.size * 2)
    do { _ = try await firstCache.get(request) }
    let secondURL = url.appendingPathComponent("second")
    let thirdURL = url.appendingPathComponent("third")
    let secondBytes = Data(repeating: 0xB8, count: bytes.count)
    let thirdBytes = Data(repeating: 0xC9, count: bytes.count)
    TransferURLProtocol.register(TransferHTTPFixture(secondBytes), at: secondURL)
    TransferURLProtocol.register(TransferHTTPFixture(thirdBytes), at: thirdURL)
    defer {
      TransferURLProtocol.remove(secondURL)
      TransferURLProtocol.remove(thirdURL)
    }
    let secondRequest = DownloadRequest(
      chunkID: "second", url: secondURL, md5: md5Hex(secondBytes), size: request.size)
    let thirdRequest = DownloadRequest(
      chunkID: "third", url: thirdURL, md5: md5Hex(thirdBytes), size: request.size)
    let secondCache = transferTestCache(root, diskLimit: request.size * 2)
    do { _ = try await secondCache.get(secondRequest) }
    let third = try await firstCache.get(thirdRequest)
    #expect(try Data(contentsOf: third.fileURL) == thirdBytes)
    var used: UInt64 = 0
    for name in try FileManager.default.contentsOfDirectory(atPath: root.path)
    where name.hasSuffix(".bin") || name.hasSuffix(".partial") {
      used += try transferFileMetadata(root.appendingPathComponent(name).path).size
    }
    #expect(used == request.size * 2)
  }
  if scenario == "shrink" {
    let nextURL = url.appendingPathComponent("second")
    let nextBytes = Data(repeating: 0xB8, count: bytes.count)
    let nextFixture = TransferHTTPFixture(nextBytes)
    TransferURLProtocol.register(nextFixture, at: nextURL)
    defer { TransferURLProtocol.remove(nextURL) }
    let nextRequest = DownloadRequest(
      chunkID: "second", url: nextURL, md5: md5Hex(nextBytes), size: request.size)
    downloaded = nil
    do {
      let next = try await cache.get(nextRequest)
      #expect(try Data(contentsOf: next.fileURL) == nextBytes)
    }
    let smaller = transferTestCache(root, diskLimit: request.size)
    let next = try await smaller.get(nextRequest)
    #expect(try Data(contentsOf: next.fileURL) == nextBytes)
    let cached = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.hasSuffix(".bin") || $0.hasSuffix(".partial") }
    #expect(cached.count == 1)
  }
  if scenario == "capacity" {
    let nextURL = url.appendingPathComponent("second")
    let nextBytes = Data(repeating: 0xB8, count: bytes.count)
    let nextFixture = TransferHTTPFixture(nextBytes)
    TransferURLProtocol.register(nextFixture, at: nextURL)
    defer { TransferURLProtocol.remove(nextURL) }
    let nextRequest = DownloadRequest(
      chunkID: "second", url: nextURL, md5: md5Hex(nextBytes), size: request.size)
    let waiting = Task { try await cache.get(nextRequest) }
    try await Task.sleep(for: .milliseconds(30))
    #expect(nextFixture.ranges.isEmpty)
    waiting.cancel()
    await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    downloaded = nil
    let next = try await cache.get(nextRequest)
    #expect(try Data(contentsOf: next.fileURL) == nextBytes)
  }
}

private func transferTestPlan(
  root: URL, fixture: HDiffFixture, bundleID: String = "bundle"
) throws -> UpdatePlan {
  let targetURL = root.appendingPathComponent("target.bin")
  let info = try JSONDecoder().decode(
    SophonDownloadInfo.self,
    from: JSONSerialization.data(withJSONObject: [
      "encryption": 0, "compression": 0, "password": "",
      "url_prefix": "https://transfer.invalid/\(root.lastPathComponent)", "url_suffix": "",
    ]))
  let chunk = RequiredChunk(
    chunkID: "install", uncompressedMd5: md5Hex(fixture.new), compressedMd5: md5Hex(fixture.new),
    compressedSize: UInt64(fixture.new.count), uncompressedSize: UInt64(fixture.new.count),
    downloadInfo: info,
    chunkApplicationInfos: [ChunkApplicationInfo(fileURL: targetURL, offset: 0)])
  let target = PlannedUpdateFile(
    fileURL: targetURL, size: UInt64(fixture.new.count), md5: md5Hex(fixture.new),
    installChunks: [chunk])
  let patch = PlannedPatch(
    patchOffset: 0, patchLength: UInt64(fixture.patch.count),
    original: PlannedPatchSource(
      fileURL: targetURL, size: UInt64(fixture.old.count), md5: md5Hex(fixture.old)), target: target
  )
  return UpdatePlan(
    sourceVersion: "old", targetVersion: "new",
    patchBundles: [
      PlannedPatchBundle(
        patchID: bundleID, patchSize: UInt64(fixture.patch.count), patchHash: md5Hex(fixture.patch),
        downloadInfo: info, patches: [patch])
    ],
    installFiles: [target],
    deleteFiles: [PlannedDeleteFile(fileURL: root.appendingPathComponent("obsolete"), size: 4)])
}

@Test(arguments: [UpdateWriteMode.temporaryReplacement, .inPlace], [false, true])
func testTransferPredownloadAndRepair(writeMode: UpdateWriteMode, rawPayload: Bool) async throws {
  let hdiff = try loadHDiffFixture()
  let fixture = HDiffFixture(
    old: hdiff.old, new: hdiff.new, patch: rawPayload ? hdiff.new : hdiff.patch)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  var settings = try JSONDecoder().decode(TransferSettings.self, from: Data("{}".utf8))
  #expect(settings.ioPolicy == nil)
  settings.cacheDirectory = root.appendingPathComponent("cache").path
  settings.memoryLimit = 0
  settings.writeMode = writeMode
  let plan = try transferTestPlan(root: root, fixture: fixture)
  let target = try #require(plan.installFiles.first)
  let deletion = try #require(plan.deleteFiles.first)
  try fixture.old.write(to: target.fileURL)
  try Data("gone".utf8).write(to: deletion.fileURL)
  let bundleURL = try #require(plan.patchBundles.first).downloadRequest().url
  let installURL = try #require(target.installChunks.first).getDownloadURL()
  let bundleFixture = TransferHTTPFixture(fixture.patch)
  let installFixture = TransferHTTPFixture(
    fixture.new, observe: { FileManager.default.fileExists(atPath: deletion.fileURL.path) })
  TransferURLProtocol.register(bundleFixture, at: bundleURL)
  TransferURLProtocol.register(installFixture, at: installURL)
  defer {
    TransferURLProtocol.remove(bundleURL)
    TransferURLProtocol.remove(installURL)
  }
  let cache = transferTestCache(settings.cacheURL.appendingPathComponent("downloads"))
  let updater = try Updater(baseGameDir: root, maxCocurrentDownloads: 2, maxCocurrentWrites: 2)
  let installer = try Installer(
    baseGameDir: root, maxCocurrentChecks: 1, maxCocurrentDownloads: 2,
    maxCocurrentPostProcessors: 2,
    maxCocurrentWrites: 2, downloadCache: cache)
  try await updater.execute(
    plan, settings: settings, downloadCache: cache, installer: installer,
    reporter: UpdateReporter(logger: .init(label: "test")), cacheOnly: true)
  #expect(try Data(contentsOf: target.fileURL) == fixture.old)
  #expect(FileManager.default.fileExists(atPath: deletion.fileURL.path))
  #expect(bundleFixture.ranges.count == 1)
  let patched = UpdateReporter(logger: .init(label: "test"))
  try await updater.execute(
    plan, settings: settings, downloadCache: cache, installer: installer, reporter: patched)
  #expect(try Data(contentsOf: target.fileURL) == fixture.new)
  #expect(bundleFixture.ranges.count == 1)
  #expect(installFixture.ranges.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: deletion.fileURL.path))
  #expect(try await SophonClientv3.savedUpdateState(at: root, settings: settings)?.finished == true)

  // Only the updated target falls back to installation when its source is broken.
  try Data(repeating: 0x00, count: fixture.old.count).write(to: target.fileURL)
  try Data("gone".utf8).write(to: deletion.fileURL)
  let cachedRepair = UpdateReporter(logger: .init(label: "test"))
  try await updater.execute(
    plan, settings: settings, downloadCache: cache, installer: installer, reporter: cachedRepair,
    cacheOnly: true)
  #expect(try Data(contentsOf: target.fileURL) == Data(repeating: 0x00, count: fixture.old.count))
  #expect(FileManager.default.fileExists(atPath: deletion.fileURL.path))
  let cacheState = try #require(
    try await SophonClientv3.savedUpdateState(at: root, settings: settings))
  #expect(cacheState.cacheOnly)
  #expect(cacheState.files[target.fileURL.path] == (rawPayload ? .cachedPatch : .cachedRepair))
  let repaired = UpdateReporter(logger: .init(label: "test"))
  try await updater.execute(
    plan, settings: settings, downloadCache: cache, installer: installer, reporter: repaired)
  #expect(try Data(contentsOf: target.fileURL) == fixture.new)
  #expect(await repaired.snapshot().repairFiles == (rawPayload ? 0 : 1))
  #expect(installFixture.observed == (rawPayload ? [] : [true]))
  #expect(!FileManager.default.fileExists(atPath: deletion.fileURL.path))

  let skipped = UpdateReporter(logger: .init(label: "test"))
  try await updater.execute(
    plan, settings: settings, downloadCache: cache, installer: installer, reporter: skipped)
  #expect(await skipped.snapshot().skippedFiles == 1)
  #expect(bundleFixture.ranges.count == 1)
}

@Test(arguments: ["in-place", "old-renamed", "new-ready", "committed", "checkpointed"])
func testTransferInterruptedUpdate(scenario: String) async throws {
  let fixture = try loadHDiffFixture()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  var settings = TransferSettings()
  settings.cacheDirectory = root.appendingPathComponent("cache").path
  settings.writeMode = scenario == "in-place" ? .inPlace : .temporaryReplacement
  let plan = try transferTestPlan(root: root, fixture: fixture)
  let patch = try #require(plan.patchBundles.first?.patches.first)
  let source = try #require(patch.original)
  let stateDirectory = UpdateJournal.directory(settings: settings, gameDirectory: root)
  do {
    let journal = try UpdateJournal(directory: stateDirectory, plan: plan)
    try journal.record(
      patch.target.fileURL, stage: scenario == "checkpointed" ? .completed : .writing)
  }
  let events = try FileHandle(forWritingTo: stateDirectory.appendingPathComponent("events.jsonl"))
  try events.seekToEnd()
  try events.write(contentsOf: Data("{\"path\":".utf8))
  try events.close()
  let key = transferKey(patch.target.fileURL.path + patch.target.md5).prefix(32)
  let temporary = root.appendingPathComponent(".sophon-\(key).new")
  let backup = root.appendingPathComponent(".sophon-\(key).old")
  let bundleURL = try #require(plan.patchBundles.first).downloadRequest().url
  let bundleFixture = TransferHTTPFixture(fixture.patch)
  TransferURLProtocol.register(bundleFixture, at: bundleURL)
  defer { TransferURLProtocol.remove(bundleURL) }
  let cache = transferTestCache(settings.cacheURL.appendingPathComponent("downloads"))
  if scenario == "in-place" {
    let original = settings.cacheURL.appendingPathComponent("originals/\(transferKey(root.path))")
      .appendingPathComponent(
        transferKey("\(source.fileURL.path):\(source.size):\(source.md5)") + ".original")
    try FileManager.default.createDirectory(
      at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fixture.old.write(to: original)
    try Data(repeating: 0xE1, count: fixture.new.count / 2).write(to: patch.target.fileURL)
    _ = try await cache.get(#require(plan.patchBundles.first).downloadRequest())
  } else if scenario == "old-renamed" {
    try fixture.old.write(to: backup)
    try fixture.new.write(to: temporary)
  } else if scenario == "new-ready" {
    try fixture.old.write(to: patch.target.fileURL)
    try fixture.new.write(to: temporary)
  } else if scenario == "checkpointed" {
    // Completion receipts are authoritative; detecting external changes is a separate verification run.
    try Data(repeating: 0xF2, count: fixture.new.count).write(to: patch.target.fileURL)
  } else {
    try fixture.new.write(to: patch.target.fileURL)
    try fixture.old.write(to: backup)
  }
  let updater = try Updater(baseGameDir: root, maxCocurrentDownloads: 1, maxCocurrentWrites: 1)
  let installer = try Installer(
    baseGameDir: root, maxCocurrentChecks: 1, maxCocurrentDownloads: 1,
    maxCocurrentPostProcessors: 1,
    maxCocurrentWrites: 1, downloadCache: cache)
  try await updater.execute(
    plan, settings: settings, downloadCache: cache, installer: installer,
    reporter: UpdateReporter(logger: .init(label: "test")))
  let expected =
    scenario == "checkpointed" ? Data(repeating: 0xF2, count: fixture.new.count) : fixture.new
  #expect(try Data(contentsOf: patch.target.fileURL) == expected)
  #expect(!FileManager.default.fileExists(atPath: backup.path))
  #expect(!FileManager.default.fileExists(atPath: temporary.path))
  #expect(bundleFixture.ranges.count == (scenario == "in-place" ? 1 : 0))
  #expect(try await SophonClientv3.savedUpdateState(at: root, settings: settings)?.finished == true)
}

@Test
func testTransferInstallationCheckpoints() async throws {
  let bytes = Data("verified chunk".utf8)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = HDiffFixture(old: Data(), new: bytes, patch: bytes)
  let update = try transferTestPlan(root: root, fixture: source)
  var chunk = try #require(update.installFiles.first?.installChunks.first)
  let first = try #require(chunk.chunkApplicationInfos.first)
  let second = ChunkApplicationInfo(fileURL: first.fileURL, offset: UInt64(bytes.count))
  chunk.chunkApplicationInfos = [first, second]
  let file = PlannedFile(
    fileURL: first.fileURL, size: UInt64(bytes.count * 2), md5: md5Hex(bytes + bytes),
    requiredChunkCount: 2, needsTrimming: false)
  let plan = InstallationPlan(
    totalChunkCount: 1, downloadSize: UInt64(bytes.count), diskWriteSize: file.size,
    requiredChunks: [chunk], plannedFiles: [file])
  var settings = TransferSettings()
  settings.cacheDirectory = root.appendingPathComponent("cache").path
  let directory = InstallationJournal.directory(settings: settings, gameDirectory: root)
  let initial = SavedInstallationState(
    gameID: "fixture", version: "1", mode: .full, voicePacks: [], predownload: false,
    plan: plan, completedApplications: [], trimmedFiles: [], finished: false)
  try bytes.write(to: first.fileURL)
  do {
    let journal = try InstallationJournal(directory: directory, state: initial)
    try journal.written(chunkID: chunk.chunkID, application: first)
  }
  let events = try FileHandle(forWritingTo: directory.appendingPathComponent("events.jsonl"))
  try events.seekToEnd()
  try events.write(contentsOf: Data("{\"application\":".utf8))
  try events.close()
  let saved = try #require(
    try await SophonClientv3.savedInstallationState(at: root, settings: settings))
  let remaining = saved.remainingPlan()
  #expect(remaining.requiredChunks.first?.chunkApplicationInfos.map(\.offset) == [second.offset])
  #expect(remaining.diskWriteSize == UInt64(bytes.count))
  let url = try chunk.getDownloadURL()
  let fixture = TransferHTTPFixture(bytes)
  TransferURLProtocol.register(fixture, at: url)
  defer { TransferURLProtocol.remove(url) }
  let cache = transferTestCache(settings.cacheURL.appendingPathComponent("downloads"))
  let installer = try Installer(
    baseGameDir: root, maxCocurrentChecks: 1, maxCocurrentDownloads: 1,
    maxCocurrentPostProcessors: 1,
    maxCocurrentWrites: 1, downloadCache: cache)
  let journal = try InstallationJournal(directory: directory, state: saved, resume: true)
  let reporter = InstallationReporter(logger: .init(label: "test"))
  try await installer.install(remaining, reporter: reporter, journal: journal)
  try journal.complete()
  #expect(try Data(contentsOf: first.fileURL) == bytes + bytes)
  #expect(await reporter.snapshot().scannedFiles == 0)
  #expect(await reporter.snapshot().writtenBytes == UInt64(bytes.count))
  let completed = try #require(
    try await SophonClientv3.savedInstallationState(at: root, settings: settings))
  #expect(completed.remainingPlan().requiredChunks.isEmpty)
  #expect(completed.finished)
}

@Test
func testTransferVersionAndActionDecision() throws {
  func branch(_ version: String, from: [String]) throws -> GameSubBranch {
    try JSONDecoder().decode(
      GameSubBranch.self,
      from: JSONSerialization.data(withJSONObject: [
        "package_id": "fixture", "branch": "fixture", "password": "", "tag": version,
        "diff_tags": from, "categories": [],
      ]))
  }
  let records = try JSONDecoder().decode(
    GameScanInfos.self,
    from: JSONSerialization.data(withJSONObject: [
      "game_scan_info": [
        [
          "game_id": "fixture",
          "game_exe_list": [
            ["version": "1", "md5": "shared"], ["version": "2", "md5": "shared"],
            ["version": "3", "md5": "new"],
          ],
        ],
        ["game_id": "other", "game_exe_list": [["version": "wrong-game", "md5": "new"]]],
      ]
    ]))
  #expect(
    resolveInstalledVersion(md5: "NEW", gameID: "fixture", records: records, completedVersion: nil)
      .version == "3")
  #expect(
    resolveInstalledVersion(
      md5: "shared", gameID: "fixture", records: records, completedVersion: nil
    ).version == nil)
  #expect(
    resolveInstalledVersion(
      md5: "shared", gameID: "fixture", records: records, completedVersion: "2"
    ).version == "2")
  let live = try branch("2", from: ["1"])
  let future = try branch("3", from: ["2"])
  let older = InstalledVersion(version: "1", executableMD5: nil, candidates: ["1"])
  let current = InstalledVersion(version: "2", executableMD5: nil, candidates: ["2"])
  let ahead = InstalledVersion(version: "3", executableMD5: nil, candidates: ["3"])
  #expect(
    decideGameAction(
      installed: older, live: live, future: future, installation: nil, update: nil,
      futureCached: false, supportsPatches: true
    ).action == .update)
  #expect(
    decideGameAction(
      installed: current, live: live, future: future, installation: nil, update: nil,
      futureCached: false, supportsPatches: true
    ).action == .cacheUpdate)
  #expect(
    decideGameAction(
      installed: current, live: live, future: future, installation: nil, update: nil,
      futureCached: true, supportsPatches: true
    ).action == .none)
  #expect(
    decideGameAction(
      installed: ahead, live: live, future: future, installation: nil, update: nil,
      futureCached: false, supportsPatches: true
    ).action == .none)
  // ZZZ advertises diff tags even though its launch config disables incremental patches.
  #expect(
    decideGameAction(
      installed: older, live: live, future: future, installation: nil, update: nil,
      futureCached: false, supportsPatches: false
    ).action == .install)
  #expect(
    decideGameAction(
      installed: current, live: live, future: future, installation: nil, update: nil,
      futureCached: false, supportsPatches: false
    ).action == .none)
  let installedPacks = ["en-us", "ko-kr"]
  for version in [
    older, current, ahead, InstalledVersion(version: nil, executableMD5: nil, candidates: []),
  ] {
    let action = decideGameAction(
      installed: version, live: live, future: future, installation: nil, update: nil,
      futureCached: false, supportsPatches: true, voicePacks: installedPacks)
    #expect(action.voicePacks == installedPacks)
  }
  let installation = SavedInstallationState(
    gameID: "fixture", version: "2", mode: .full, voicePacks: ["ja-jp"], predownload: false,
    plan: InstallationPlan(
      totalChunkCount: 0, downloadSize: 0, diskWriteSize: 0, requiredChunks: [], plannedFiles: []),
    completedApplications: [], trimmedFiles: [], finished: false)
  let installAction = decideGameAction(
    installed: older, live: live, future: future, installation: installation, update: nil,
    futureCached: false, supportsPatches: true, voicePacks: installedPacks)
  #expect(installAction.voicePacks == ["en-us", "ja-jp", "ko-kr"])
  let plan = UpdatePlan(
    sourceVersion: "1", targetVersion: "2", patchBundles: [], installFiles: [], deleteFiles: [])
  let writing = SavedUpdateState(
    gameID: "fixture", mode: .full, predownload: false, cacheOnly: false, plan: plan, files: [:],
    finished: false)
  // A partially updated executable cannot hide unfinished file work.
  #expect(
    decideGameAction(
      installed: current, live: live, future: future, installation: nil, update: writing,
      futureCached: false, supportsPatches: true
    ).action == .resumeUpdate)
  let liveCache = SavedUpdateState(
    gameID: "fixture", mode: .full, predownload: false, cacheOnly: true, plan: plan, files: [:],
    finished: false)
  let resumeCache = decideGameAction(
    installed: older, live: live, future: future, installation: nil, update: liveCache,
    futureCached: false, supportsPatches: true)
  #expect(resumeCache.action == .resumeUpdate)
  #expect(resumeCache.cacheOnly)
  let obsolete = try branch("3", from: ["2"])
  #expect(
    decideGameAction(
      installed: current, live: obsolete, future: nil, installation: nil, update: writing,
      futureCached: false, supportsPatches: true
    ).action == .install)
  let cachePlan = UpdatePlan(
    sourceVersion: "2", targetVersion: "3", patchBundles: [], installFiles: [], deleteFiles: [])
  let caching = SavedUpdateState(
    gameID: "fixture", mode: .full, predownload: true, cacheOnly: true, plan: cachePlan, files: [:],
    finished: false)
  #expect(
    decideGameAction(
      installed: current, live: live, future: future, installation: nil, update: caching,
      futureCached: false, supportsPatches: true
    ).cacheOnly)
}

private final class TransferRPCProcess: @unchecked Sendable {
  let process = Process()
  let input = Pipe()
  let output = Pipe()

  init(_ arguments: [String]) throws {
    process.executableURL = getTestDataPath().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/SophonCLI")
    process.arguments = ["rpc"] + arguments
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
  }

  func send(_ line: String) throws {
    try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
  }

  func read() throws -> Data {
    var bytes = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
      if byte.first == 10 { return bytes }
      bytes.append(byte)
      if bytes.count > 1024 * 1024 { break }
    }
    throw SophonClientError.UnknownError("RPC output ended before a complete message")
  }

  func stop() {
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
  }

  deinit {
    stop()
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
  }
}

@Test(arguments: ["stdio", "http"])
func testTransferRPCTransports(transport: String) async throws {
  let child = try TransferRPCProcess(
    transport == "http" ? ["--transport", "http", "--token", "fixture-token"] : [])
  let timeout = Task {
    do {
      try await Task.sleep(for: .seconds(10))
      child.stop()
    } catch {}
  }
  defer {
    timeout.cancel()
    child.stop()
  }
  if transport == "stdio" {
    try child.send("{\"jsonrpc\":\"2.0\",\"method\":\"rpc.discover\"}")
    try child.send("{\"jsonrpc\":\"2.0\",\"id\":18446744073709551615,\"method\":\"rpc.discover\"}")
    let response =
      try JSONSerialization.jsonObject(with: await runTransferIO { try child.read() })
      as? [String: Any]
    #expect((response?["id"] as? NSNumber)?.uint64Value == UInt64.max)
    #expect((response?["result"] as? [String: Any])?["methods"] is [String])
    try child.send("{")
    let invalid =
      try JSONSerialization.jsonObject(with: await runTransferIO { try child.read() })
      as? [String: Any]
    #expect((invalid?["error"] as? [String: Any])?["code"] as? Int == -32700)
    try child.send(
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"state.inspect\",\"params\":{\"directory\":\"/nonexistent-sophon-rpc-fixture\"}}"
    )
    let state =
      try JSONSerialization.jsonObject(with: await runTransferIO { try child.read() })
      as? [String: Any]
    #expect(state?["result"] is NSNull)
    child.process.interrupt()
  } else {
    let listening =
      try JSONSerialization.jsonObject(with: await runTransferIO { try child.read() })
      as? [String: Any]
    let urlString = try #require((listening?["params"] as? [String: Any])?["url"] as? String)
    let url = try #require(URL(string: urlString))
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"rpc.discover\"}".utf8)
    let (_, rejected) = try await URLSession.shared.data(for: request)
    #expect((rejected as? HTTPURLResponse)?.statusCode == 401)
    request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(result?["id"] as? Int == 1)
    request.httpBody = Data("{\"jsonrpc\":\"2.0\",\"method\":\"rpc.discover\"}".utf8)
    let (notification, acknowledged) = try await URLSession.shared.data(for: request)
    #expect((acknowledged as? HTTPURLResponse)?.statusCode == 204)
    #expect(notification.isEmpty)
    request.httpBody = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"rpc.shutdown\"}".utf8)
    let (shutdown, _) = try await URLSession.shared.data(for: request)
    #expect(
      (try JSONSerialization.jsonObject(with: shutdown) as? [String: Any])?["result"] as? Bool
        == true)
  }
  try await runTransferIO { child.process.waitUntilExit() }
  #expect(child.process.terminationStatus == 0)
}

func testManifestContents(_ manifest: Manifest) {
  for fileInfo in manifest.files {
    for chunkInfo in fileInfo.chunks {
      #expect(chunkInfo.chunkID.count > 0, "chunk ID should exist")
      #expect(chunkInfo.md5.count > 0, "chunk uncompressed md5 should exist")
      #expect(chunkInfo.compressedSize > 0, "chunk compressed size should be positive")
      #expect(chunkInfo.uncompressedSize > 0, "chunk uncompressed size should be positive")
      #expect(chunkInfo.compressedMd5.count > 0, "chunk compressed md5 should exist")
      #expect(
        UInt64(chunkInfo.uncompressedSize) + chunkInfo.offset <= UInt64(fileInfo.size),
        "chunk should be within file")
    }
  }
}

func testDiffManifestContents(_ manifest: DiffManifest) {
  for fileInfo in manifest.files {
    #expect(fileInfo.filename.count > 0, "file name should exist")
    #expect(fileInfo.size >= 0, "file size should not be negative")
    #expect(fileInfo.hash.count > 0, "file hash should exist")
    let sourceVersions = fileInfo.patches.map(\.key)
    #expect(
      Set(sourceVersions).count == sourceVersions.count,
      "file \(fileInfo.filename) should have at most one patch per source version")
    for patch in fileInfo.patches {
      #expect(patch.key.count > 0, "patch source version should exist")
      #expect(patch.hasInfo, "patch info should exist")
      #expect(patch.info.patchOffset >= 0, "patch offset should not be negative")
      #expect(patch.info.patchLength >= 0, "patch length should not be negative")
      #expect(
        patch.info.patchOffset + patch.info.patchLength <= patch.info.patchSize,
        "patch should be within the diff file")
    }
  }

  for deleteFile in manifest.filesDelete {
    #expect(deleteFile.key.count > 0, "delete source version should exist")
    #expect(deleteFile.hasInfo, "delete info should exist")
    for fileInfo in deleteFile.info.list {
      #expect(fileInfo.filename.count > 0, "delete file name should exist")
      #expect(fileInfo.size >= 0, "delete file size should not be negative")
      #expect(fileInfo.hash.count > 0, "delete file hash should exist")
    }
  }
}

func printUpdatePlanSummary(_ plan: UpdatePlan, gameID: String) {
  let patches = plan.patchBundles.flatMap(\.patches)
  let patchesWithSource = patches.filter { $0.original != nil }.count

  print(
    """
    update plan for \(gameID) from \(plan.sourceVersion):
      patch bundle files: \(plan.patchBundles.count)
      total bundle target files: \(patches.count)
      files to patch using an original: \(patchesWithSource)
      files supplied by bundles without an original: \(patches.count - patchesWithSource)
      files to delete: \(plan.deleteFiles.count)
      total file size to delete: \(Double(plan.deleteSize) / 1_073_741_824) GiB
      total patch bundle download size: \(Double(plan.patchSize) / 1_073_741_824) GiB
      total updated file size: \(Double(plan.installSize) / 1_073_741_824) GiB
    """)
}

func testDiffManifestParse(
  baseURL: String, sophonBaseURL: String, launcherID: String, gameList: [String]
) async throws {
  let cacheDir = getTestDataPath().appendingPathComponent("manifestCache")
  for gameID in gameList {
    let manager = try await CachedManifestManager(
      baseURL: baseURL, sophonBaseURL: sophonBaseURL, launcherID: launcherID,
      gameID: gameID, manifestCacheDir: cacheDir.path())
    let subBranch = try manager.getGameSubbranch(predownload: false)
    let patchBuildInfo = try await manager.apiClient.getSophonPatchBuildInfo(subBranch)
    #expect(patchBuildInfo.manifests.count > 0, "patch manifests should exist")
    let categories =
      subBranch.getGameBranchCategories(
        categoryScenario: .full, categoryType: .resource)
      + subBranch.getGameBranchCategories(categoryScenario: .full, categoryType: .audio)
    let matchingFields = Set(categories.map(\.matchingField))
    var installInfos: [(manifest: Manifest, chunkDownloadInfo: SophonDownloadInfo)] = []
    var updateInfos: [(manifest: DiffManifest, diffDownloadInfo: SophonDownloadInfo)] = []

    for manifestInfo in patchBuildInfo.manifests {
      let (manifest, diffDownloadInfo) = try await manager.getSophonPatchManifest(
        matchingField: manifestInfo.matchingField)
      #expect(
        manifest.files.count > 0 || manifest.filesDelete.count > 0,
        "manifest with matching field \(manifestInfo.matchingField) should not be empty")
      #expect(diffDownloadInfo.urlPrefix == manifestInfo.diffDownload.urlPrefix)
      #expect(diffDownloadInfo.urlSuffix == manifestInfo.diffDownload.urlSuffix)
      testDiffManifestContents(manifest)

      if matchingFields.contains(manifestInfo.matchingField) {
        installInfos.append(
          try await manager.getSophonManifest(matchingField: manifestInfo.matchingField))
        updateInfos.append((manifest, diffDownloadInfo))
      }
    }

    #expect(updateInfos.count > 0, "selected update manifests should exist")
    let baseGameDir = getTestDataPath().appendingPathComponent("updatePlan")
    let updater = try Updater(
      baseGameDir: baseGameDir, maxCocurrentDownloads: 8, maxCocurrentWrites: 4)
    var installFilesByPath: [String: (file: FileInfo, downloadInfo: SophonDownloadInfo)] = [:]
    for info in installInfos {
      for file in info.manifest.files where file.flags == FILE_FLAG_FILE {
        let path = baseGameDir.appendingPathComponent(file.filename).path.lowercased()
        installFilesByPath[path] = (file, info.chunkDownloadInfo)
      }
    }
    let retainedPaths = Set(installFilesByPath.keys)
    for sourceVersion in subBranch.diffTags {
      let plan = try updater.makePlan(
        sourceVersion: sourceVersion, installInfos: installInfos, updateInfos: updateInfos)
      var expectedPatchesByPath: [String: (info: PatchInfo, downloadInfo: SophonDownloadInfo)] = [:]
      for info in updateInfos {
        for file in info.manifest.files {
          if let patch = file.patches.first(where: { $0.key == sourceVersion }) {
            let path = baseGameDir.appendingPathComponent(file.filename).path.lowercased()
            expectedPatchesByPath[path] = (patch.info, info.diffDownloadInfo)
          }
        }
      }
      let expectedUpdatedPaths = Set(expectedPatchesByPath.keys)
      let plannedFiles = plan.patchBundles.flatMap { $0.patches.map(\.target) }
      #expect(plan.sourceVersion == sourceVersion)
      #expect(plannedFiles.count == expectedUpdatedPaths.count)
      #expect(Set(plannedFiles.map { $0.fileURL.path.lowercased() }) == expectedUpdatedPaths)
      for plannedFile in plan.installFiles + plannedFiles {
        let path = plannedFile.fileURL.path.lowercased()
        let target = try #require(installFilesByPath[path])
        #expect(plannedFile.fileURL == baseGameDir.appendingPathComponent(target.file.filename))
        #expect(plannedFile.size == UInt64(target.file.size))
        #expect(plannedFile.md5 == target.file.md5)
        #expect(plannedFile.installChunks.count == target.file.chunks.count)
        for (plannedChunk, chunk) in zip(plannedFile.installChunks, target.file.chunks) {
          #expect(plannedChunk.chunkID == chunk.chunkID)
          #expect(plannedChunk.uncompressedMd5 == chunk.md5)
          #expect(plannedChunk.compressedMd5 == chunk.compressedMd5)
          #expect(plannedChunk.compressedSize == UInt64(chunk.compressedSize))
          #expect(plannedChunk.uncompressedSize == UInt64(chunk.uncompressedSize))
          #expect(plannedChunk.downloadInfo.urlPrefix == target.downloadInfo.urlPrefix)
          #expect(plannedChunk.downloadInfo.urlSuffix == target.downloadInfo.urlSuffix)
          #expect(plannedChunk.downloadInfo.compression == target.downloadInfo.compression)
          #expect(plannedChunk.downloadInfo.encryption == target.downloadInfo.encryption)
          #expect(plannedChunk.downloadInfo.password == target.downloadInfo.password)
          #expect(plannedChunk.chunkApplicationInfos.count == 1)
          let application = try #require(plannedChunk.chunkApplicationInfos.first)
          #expect(application.fileURL == plannedFile.fileURL)
          #expect(application.offset == chunk.offset)
        }
      }

      #expect(plan.installFiles.count == expectedUpdatedPaths.count)
      #expect(
        Set(plan.installFiles.map { $0.fileURL.path.lowercased() }) == expectedUpdatedPaths)
      let expectedPatchIDs = Set(expectedPatchesByPath.values.map { $0.info.patchID })
      #expect(plan.patchBundles.count == expectedPatchIDs.count)
      #expect(Set(plan.patchBundles.map(\.patchID)) == expectedPatchIDs)
      for bundle in plan.patchBundles {
        #expect(bundle.patches.count > 0)
        let offsets = bundle.patches.map(\.patchOffset)
        #expect(offsets == offsets.sorted())
        for patch in bundle.patches {
          let expectedPatch = try #require(
            expectedPatchesByPath[patch.target.fileURL.path.lowercased()])
          #expect(bundle.patchID == expectedPatch.info.patchID)
          #expect(bundle.patchSize == UInt64(expectedPatch.info.patchSize))
          #expect(bundle.patchHash == expectedPatch.info.patchName)
          #expect(patch.patchOffset == UInt64(expectedPatch.info.patchOffset))
          #expect(patch.patchLength == UInt64(expectedPatch.info.patchLength))
          if expectedPatch.info.originalName.isEmpty {
            #expect(patch.original == nil)
          } else {
            let original = try #require(patch.original)
            #expect(
              original.fileURL
                == baseGameDir.appendingPathComponent(expectedPatch.info.originalName))
            #expect(original.size == UInt64(expectedPatch.info.originalSize))
            #expect(original.md5 == expectedPatch.info.originalHash)
          }
          #expect(bundle.downloadInfo.urlPrefix == expectedPatch.downloadInfo.urlPrefix)
          #expect(bundle.downloadInfo.urlSuffix == expectedPatch.downloadInfo.urlSuffix)
          #expect(bundle.downloadInfo.compression == expectedPatch.downloadInfo.compression)
          #expect(bundle.downloadInfo.encryption == expectedPatch.downloadInfo.encryption)
          #expect(bundle.downloadInfo.password == expectedPatch.downloadInfo.password)
        }
      }

      var expectedDeleteSizes: [String: UInt64] = [:]
      for deletion in updateInfos.flatMap({ $0.manifest.filesDelete })
      where deletion.key == sourceVersion {
        for file in deletion.info.list {
          let path = baseGameDir.appendingPathComponent(file.filename).path.lowercased()
          if !retainedPaths.contains(path) {
            expectedDeleteSizes[path] = UInt64(file.size)
          }
        }
      }
      let expectedDeletePaths = Set(expectedDeleteSizes.keys)
      #expect(plan.deleteFiles.count == expectedDeletePaths.count)
      #expect(Set(plan.deleteFiles.map { $0.fileURL.path.lowercased() }) == expectedDeletePaths)
      for file in plan.deleteFiles {
        let expectedSize = try #require(expectedDeleteSizes[file.fileURL.path.lowercased()])
        #expect(file.size == expectedSize)
      }
      #expect(plan.deleteSize == expectedDeleteSizes.values.reduce(UInt64(0), +))
      printUpdatePlanSummary(plan, gameID: gameID)
    }
  }
}

func testManifestParse(
  baseURL: String, sophonBaseURL: String, launcherID: String, gameList: [String]
) async throws {
  let cacheDir = getTestDataPath().appendingPathComponent("manifestCache")
  let installerTempDir = getTestDataPath().appendingPathComponent(
    "installerTemp-\(UUID().uuidString)")
  for gameID in gameList {
    let settings = SophonClientSettings(
      baseURL: baseURL, sophonBaseURL: sophonBaseURL,
      launcherID: launcherID, gameID: gameID,
      manifestCacheDir: cacheDir.path())
    let client = try await SophonClientv3(settings, baseGameDir: installerTempDir)
    let subBranch = try client.manifestManager.getGameSubbranch(predownload: false)

    let fullResourceCategory = subBranch.getGameBranchCategories(
      categoryScenario: GameBranchCategoryScenario.full,
      categoryType: GameBranchCategoryType.resource)
    let fullAudioCategory = subBranch.getGameBranchCategories(
      categoryScenario: GameBranchCategoryScenario.full, categoryType: GameBranchCategoryType.audio)

    for resource in fullAudioCategory {
      #expect(
        !fullResourceCategory.contains(where: { $0.matchingField == resource.matchingField }),
        "audio category and resource category must not overlap")
    }

    var installInfos: [(manifest: Manifest, chunkDownloadInfo: SophonDownloadInfo)] = []
    for matchingField in (fullResourceCategory + fullAudioCategory).map({ $0.matchingField }) {
      let (manifest, chunkDownloadInfo) = try await client.manifestManager.getSophonManifest(
        matchingField: matchingField)
      installInfos.append((manifest, chunkDownloadInfo))
      #expect(
        manifest.files.count > 0,
        "manifest with matching field \(matchingField) should not have no files")
      testManifestContents(manifest)

      if FileManager.default.fileExists(atPath: installerTempDir.path()) {
        try FileManager.default.removeItem(at: installerTempDir)
      }
      try FileManager.default.createDirectory(
        at: installerTempDir, withIntermediateDirectories: true)
    }
    try checkManifests(installInfos.map { $0.manifest })

    let installer = try Installer(
      baseGameDir: installerTempDir, maxCocurrentChecks: 8, maxCocurrentDownloads: 8,
      maxCocurrentPostProcessors: 8, maxCocurrentWrites: 8)
    let installationPlan = try await installer.scan(installInfos: installInfos)
    print("total chunk count for \(gameID): \(installationPlan.totalChunkCount)")
    print(
      "download size for \(gameID): \(Double(installationPlan.downloadSize) / 1_073_741_824) GiB")
    print(
      "disk write size for \(gameID): \(Double(installationPlan.diskWriteSize) / 1_073_741_824) GiB"
    )
  }
  try? FileManager.default.removeItem(at: installerTempDir)
}

@Test
func testOSManifestParse() async throws {
  try await testManifestParse(
    baseURL: HYPAPI_OS_BASE_URL, sophonBaseURL: SOPHON_API_OS_BASE_URL,
    launcherID: HYPAPI_OS_LAUNCHER_ID,
    gameList: [
      "U5hbdsT9W7",
      "4ziysqXOQ8",
      "gopR6Cufr3",
      "5TIVvvcwtM",
      "g0mMIvshDb",
      "uxB4MC7nzC",
      "bxPTXSET5t",
      "wkE5P5WsIf",
    ])
}

@Test
func testCNManifestParse() async throws {
  try await testManifestParse(
    baseURL: HYPAPI_CN_BASE_URL, sophonBaseURL: SOPHON_API_CN_BASE_URL,
    launcherID: HYPAPI_CN_LAUNCHER_ID,
    gameList: [
      "x6znKlJ0xK",
      "64kMb5iAWu",
      "1Z8W5NHUQb",
      "osvnlOc0S8",
    ])
}

@Test
func testOSDiffManifestParse() async throws {
  try await testDiffManifestParse(
    baseURL: HYPAPI_OS_BASE_URL, sophonBaseURL: SOPHON_API_OS_BASE_URL,
    launcherID: HYPAPI_OS_LAUNCHER_ID,
    gameList: [
      "U5hbdsT9W7",
      "4ziysqXOQ8",
      "gopR6Cufr3",
    ])
}

@Test
func testCNDiffManifestParse() async throws {
  try await testDiffManifestParse(
    baseURL: HYPAPI_CN_BASE_URL, sophonBaseURL: SOPHON_API_CN_BASE_URL,
    launcherID: HYPAPI_CN_LAUNCHER_ID,
    gameList: [
      "x6znKlJ0xK",
      "64kMb5iAWu",
      "1Z8W5NHUQb",
    ])
}
