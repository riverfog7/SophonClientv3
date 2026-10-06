import Crypto
import Foundation

struct OriginalSnapshot: Sendable {
  let input: PatchInput?
  let observed: FileDigest?
  let fromSavedOriginal: Bool
}

actor OriginalSnapshots {
  private let cache: BinaryCache
  private let directory: URL
  private let diskLimit: UInt64
  private let io: WorkLimiter
  private let targets: [URL: PlannedUpdateFile]
  private let durableSources: Set<URL>
  private let sharedSources: Set<URL>
  private let cacheOnly: Bool
  private var references: [String: Int]
  private var tasks: [String: Task<OriginalSnapshot, any Error>] = [:]
  private var diskSizes: [String: UInt64]

  init(
    cache: BinaryCache, directory: URL, diskLimit: UInt64, io: WorkLimiter,
    plan: UpdatePlan, writeMode: UpdateWriteMode, existingSizes: [String: UInt64],
    cacheOnly: Bool = false
  ) {
    self.cache = cache
    self.directory = directory
    self.diskLimit = diskLimit
    self.io = io
    self.cacheOnly = cacheOnly
    targets = Dictionary(uniqueKeysWithValues: plan.installFiles.map { ($0.fileURL, $0) })
    let patches = plan.patchBundles.flatMap(\.patches)
    let targetPaths = Set(plan.installFiles.map(\.fileURL))
    sharedSources = Set(
      patches.compactMap { patch in
        guard !cacheOnly, let original = patch.original, targetPaths.contains(original.fileURL),
          original.fileURL != patch.target.fileURL
        else { return nil }
        return original.fileURL
      })
    durableSources = Set(
      patches.compactMap { patch in
        guard !cacheOnly, let original = patch.original else { return nil }
        if writeMode == .inPlace
          || (targetPaths.contains(original.fileURL) && original.fileURL != patch.target.fileURL)
        {
          return original.fileURL
        }
        return nil
      })
    references = [:]
    for source in patches.compactMap(\.original) {
      references[Self.key(source), default: 0] += 1
    }
    diskSizes = existingSizes
  }

  static func existingSizes(directory: URL) throws -> [String: UInt64] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var result: [String: UInt64] = [:]
    for file in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey])
    where file.pathExtension == "original" {
      result[file.deletingPathExtension().lastPathComponent] = UInt64(
        try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    return result
  }

  private static func key(_ source: PlannedPatchSource) -> String {
    transferKey("\(source.fileURL.path):\(source.size):\(source.md5.lowercased())")
  }

  func preloadSharedSources(_ plan: UpdatePlan) async throws {
    for source in plan.patchBundles.flatMap(\.patches).compactMap(\.original)
    where sharedSources.contains(source.fileURL) && references[Self.key(source), default: 0] > 0 {
      _ = try await get(source)
    }
  }

  func get(_ source: PlannedPatchSource) async throws -> OriginalSnapshot {
    let key = Self.key(source)
    if let task = tasks[key] { return try await task.value }
    let durable = !cacheOnly && (durableSources.contains(source.fileURL) || diskSizes[key] != nil)
    if durable {
      let used = diskSizes.values.reduce(UInt64(0), +)
      let extra =
        source.size > diskSizes[key, default: 0] ? source.size - diskSizes[key, default: 0] : 0
      guard extra <= diskLimit, used <= diskLimit - extra else {
        throw SophonClientError.UnknownError(
          "The original-file cache limit is too small for this update")
      }
      diskSizes[key] = max(source.size, diskSizes[key, default: 0])
    }
    let savedURL = directory.appendingPathComponent(key + ".original")
    let candidate = targets[source.fileURL]
    let task = Task { [cache, io, cacheOnly] in
      if durable, let digest = try await runTransferIO({ try digestFile(savedURL) }),
        digest.size == source.size, digest.md5 == source.md5.lowercased()
      {
        return OriginalSnapshot(
          input: .file(savedURL, offset: 0, size: source.size), observed: digest,
          fromSavedOriginal: true)
      }
      let writer =
        durable || cacheOnly ? nil : try await cache.makeWriter(expectedSize: source.size)
      do {
        let digest = try await io.withPermit {
          try await Self.capture(
            source, candidate: candidate, writer: writer, savedURL: durable ? savedURL : nil)
        }
        if digest?.size == source.size, digest?.md5 == source.md5.lowercased() {
          let input: PatchInput?
          if cacheOnly {
            input = nil
          } else if let writer {
            input = .cached(try await writer.finish())
          } else {
            input = .file(savedURL, offset: 0, size: source.size)
          }
          return OriginalSnapshot(input: input, observed: digest, fromSavedOriginal: false)
        }
        try? await writer?.abort()
        if durable { try await runTransferIO { try removeOwnedFile(savedURL) } }
        return OriginalSnapshot(input: nil, observed: digest, fromSavedOriginal: false)
      } catch {
        try? await writer?.abort()
        throw error
      }
    }
    tasks[key] = task
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func capture(
    _ source: PlannedPatchSource, candidate: PlannedUpdateFile?, writer: CachedBinaryWriter?,
    savedURL: URL?
  ) async throws -> FileDigest? {
    let opened: (FileHandle, UInt64)? = try await runTransferIO {
      let handle: FileHandle
      do { handle = try FileHandle(forReadingFrom: source.fileURL) } catch {
        if isMissingFile(error) { return nil }
        throw error
      }
      return (handle, try handle.seekToEnd())
    }
    guard let (handle, size) = opened else { return nil }
    defer { transferIOQueue.async { try? handle.close() } }
    guard size == source.size || size == candidate?.size else {
      return FileDigest(size: size, md5: "")
    }
    let output: FileHandle? = try await runTransferIO {
      try handle.seek(toOffset: 0)
      guard size == source.size, let savedURL else { return nil }
      try FileManager.default.createDirectory(
        at: savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard FileManager.default.createFile(atPath: savedURL.path, contents: nil) else {
        throw SophonClientError.UnknownError("Cannot create original snapshot: \(savedURL.path)")
      }
      return try FileHandle(forWritingTo: savedURL)
    }
    defer { transferIOQueue.async { try? output?.close() } }
    var hasher = Insecure.MD5()
    var offset: UInt64 = 0
    while let data = try await runTransferIO({ try handle.read(upToCount: 1024 * 1024) }),
      !data.isEmpty
    {
      hasher.update(data: data)
      if size == source.size {
        if let output {
          try await runTransferIO { try output.write(contentsOf: data) }
        } else {
          try await writer?.write(data, at: offset)
        }
      }
      offset += UInt64(data.count)
    }
    try await runTransferIO(checkCancellation: false) { try output?.close() }
    return FileDigest(
      size: offset, md5: hasher.finalize().map { String(format: "%02x", $0) }.joined())
  }

  func consumed(_ source: PlannedPatchSource) async throws {
    let key = Self.key(source)
    references[key, default: 1] -= 1
    guard references[key] == 0 else { return }
    tasks.removeValue(forKey: key)
    if !cacheOnly, diskSizes[key] != nil {
      let fileURL = directory.appendingPathComponent(key + ".original")
      try await runTransferIO(checkCancellation: false) { try removeOwnedFile(fileURL) }
      diskSizes.removeValue(forKey: key)
    }
  }

  func cancel() { for task in tasks.values { task.cancel() } }
}
