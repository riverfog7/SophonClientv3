import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct DownloadByteProgress: Codable, Sendable {
  public let id: String
  public let category: String
  public let totalBytes: UInt64
  public var receivedBytes: UInt64
  public var retainedBytes: UInt64
  public var transferredBytes: UInt64
}

public struct StorageByteProgress: Codable, Sendable {
  public let id: String
  public let location: String
  public var roles: [String]
  public var readBytes: UInt64 = 0
  public var writtenBytes: UInt64 = 0
  public var cacheBytes: UInt64 = 0
  public var reservedCacheBytes: UInt64 = 0
}

public struct TransferResourceProgress: Codable, Sendable {
  public let memoryBytes: UInt64
  public let memoryLimit: UInt64
  public let diskLimit: UInt64
  public let devices: [StorageByteProgress]
  public let downloads: [DownloadByteProgress]

  public var receivedBytes: UInt64 {
    downloads.filter { $0.category == "patch" }.reduce(0) { $0 + $1.receivedBytes }
  }
  public var retainedBytes: UInt64 {
    downloads.filter { $0.category == "patch" }.reduce(0) { $0 + $1.retainedBytes }
  }
  public var transferredBytes: UInt64 {
    downloads.filter { $0.category == "patch" }.reduce(0) { $0 + $1.transferredBytes }
  }
}

// I/O callbacks only update counters. One periodic publisher forwards snapshots to the reporter.
final class TransferTelemetry: @unchecked Sendable {
  private let lock = NSLock()
  private let memoryLimit: UInt64
  private let diskLimit: UInt64
  private var memoryBytes: UInt64 = 0
  private var devices: [String: StorageByteProgress] = [:]
  private var locations: [String: String] = [:]
  private var downloads: [String: DownloadByteProgress] = [:]

  init(memoryLimit: UInt64, diskLimit: UInt64) {
    self.memoryLimit = memoryLimit
    self.diskLimit = diskLimit
  }

  @discardableResult
  func register(_ url: URL, role: String) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    if let known = lock.withLock({ locations[path] }) {
      lock.withLock {
        if !devices[known]!.roles.contains(role) { devices[known]!.roles.append(role) }
      }
      return known
    }
    let (id, location) = Self.storage(at: url)
    lock.withLock {
      locations[path] = id
      if devices[id] == nil {
        devices[id] = StorageByteProgress(id: id, location: location, roles: [])
      }
      if !devices[id]!.roles.contains(role) { devices[id]!.roles.append(role) }
    }
    return id
  }

  func read(_ bytes: UInt64, device: String) {
    lock.withLock { devices[device]?.readBytes += bytes }
  }

  func write(_ bytes: UInt64, device: String) {
    lock.withLock { devices[device]?.writtenBytes += bytes }
  }

  func reserve(_ bytes: UInt64, inMemory: Bool, device: String) {
    lock.withLock {
      if inMemory { memoryBytes += bytes } else { devices[device]?.reservedCacheBytes += bytes }
    }
  }

  func release(_ bytes: UInt64, inMemory: Bool, device: String) {
    lock.withLock {
      if inMemory {
        memoryBytes -= min(memoryBytes, bytes)
      } else if let value = devices[device]?.reservedCacheBytes {
        devices[device]?.reservedCacheBytes -= min(value, bytes)
      }
    }
  }

  func stored(_ bytes: UInt64, device: String) {
    lock.withLock { devices[device]?.cacheBytes += bytes }
  }

  func removed(_ bytes: UInt64, device: String) {
    lock.withLock {
      if let value = devices[device]?.cacheBytes {
        devices[device]?.cacheBytes -= min(value, bytes)
      }
    }
  }

  func planDownload(_ id: String, size: UInt64, retained: UInt64, category: String = "patch") {
    lock.withLock {
      downloads[id] = DownloadByteProgress(
        id: id, category: category, totalBytes: size, receivedBytes: min(size, retained),
        retainedBytes: min(size, retained), transferredBytes: 0)
    }
  }

  func receive(_ bytes: UInt64, committed: UInt64, id: String) {
    lock.withLock {
      downloads[id]?.transferredBytes += bytes
      if let total = downloads[id]?.totalBytes {
        downloads[id]?.receivedBytes = min(total, committed)
      }
    }
  }

  func resetDownload(_ id: String) {
    lock.withLock {
      downloads[id]?.receivedBytes = 0
      downloads[id]?.retainedBytes = 0
    }
  }

  func ready(_ id: String) {
    lock.withLock {
      if let total = downloads[id]?.totalBytes { downloads[id]?.receivedBytes = total }
    }
  }

  func snapshot() -> TransferResourceProgress {
    lock.withLock {
      TransferResourceProgress(
        memoryBytes: memoryBytes, memoryLimit: memoryLimit, diskLimit: diskLimit,
        devices: devices.values.sorted { $0.id < $1.id },
        downloads: downloads.values.sorted { $0.id < $1.id })
    }
  }

  private static func storage(at url: URL) -> (String, String) {
    var current = url.standardizedFileURL.resolvingSymlinksInPath()
    #if canImport(Darwin) || canImport(Glibc)
      var info = stat()
      while stat(current.path, &info) != 0, current.path != "/" {
        current.deleteLastPathComponent()
      }
      let device = info.st_dev
      var mount = current
      while mount.path != "/" {
        let parent = mount.deletingLastPathComponent()
        var parentInfo = stat()
        guard stat(parent.path, &parentInfo) == 0, parentInfo.st_dev == device else { break }
        mount = parent
      }
      return (String(describing: device), mount.path)
    #else
      let volume = try? current.resourceValues(forKeys: [.volumeURLKey])
      let root = volume?.volume ?? current
      return (root.path, root.path)
    #endif
  }
}
