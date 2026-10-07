import ArgumentParser
import Foundation
import HYPAPIClient
import SophonClientv3

extension StorageIOPolicy: ExpressibleByArgument {}
extension UpdateWriteMode: ExpressibleByArgument {}

struct TransferCLIOptions: ParsableArguments, Sendable {
  @Option(help: "Fast local working cache for downloads and original snapshots.")
  var cacheDirectory: String?
  @Option(help: "Operation state directory; defaults to a directory within the cache.")
  var stateDirectory: String?
  @Option(name: .customLong("memory-cache-mib"), help: "RAM snapshot cache limit in MiB.")
  var memoryCacheMiB = 500
  @Option(name: .customLong("disk-cache-gib"), help: "Limit in GiB for each disk cache.")
  var diskCacheGiB = 10
  @Option(help: "Maximum queued cache entries.")
  var cacheEntryLimit = 500
  @Option(help: "Target I/O: serialized by default for updates, parallel for installs.")
  var ioPolicy: StorageIOPolicy?
  @Option(help: "Update output mode: temporary replacement or in-place overwrite.")
  var writeMode: UpdateWriteMode = .temporaryReplacement
  @Flag(
    help: "Rebuild progress from files instead of using saved checkpoints; downloads remain cached."
  )
  var stateless = false

  mutating func validate() throws {
    guard memoryCacheMiB >= 0, memoryCacheMiB <= Int.max / (1024 * 1024),
      diskCacheGiB > 0, diskCacheGiB <= Int.max / (1024 * 1024 * 1024), cacheEntryLimit > 0
    else {
      throw ValidationError("Cache limits must fit the platform and disk capacity must be positive")
    }
  }

  var settings: TransferSettings {
    var settings = TransferSettings()
    settings.cacheDirectory = cacheDirectory
    settings.stateDirectory = stateDirectory
    settings.memoryLimit = UInt64(memoryCacheMiB) * 1024 * 1024
    settings.diskLimit = UInt64(diskCacheGiB) * 1024 * 1024 * 1024
    settings.entryLimit = cacheEntryLimit
    settings.ioPolicy = ioPolicy
    settings.writeMode = writeMode
    settings.preserveState = !stateless
    return settings
  }
}

struct UpdateCLI: AsyncParsableCommand, Sendable {
  static let configuration = CommandConfiguration(
    commandName: "update", abstract: "Apply an incremental game update.")
  @Argument(help: "Game ID or game biz.") var game: String
  @Argument(help: "Game directory.") var directory: String
  @Option(
    name: .customLong("from"),
    help: "Source version override; defaults to the saved operation or executable hash detection.")
  var sourceVersion: String?
  @Flag(help: "Use CN endpoints.") var cn = false
  @Flag(help: "Select the future branch instead of the live branch.") var predownload = false
  @Option(help: "Download diff bundles to this directory without modifying game files.")
  var cacheAt: String?
  @Option(help: "Installation category scenario: full or base.") var mode = "full"
  @Option(help: "Maximum parallel HTTP range downloads.") var maxConcurrentDownloads = 8
  @Option(help: "Maximum file patch workers when --io-policy parallel is selected.")
  var maxConcurrentWrites = 4
  @Flag(help: "Print the selected update plan without applying it.") var plan = false
  @Flag(help: "Print append-only summaries instead of updating a terminal dashboard.")
  var plain = false
  @Option(
    help: "Dashboard refresh interval in seconds; plain output is limited to once per second.")
  var refreshInterval = 0.25
  @OptionGroup var transfer: TransferCLIOptions

  mutating func validate() throws {
    guard ["full", "base"].contains(mode), sourceVersion?.isEmpty != true, cacheAt?.isEmpty != true,
      maxConcurrentDownloads > 0, maxConcurrentWrites > 0
    else { throw ValidationError("Invalid update scenario, source version, or worker count") }
    guard refreshInterval.isFinite, refreshInterval > 0, refreshInterval <= Double(Int32.max) else {
      throw ValidationError("--refresh-interval must be positive and at most \(Int32.max) seconds")
    }
  }

  mutating func run() async throws {
    var settings = transfer.settings
    settings.predownloadDirectory = cacheAt
    if plan {
      let client = try await makeOperationClient(
        game: game, directory: directory, cn: cn, transfer: settings,
        downloads: maxConcurrentDownloads, writes: maxConcurrentWrites)
      let plan = try await client.planUpdate(
        sourceVersion: sourceVersion, mode: mode == "base" ? .base : .full,
        predownload: predownload)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      print(String(decoding: try encoder.encode(plan), as: UTF8.self))
      return
    }
    let command = self
    let terminal = InstallTerminal(plain: plain)
    let frames = AsyncStream<InstallFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let dashboard = UpdateDashboard(
      title: "\(game) [\(mode)\(predownload ? ", predownload branch" : "")]",
      directory: URL(fileURLWithPath: directory).standardizedFileURL.path,
      cacheAt: cacheAt.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
      writeMode: settings.writeMode, ioPolicy: settings.ioPolicy ?? .serialized,
      plain: !terminal.interactive, frames: frames.continuation)
    await dashboard.refresh(force: true)
    let operation = Task { [settings] in await command.update(settings, dashboard: dashboard) }
    let interrupts = InstallInterrupts {
      operation.cancel()
      Task { await dashboard.requestCancellation() }
    }
    let rendering = Task {
      do {
        for await frame in frames.stream { try await terminal.write(frame) }
        return nil as String?
      } catch {
        operation.cancel()
        return error.localizedDescription
      }
    }
    let ticker = Task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(command.refreshInterval)) } catch { return }
        await dashboard.refresh()
      }
    }
    let outcome = await withTaskCancellationHandler {
      await operation.value
    } onCancel: {
      operation.cancel()
    }
    ticker.cancel()
    await ticker.value
    await dashboard.complete(outcome)
    frames.continuation.finish()
    let outputError = await rendering.value
    withExtendedLifetime(interrupts) {}
    if let outputError { throw ValidationError("Could not write update progress: \(outputError)") }
    switch outcome {
    case .completed: return
    case .cancelled: throw ExitCode(130)
    case .failed: throw ExitCode.failure
    }
  }

  private func update(_ settings: TransferSettings, dashboard: UpdateDashboard) async
    -> UpdateOutcome
  {
    do {
      try Task.checkCancellation()
      let client = try await makeOperationClient(
        game: game, directory: directory, cn: cn, transfer: settings,
        downloads: maxConcurrentDownloads, writes: maxConcurrentWrites)
      try Task.checkCancellation()
      let reporter = client.makeUpdateReporter()
      let subscription = await reporter.subscribe()
      let progress = Task {
        for await event in subscription.events { await dashboard.record(event) }
      }
      let outcome: UpdateOutcome
      do {
        try await client.update(
          sourceVersion: sourceVersion, mode: mode == "base" ? .base : .full,
          predownload: predownload, cacheOnly: cacheAt != nil, reporter: reporter)
        outcome = .completed
      } catch {
        outcome =
          error is CancellationError || Task.isCancelled
          ? .cancelled : .failed(reason: error.localizedDescription)
      }
      await reporter.unsubscribe(subscription.id)
      await progress.value
      await client.flushLogs()
      return outcome
    } catch {
      return error is CancellationError || Task.isCancelled
        ? .cancelled : .failed(reason: error.localizedDescription)
    }
  }
}

struct NextActionCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "next-action", abstract: "Return the next appropriate action without executing it."
  )
  @Argument var game: String
  @Argument var directory: String
  @Flag var cn = false
  @OptionGroup var transfer: TransferCLIOptions

  mutating func run() async throws {
    let client = try await makeOperationClient(
      game: game, directory: directory, cn: cn, transfer: transfer.settings)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(await client.nextAction()), as: UTF8.self))
  }
}

struct UpdateStateCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "state", abstract: "Inspect saved updater state.")
  @Argument var directory: String
  @Option(help: "Operation to inspect: update or install.") var operation = "update"
  @OptionGroup var transfer: TransferCLIOptions

  mutating func validate() throws {
    guard ["update", "install"].contains(operation) else {
      throw ValidationError("Unknown operation")
    }
  }

  mutating func run() async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data: Data
    if operation == "install" {
      data = try encoder.encode(
        await SophonClientv3.savedInstallationState(
          at: URL(fileURLWithPath: directory), settings: transfer.settings))
    } else {
      data = try encoder.encode(
        await SophonClientv3.savedUpdateState(
          at: URL(fileURLWithPath: directory), settings: transfer.settings))
    }
    print(String(decoding: data, as: UTF8.self))
  }
}

func makeOperationClient(
  game: String, directory: String, cn: Bool, transfer: TransferSettings,
  downloads: Int = 8, writes: Int = 4
) async throws -> SophonClientv3 {
  let api = HYPAPIClientManager.shared.getClient(isCN: cn)
  let config = try resolveHYPGame(game, in: await api.getGameConfigs())
  let manifests =
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    ?? FileManager.default.temporaryDirectory
  let settings = SophonClientSettings(
    baseURL: cn ? HYPAPI_CN_BASE_URL : HYPAPI_OS_BASE_URL,
    sophonBaseURL: cn ? SOPHON_API_CN_BASE_URL : SOPHON_API_OS_BASE_URL,
    launcherID: cn ? HYPAPI_CN_LAUNCHER_ID : HYPAPI_OS_LAUNCHER_ID,
    gameID: config.game.id,
    manifestCacheDir: manifests.appendingPathComponent("SophonClientv3/manifests").path,
    logStdout: false, maxCocurrentDownloads: downloads, maxCocurrentWrites: writes,
    transfer: transfer)
  return try await SophonClientv3(settings, baseGameDir: URL(fileURLWithPath: directory))
}

private actor UpdateDashboard {
  private let title: String
  private let directory: String
  private let cacheAt: String?
  private let writeMode: UpdateWriteMode
  private let ioPolicy: StorageIOPolicy
  private let plain: Bool
  private let frames: AsyncStream<InstallFrame>.Continuation
  private let origin = ContinuousClock.now
  private var phase: UpdatePhase = .metadata
  private var phaseStart: Double = 0
  private var ended: Double?
  private var outcome: UpdateOutcome?
  private var cancelling = false
  private var lastFrame: Double = -.infinity
  private var version = "Resolving source and target versions"
  private var latest = "Loading game configuration and branches"
  private var currentFile: String?
  private var downloads = InstallMeter()
  private var files = InstallMeter()
  private var writes = InstallMeter()
  private var repairDownloads = InstallMeter()
  private var repairWrites = InstallMeter()
  private var deletions = InstallMeter()
  private var bundles = 0
  private var skipped = 0
  private var repairFiles = 0
  private var deletedBytes: UInt64 = 0
  private var totalDeleteBytes: UInt64 = 0

  init(
    title: String, directory: String, cacheAt: String?, writeMode: UpdateWriteMode,
    ioPolicy: StorageIOPolicy, plain: Bool, frames: AsyncStream<InstallFrame>.Continuation
  ) {
    self.title = title
    self.directory = directory
    self.cacheAt = cacheAt
    self.writeMode = writeMode
    self.ioPolicy = ioPolicy
    self.plain = plain
    self.frames = frames
  }

  private var now: Double {
    let elapsed = origin.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
  }

  func record(_ event: UpdateEvent) {
    guard outcome == nil else { return }
    let time = now
    switch event {
    case .planned(
      let source, let target, let patchBytes, let outputBytes, let count, let deletes, let bytes):
      version = "\(source) -> \(target)"
      downloads.setTotal(patchBytes, at: time)
      files.setTotal(UInt64(count), at: time)
      writes.setTotal(outputBytes, at: time)
      deletions.setTotal(UInt64(deletes), at: time)
      totalDeleteBytes = bytes
    case .bundleDownloaded(let id, let bytes):
      bundles += 1
      downloads.advance(bytes, at: time)
      latest = "Bundle ready: \(id)"
    case .fileStarted(let path):
      currentFile = fileName(path)
    case .fileNeedsRepair(let path):
      repairFiles += 1
      currentFile = nil
      latest = "Queued for repair: \(fileName(path))"
    case .fileCompleted(let path, let bytes, let wasSkipped):
      files.advance(1, at: time)
      if wasSkipped {
        skipped += 1
        if let total = writes.total { writes.setTotal(total - min(total, bytes), at: time) }
      } else {
        writes.advance(bytes, at: time)
      }
      if currentFile == fileName(path) { currentFile = nil }
      latest = "\(wasSkipped ? "Already updated" : "Verified"): \(fileName(path))"
    case .fileCached(let path):
      files.advance(1, at: time)
      latest = "Cached patch: \(fileName(path))"
    case .repairPlanned(let downloadBytes, let writeBytes):
      repairDownloads.setTotal(downloadBytes, at: time)
      repairWrites.setTotal(writeBytes, at: time)
      repairDownloads.start(at: time)
      repairWrites.start(at: time)
    case .repairDownloaded(let bytes):
      repairDownloads.advance(bytes, at: time)
    case .repairWritten(let bytes):
      repairWrites.advance(bytes, at: time)
    case .fileDeleted(let path, let bytes):
      deletions.advance(1, at: time)
      deletedBytes += bytes
      latest = "Delete entry complete: \(fileName(path))"
    case .phaseChanged(let next):
      guard next != phase else { return }
      phase = next
      phaseStart = time
      if next == .running || next == .caching {
        downloads.start(at: time)
        files.start(at: time)
        writes.start(at: time)
      }
      refresh(force: true)
    case .finished(let result): finish(result, at: time)
    }
  }

  func requestCancellation() {
    guard outcome == nil else { return }
    cancelling = true
    refresh(force: true)
  }

  func refresh(force: Bool = false) {
    guard outcome == nil else { return }
    let time = now
    guard force || !plain || time - lastFrame >= 1 else { return }
    lastFrame = time
    frames.yield(InstallFrame(lines: lines(at: time), force: force))
  }

  func complete(_ result: UpdateOutcome) {
    if outcome == nil { finish(result, at: now) }
    frames.yield(InstallFrame(lines: lines(at: ended ?? now), force: true))
  }

  private func finish(_ result: UpdateOutcome, at time: Double) {
    outcome = result
    ended = time
    if case .completed = result {
      // Recovery can skip whole bundles whose targets were already completed.
      downloads.setTotal(downloads.value, at: time)
    }
    downloads.finish(at: time)
    files.finish(at: time)
    writes.finish(at: time)
    repairDownloads.finish(at: time)
    repairWrites.finish(at: time)
    deletions.finish(at: time)
  }

  private func average(_ meter: InstallMeter, at time: Double) -> Double? {
    let elapsed = meter.elapsed(at: time)
    return elapsed >= 0.25 ? Double(meter.value) / elapsed : nil
  }

  private func eta(_ meter: InstallMeter, at time: Double) -> Double? {
    if meter.done { return 0 }
    guard let total = meter.total, let rate = average(meter, at: time), rate > 0 else { return nil }
    return Double(total - meter.value) / rate
  }

  private func lines(at time: Double) -> [String] {
    let status: String
    switch outcome {
    case .completed?: status = "COMPLETED"
    case .cancelled?: status = "CANCELLED"
    case .failed?: status = "FAILED"
    case nil: status = cancelling ? "CANCELLING..." : phase.rawValue.uppercased()
    }
    let estimates = [downloads, files].map { eta($0, at: time) }
    let remaining = estimates.allSatisfy { $0 != nil } ? estimates.compactMap { $0 }.max() : nil
    var lines = [
      "  SOPHON / UPDATE",
      "  \(installText(title, limit: 70))",
      "  Target  \(installText(directory, limit: 65))",
      cacheAt.map { "  Cache at  \(installText($0, limit: 63))" }
        ?? "  Output  \(writeMode == .inPlace ? "In-place" : "Temporary replacement") | \(ioPolicy == .serialized ? "Sequential" : "Parallel") I/O",
      "  Version  \(installText(version, limit: 65))",
      "",
      "  \(status)",
      "  Stage \(installDuration(time - phaseStart))   Total \(installDuration(time))   ETA \(installDuration(remaining))",
      "",
    ]
    if phase == .repairing || repairDownloads.total != nil {
      lines.append(
        "  Patch data ready  \(installBytes(Double(downloads.value))) (\(bundles) bundles)")
      lines += byteRows("Repair data", repairDownloads, at: time)
      lines += byteRows("Repair write", repairWrites, at: time)
    } else {
      lines += byteRows("Patch data", downloads, at: time)
      lines.append("  Bundles ready  \(bundles)")
    }
    lines += [
      progressRow(cacheAt == nil ? "Files" : "Cached files", files, at: time),
      "  \(files.value) / \(files.total.map(String.init) ?? "—") files   Skipped \(skipped)   Repair \(repairFiles)",
    ]
    if cacheAt == nil {
      if phase == .repairing || repairDownloads.total != nil {
        lines.append("  Verified output  \(installBytes(Double(writes.value)))")
      } else {
        lines += byteRows("Output", writes, at: time)
      }
      lines.append(
        "  Delete entries  \(deletions.value) / \(deletions.total.map(String.init) ?? "—")   Planned \(installBytes(Double(totalDeleteBytes)))   Removed \(installBytes(Double(deletedBytes)))"
      )
    }
    lines += [
      "",
      "  \(currentFile == nil ? "Latest" : "File")  \(installText(currentFile ?? latest, limit: 65))",
      "  Ready totals include cached bundles; output counts verified files.",
    ]
    if case .failed(let reason)? = outcome {
      lines.append("  Error  \(installText(reason, limit: 500))")
    }
    return lines
  }

  private func progressRow(_ label: String, _ meter: InstallMeter, at time: Double) -> String {
    "  \(installColumn(label, width: 12))\(installBar(meter.value, meter.total, at: time, unicode: !plain))  \(installPercent(meter.value, meter.total))"
  }

  private func byteRows(_ label: String, _ meter: InstallMeter, at time: Double) -> [String] {
    [
      progressRow(label, meter, at: time),
      "  \(installColumn("\(installBytes(Double(meter.value))) / \(meter.total.map { installBytes(Double($0)) } ?? "—")"))Avg \(installSpeed(average(meter, at: time)))",
    ]
  }

  private func fileName(_ file: URL) -> String {
    let prefix = directory.hasSuffix("/") ? directory : directory + "/"
    return file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
  }
}
