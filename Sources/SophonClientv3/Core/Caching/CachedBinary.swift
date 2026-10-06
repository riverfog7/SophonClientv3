// TODO: Un-vibecode this
import Foundation

private let cachedBinaryIOQueue = DispatchQueue(
  label: "sophon.binary-cache.io", qos: .utility, attributes: .concurrent
)

private func cleanupCachedBinaryFile(at fileURL: URL, reservation: BinaryCache.Reservation) {
  cachedBinaryIOQueue.async {
    withExtendedLifetime(reservation) {
      do {
        try FileManager.default.removeItem(at: fileURL)
      } catch {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
          nsError.code == CocoaError.Code.fileNoSuchFile.rawValue
            || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
        {
          return
        }

        // Keep the bytes and entry slot charged until the file is removed.
        cachedBinaryIOQueue.asyncAfter(deadline: .now() + 5) {
          cleanupCachedBinaryFile(at: fileURL, reservation: reservation)
        }
      }
    }
  }
}

private func performCacheIO<T: Sendable>(
  on queue: DispatchQueue = cachedBinaryIOQueue,
  _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
  try Task.checkCancellation()
  let value: T = try await withCheckedThrowingContinuation { continuation in
    queue.async {
      continuation.resume(with: Result(catching: operation))
    }
  }
  try Task.checkCancellation()
  return value
}

private func checkBinaryRange(offset: UInt64, length: UInt64, size: UInt64) throws {
  guard offset <= size, length <= size - offset else {
    throw BinaryCacheError.outOfBounds
  }
}

// Mutated only by the writer's queue; immutable once handed to CachedBinary.
private final class CachedBinaryStorage: @unchecked Sendable {
  let reservation: BinaryCache.Reservation
  var fileURL: URL?
  var data: Data?

  init(reservation: BinaryCache.Reservation, directory: URL) throws {
    self.reservation = reservation
    if reservation.inMemory {
      self.fileURL = nil
      self.data = Data(count: Int(reservation.size))
    } else {
      self.data = nil
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let fileURL = directory.appendingPathComponent("sophon-\(UUID().uuidString).tmp")
      try Data().write(to: fileURL, options: .withoutOverwriting)
      self.fileURL = fileURL
    }
  }

  deinit {
    data = nil
    guard let fileURL else { return }
    cleanupCachedBinaryFile(at: fileURL, reservation: reservation)
  }
}

final class CachedBinaryWriter: @unchecked Sendable {
  private let ioQueue = DispatchQueue(label: "sophon.binary-cache.write", qos: .utility)
  // All mutable state is confined to ioQueue.
  private var storage: CachedBinaryStorage?
  private var handle: FileHandle?
  private var writtenRanges: [Range<UInt64>] = []

  private init(storage: CachedBinaryStorage, handle: FileHandle?) {
    self.storage = storage
    self.handle = handle
  }

  internal static func make(
    reservation: BinaryCache.Reservation, directory: URL
  ) async throws -> CachedBinaryWriter {
    try await performCacheIO {
      let storage = try CachedBinaryStorage(reservation: reservation, directory: directory)
      let handle = try storage.fileURL.map { try FileHandle(forUpdating: $0) }
      return CachedBinaryWriter(storage: storage, handle: handle)
    }
  }

  deinit {
    let handle = handle
    let storage = storage
    ioQueue.async {
      withExtendedLifetime(storage) {
        try? handle?.close()
      }
    }
  }

  internal func write(_ data: Data, at offset: UInt64) async throws {
    try await run { writer in
      guard let storage = writer.storage else { throw BinaryCacheError.closed }
      let length = UInt64(data.count)
      try checkBinaryRange(offset: offset, length: length, size: storage.reservation.size)
      guard !data.isEmpty else { return }

      do {
        if let handle = writer.handle {
          try handle.seek(toOffset: offset)
          try handle.write(contentsOf: data)
        } else {
          storage.data?.replaceSubrange(Int(offset)..<Int(offset + length), with: data)
        }
      } catch {
        try? writer.discard()
        throw error
      }
      writer.recordRange(offset..<(offset + length))
    }
  }

  // A failed coverage check leaves the writer open for missing ranges.
  internal func finish() async throws -> CachedBinary {
    try await run { writer in
      guard let storage = writer.storage else { throw BinaryCacheError.closed }
      let size = storage.reservation.size
      guard size == 0 || writer.writtenRanges == [0..<size] else {
        throw BinaryCacheError.incomplete
      }
      do {
        try writer.handle?.close()
      } catch {
        try? writer.discard()
        throw error
      }
      writer.handle = nil
      writer.storage = nil
      writer.writtenRanges.removeAll()
      return CachedBinary(storage: storage, offset: 0, size: size)
    }
  }

  internal func abort() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      ioQueue.async { [self] in
        continuation.resume(with: Result { try discard() })
      }
    }
  }

  private func run<T: Sendable>(
    _ operation: @escaping @Sendable (CachedBinaryWriter) throws -> T
  ) async throws -> T {
    do {
      return try await performCacheIO(on: ioQueue) { try operation(self) }
    } catch is CancellationError {
      try? await abort()
      throw CancellationError()
    }
  }

  private func discard() throws {
    defer {
      handle = nil
      storage = nil
      writtenRanges.removeAll()
    }
    try handle?.close()
    if let fileURL = storage?.fileURL {
      try FileManager.default.removeItem(at: fileURL)
      storage?.fileURL = nil
    }
  }

  private func recordRange(_ range: Range<UInt64>) {
    var lower = range.lowerBound
    var upper = range.upperBound
    let first = writtenRanges.firstIndex { $0.upperBound >= lower } ?? writtenRanges.count
    var last = first
    while last < writtenRanges.count, writtenRanges[last].lowerBound <= upper {
      lower = min(lower, writtenRanges[last].lowerBound)
      upper = max(upper, writtenRanges[last].upperBound)
      last += 1
    }
    writtenRanges.replaceSubrange(first..<last, with: [lower..<upper])
  }
}

struct CachedBinary: Sendable {
  fileprivate let storage: CachedBinaryStorage
  fileprivate let offset: UInt64
  let size: UInt64

  internal func slice(offset: UInt64, length: UInt64) throws -> CachedBinary {
    try checkBinaryRange(offset: offset, length: length, size: size)
    return CachedBinary(storage: storage, offset: self.offset + offset, size: length)
  }

  // Synchronous access for callers running on a blocking I/O thread.
  internal func makeReader() throws -> CachedBinaryReader {
    try CachedBinaryReader(binary: self)
  }

  internal func stream(bufferSize: Int = 1024 * 1024) throws -> CachedBinaryStream {
    guard bufferSize > 0 else { throw BinaryCacheError.invalidBufferSize }
    return CachedBinaryStream(binary: self, bufferSize: bufferSize)
  }
}

final class CachedBinaryReader: @unchecked Sendable {
  private let binary: CachedBinary
  private let handle: FileHandle?
  private let lock = NSLock()

  fileprivate init(binary: CachedBinary) throws {
    self.binary = binary
    self.handle = try binary.storage.fileURL.map { try FileHandle(forReadingFrom: $0) }
  }

  deinit {
    let handle = handle
    let binary = binary
    cachedBinaryIOQueue.async {
      withExtendedLifetime(binary) {
        try? handle?.close()
      }
    }
  }

  internal func read(at offset: UInt64, count: Int) throws -> Data {
    guard count >= 0 else { throw BinaryCacheError.outOfBounds }
    try checkBinaryRange(offset: offset, length: UInt64(count), size: binary.size)
    guard count > 0 else { return Data() }

    lock.lock()
    defer { lock.unlock() }
    let position = binary.offset + offset
    if let data = binary.storage.data {
      return data.subdata(in: Int(position)..<(Int(position) + count))
    }

    guard let handle else { throw BinaryCacheError.closed }
    try handle.seek(toOffset: position)
    var data = Data()
    while data.count < count {
      guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else {
        throw BinaryCacheError.unexpectedEndOfFile
      }
      data.append(part)
    }
    return data
  }
}

// One bounded read per next(), with no background producer or prefetch queue.
struct CachedBinaryStream: AsyncSequence, Sendable {
  typealias Element = Data
  fileprivate let binary: CachedBinary
  fileprivate let bufferSize: Int

  internal func makeAsyncIterator() -> Iterator {
    Iterator(binary: binary, bufferSize: bufferSize)
  }

  struct Iterator: AsyncIteratorProtocol {
    fileprivate let binary: CachedBinary
    fileprivate let bufferSize: Int
    fileprivate var reader: CachedBinaryReader? = nil
    fileprivate var offset: UInt64 = 0

    internal mutating func next() async throws -> Data? {
      guard offset < binary.size else {
        reader = nil
        return nil
      }
      do {
        let binary = binary
        let reader = reader
        let offset = offset
        let count = Int(Swift.min(UInt64(bufferSize), binary.size - offset))
        let (activeReader, data) = try await performCacheIO {
          let activeReader = try reader ?? binary.makeReader()
          return (activeReader, try activeReader.read(at: offset, count: count))
        }
        self.offset += UInt64(data.count)
        self.reader = self.offset < binary.size ? activeReader : nil
        return data
      } catch {
        offset = binary.size
        reader = nil
        throw error
      }
    }
  }
}
