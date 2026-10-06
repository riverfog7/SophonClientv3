import Foundation

public enum UpdateFileStage: String, Codable, Sendable {
  case writing
  case repair
  case completed
}

public struct SavedUpdateState: Codable, Sendable {
  public let plan: UpdatePlan
  public let files: [String: UpdateFileStage]
  public let finished: Bool
}

final class UpdateJournal: @unchecked Sendable {
  private struct Record: Codable {
    let path: String?
    let stage: UpdateFileStage?
    var finished: Bool? = nil
  }

  private let lock = NSLock()
  private let handle: FileHandle
  private let encoder = JSONEncoder()
  private var files: [String: UpdateFileStage]
  let plan: UpdatePlan

  init(directory: URL, plan: UpdatePlan) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let planURL = directory.appendingPathComponent("plan.json")
    let eventsURL = directory.appendingPathComponent("events.jsonl")
    let saved = try Self.load(directory: directory)
    let planData = try JSONEncoder().encode(plan)
    if let saved, !saved.finished {
      guard saved.plan.sourceVersion == plan.sourceVersion,
        saved.plan.targetVersion == plan.targetVersion
      else {
        throw SophonClientError.UnknownError(
          "An unfinished update must be resumed before starting another")
      }
      self.plan = saved.plan
      files = saved.files
    } else {
      try planData.write(to: planURL, options: .atomic)
      try Data().write(to: eventsURL, options: .atomic)
      self.plan = plan
      files = [:]
    }
    handle = try FileHandle(forUpdating: eventsURL)
    let events = try Data(contentsOf: eventsURL)
    let validLength = events.lastIndex(of: 10).map { $0 + 1 } ?? 0
    try handle.truncate(atOffset: UInt64(validLength))
    try handle.seekToEnd()
  }

  static func directory(settings: TransferSettings, gameDirectory: URL) -> URL {
    settings.stateURL.appendingPathComponent(transferKey(gameDirectory.standardizedFileURL.path))
      .appendingPathComponent("update", isDirectory: true)
  }

  static func load(directory: URL) throws -> SavedUpdateState? {
    let planURL = directory.appendingPathComponent("plan.json")
    let eventsURL = directory.appendingPathComponent("events.jsonl")
    let data: Data
    do { data = try Data(contentsOf: planURL) } catch {
      if isMissingFile(error) { return nil }
      throw error
    }
    let plan = try JSONDecoder().decode(UpdatePlan.self, from: data)
    let events: Data
    do { events = try Data(contentsOf: eventsURL) } catch {
      if isMissingFile(error) { return SavedUpdateState(plan: plan, files: [:], finished: false) }
      throw error
    }
    var files: [String: UpdateFileStage] = [:]
    var finished = false
    for line in events.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
      let record = try JSONDecoder().decode(Record.self, from: Data(line))
      if let path = record.path, let stage = record.stage { files[path] = stage }
      if record.finished == true { finished = true }
    }
    return SavedUpdateState(plan: plan, files: files, finished: finished)
  }

  func stage(of fileURL: URL) -> UpdateFileStage? {
    lock.withLock { files[fileURL.path] }
  }

  func record(_ fileURL: URL, stage: UpdateFileStage) throws {
    try lock.withLock {
      try append(Record(path: fileURL.path, stage: stage))
      files[fileURL.path] = stage
    }
  }

  func complete() throws {
    try lock.withLock {
      try append(Record(path: nil, stage: nil, finished: true))
    }
  }

  private func append(_ record: Record) throws {
    var bytes = try encoder.encode(record)
    bytes.append(10)
    try handle.write(contentsOf: bytes)
  }

  deinit {
    let handle = handle
    transferIOQueue.async { try? handle.close() }
  }
}
