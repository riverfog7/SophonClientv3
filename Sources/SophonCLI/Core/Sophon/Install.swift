import ArgumentParser
import Dispatch
import Foundation
import HYPAPIClient
import SophonClientv3

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif

struct InstallCLI: AsyncParsableCommand, Sendable {
  static let configuration = CommandConfiguration(
    commandName: "install",
    abstract: "Verify an installation and download missing or damaged chunks."
  )

  @Argument(help: "Game ID or game biz.", completion: .list(AVAILABLE_GAME_BIZS))
  var gameIDOrBiz: String

  @Argument(help: "Destination game directory; may not exist yet.", completion: .directory)
  var directory: String

  @Flag(help: "Use the CN endpoints and launcher ID instead of OS defaults.")
  var cn = false

  @Option(help: "Override the regional HYP API base URL.")
  var baseURL: String?

  @Option(help: "Override the regional Sophon API base URL.")
  var sophonBaseURL: String?

  @Option(help: "Override the regional launcher ID.")
  var launcherID: String?

  @Option(
    help: "Manifest cache directory; defaults to the user cache directory.", completion: .directory)
  var manifestCacheDir: String?

  @Option(help: "Installation mode: full or base.", completion: .list(["full", "base"]))
  var mode = "full"

  @Option(
    name: .customLong("voice-pack"),
    help: "Audio matching field; repeat for multiple packs. Installed packs are auto-detected.")
  var voicePacks: [String] = []

  @Flag(help: "Install the predownload branch into the destination; NOT download-only caching.")
  var predownload = false

  @Option(help: "Additional download attempts after the initial attempt.")
  var maxRetries = 10

  @Option(help: "Seconds between retries; zero is allowed.")
  var retryInterval = 5

  @Option(help: "Maximum concurrent file checks.")
  var maxConcurrentChecks = 8

  @Option(help: "Maximum concurrent chunk downloads.")
  var maxConcurrentDownloads = 8

  @Option(help: "Maximum concurrent chunk post-processors.")
  var maxConcurrentPostProcessors = 4

  @Option(help: "Maximum concurrent disk writers.")
  var maxConcurrentWrites = 4

  @Option(
    help: "Optional library log file. Normal library stdout logging is always disabled.",
    completion: .file())
  var logFile: String?

  @Flag(help: "Print append-only summaries instead of updating a terminal dashboard.")
  var plain = false

  @Option(
    help: "Dashboard refresh interval in seconds; plain output is limited to once per second.")
  var refreshInterval = 0.25

  private var cacheURL: URL {
    if let manifestCacheDir { return URL(fileURLWithPath: manifestCacheDir).standardizedFileURL }
    let root =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent("SophonClientv3/manifests", isDirectory: true)
  }

  mutating func validate() throws {
    mode = mode.lowercased()
    guard mode == "full" || mode == "base" else {
      throw ValidationError("--mode must be full or base")
    }
    guard maxRetries >= 0, retryInterval >= 0 else {
      throw ValidationError("Retry counts and intervals must be nonnegative")
    }
    guard
      [
        maxConcurrentChecks, maxConcurrentDownloads, maxConcurrentPostProcessors,
        maxConcurrentWrites,
      ]
      .allSatisfy({ $0 > 0 })
    else {
      throw ValidationError("Concurrency limits must be positive")
    }
    guard refreshInterval.isFinite, refreshInterval > 0, refreshInterval <= Double(Int32.max) else {
      throw ValidationError("--refresh-interval must be positive and at most \(Int32.max) seconds")
    }
    for value in [gameIDOrBiz, directory]
      + [launcherID, manifestCacheDir, logFile].compactMap({ $0 })
      + voicePacks
    {
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("Identifiers and paths cannot be empty")
      }
    }
    for value in [baseURL, sophonBaseURL].compactMap({ $0 }) {
      guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
        ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty
      else {
        throw ValidationError("API URLs must be absolute HTTP(S) URLs")
      }
    }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
      !isDirectory.boolValue
    {
      throw ValidationError("The installation destination is not a directory")
    }
  }

  mutating func run() async throws {
    let command = self
    let terminal = InstallTerminal(plain: plain)
    let frames = AsyncStream<InstallFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let dashboard = InstallDashboard(
      title: "\(gameIDOrBiz) [\(mode)\(predownload ? ", predownload branch" : "")]",
      directory: URL(fileURLWithPath: directory).standardizedFileURL.path,
      cache: cacheURL.path, plain: !terminal.interactive, frames: frames.continuation)

    await dashboard.refresh(force: true)
    let operation = Task { await command.install(dashboard: dashboard) }
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
    if let outputError {
      throw ValidationError("Could not write installation progress: \(outputError)")
    }
    switch outcome {
    case .completed: return
    case .cancelled: throw ExitCode(130)
    case .failed: throw ExitCode.failure
    }
  }

  private func install(dashboard: InstallDashboard) async -> InstallationOutcome {
    do {
      try Task.checkCancellation()
      let apiClient = try HYPAPIClient(
        baseURL: baseURL ?? (cn ? HYPAPI_CN_BASE_URL : HYPAPI_OS_BASE_URL),
        sophonBaseURL: sophonBaseURL ?? (cn ? SOPHON_API_CN_BASE_URL : SOPHON_API_OS_BASE_URL),
        launcherID: launcherID ?? (cn ? HYPAPI_CN_LAUNCHER_ID : HYPAPI_OS_LAUNCHER_ID),
        maxRetries: maxRetries, retryInterval: retryInterval)
      let configs = try await apiClient.getGameConfigs()
      try Task.checkCancellation()
      guard let config = configs.findBy(id: gameIDOrBiz) ?? configs.findBy(biz: gameIDOrBiz) else {
        return .failed(
          reason: "No game matches ID or biz '\(gameIDOrBiz)' for the selected launcher.")
      }
      let settings = SophonClientSettings(
        baseURL: baseURL ?? (cn ? HYPAPI_CN_BASE_URL : HYPAPI_OS_BASE_URL),
        sophonBaseURL: sophonBaseURL ?? (cn ? SOPHON_API_CN_BASE_URL : SOPHON_API_OS_BASE_URL),
        maxRetries: maxRetries, retryInterval: retryInterval,
        launcherID: launcherID ?? (cn ? HYPAPI_CN_LAUNCHER_ID : HYPAPI_OS_LAUNCHER_ID),
        gameID: config.game.id, manifestCacheDir: cacheURL.path, logStdout: false, logFile: logFile,
        maxCocurrentChecks: maxConcurrentChecks, maxCocurrentDownloads: maxConcurrentDownloads,
        maxCocurrentPostProcessors: maxConcurrentPostProcessors,
        maxCocurrentWrites: maxConcurrentWrites)
      let client = try await SophonClientv3(settings, baseGameDir: URL(fileURLWithPath: directory))
      try Task.checkCancellation()
      let reporter = client.makeInstallationReporter()
      let subscription = await reporter.subscribe()
      // Own this consumer explicitly so cancelling installation does not discard its final events.
      let consumer = Task {
        for await event in subscription.events { await dashboard.record(event) }
      }
      let outcome: InstallationOutcome
      do {
        try await client.install(
          mode: mode == "full" ? .full : .base,
          additionalVoicePackMatchingFields: Set(voicePacks), predownload: predownload,
          reporter: reporter)
        outcome = .completed
      } catch {
        outcome =
          error is CancellationError || Task.isCancelled
          ? .cancelled : .failed(reason: error.localizedDescription)
      }
      // Finishing preserves buffered events, including the terminal event, for the consumer to drain.
      await reporter.unsubscribe(subscription.id)
      await consumer.value
      return outcome
    } catch {
      return error is CancellationError || Task.isCancelled
        ? .cancelled : .failed(reason: error.localizedDescription)
    }
  }
}

// Each meter measures completed work, not in-flight network traffic or physical device activity.
private struct InstallMeter {
  var value: UInt64 = 0
  var total: UInt64?
  var started: Double = 0
  var ended: Double?
  private var samples: [(time: Double, value: UInt64)] = [(0, 0)]

  var done: Bool { total.map { value >= $0 } ?? false }

  mutating func start(at time: Double) {
    started = time
    ended = done ? time : nil
    samples = [(time, value)]
  }

  mutating func setTotal(_ total: UInt64, at time: Double) {
    self.total = total
    if done { finish(at: time) }
  }

  mutating func advance(_ bytes: UInt64, at time: Double) {
    value += bytes
    if done { finish(at: time) }
  }

  mutating func sample(at time: Double) {
    guard ended == nil else { return }
    while samples.count > 1 && samples[1].time <= time - 5 { samples.removeFirst() }
    if samples.last?.time == time { samples.removeLast() }
    samples.append((time, value))
    // Also bound memory for unusually small user-specified refresh intervals.
    if samples.count > 256 { samples.removeFirst(samples.count - 256) }
  }

  mutating func finish(at time: Double) {
    guard ended == nil else { return }
    sample(at: time)
    ended = time
  }

  func rate(at time: Double) -> Double? {
    guard let first = samples.first else { return nil }
    let interval = (ended ?? time) - first.time
    guard interval >= 0.25 else { return nil }
    return Double(value - first.value) / interval
  }

  func eta(at time: Double) -> Double? {
    if done { return 0 }
    guard ended == nil, let total, let rate = rate(at: time), rate > 0 else { return nil }
    return Double(total - value) / rate
  }

  func elapsed(at time: Double) -> Double { max(0, (ended ?? time) - started) }
}

private struct InstallFrame: Sendable {
  let lines: [String]
  let force: Bool
}

private actor InstallDashboard {
  private let title: String
  private let directory: String
  private let cache: String
  private let plain: Bool
  private let frames: AsyncStream<InstallFrame>.Continuation
  private let origin = ContinuousClock.now
  private var phase: InstallationPhase = .metadata
  private var phaseStart: Double = 0
  private var durations: [InstallationPhase: Double] = [:]
  private var ended: Double?
  private var outcome: InstallationOutcome?
  private var cancelling = false
  private var lastFrame: Double = -.infinity
  private var manifests = InstallMeter()
  private var scan = InstallMeter()
  private var reads = InstallMeter()
  private var trims = InstallMeter()
  private var downloads = InstallMeter()
  private var processing = InstallMeter()
  private var writes = InstallMeter()
  private var scanChunks: UInt64 = 0
  private var totalScanChunks: Int?
  private var scannedFiles = 0
  private var totalFiles: Int?
  private var missingFiles = 0
  private var brokenFiles = 0
  private var trimFiles: UInt64 = 0
  private var completedFiles = 0
  private var downloadedChunks = 0
  private var processedBytes: UInt64 = 0
  private var retries = 0
  private var latest = "Loading game configuration and branches"
  private var notices: [String] = []

  init(
    title: String, directory: String, cache: String, plain: Bool,
    frames: AsyncStream<InstallFrame>.Continuation
  ) {
    self.title = title
    self.directory = directory
    self.cache = cache
    self.plain = plain
    self.frames = frames
  }

  private var now: Double {
    let elapsed = origin.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
  }

  func record(_ event: InstallationEvent) {
    guard outcome == nil else { return }
    let time = now
    switch event {
    case .metadataPlanned(let total):
      manifests.start(at: time)
      manifests.setTotal(UInt64(total), at: time)
    case .manifestPulled(let field, let predownload):
      manifests.advance(1, at: time)
      latest = "Loaded manifest \(field)\(predownload ? " (predownload)" : "")"
    case .scanPlanned(let files, let chunks, let bytes):
      totalFiles = files
      totalScanChunks = chunks
      scan.setTotal(bytes, at: time)
    case .fileMissing(let path, let count, let bytes):
      missingFiles += 1
      scanChunks += UInt64(count)
      scan.advance(bytes, at: time)
      latest = "Missing: \(path.path)"
    case .fileChunkScanned(let path, _, let broken, _, let bytes, let expected):
      scanChunks += 1
      scan.advance(expected, at: time)
      reads.advance(bytes, at: time)
      latest = "\(broken ? "Damaged chunk" : "Checked"): \(path.path)"
    case .fileScanned(let path, let broken, let needsTrimming):
      scannedFiles += 1
      if broken { brokenFiles += 1 }
      if needsTrimming { trimFiles += 1 }
      latest = "Scanned: \(path.path)"
    case .planned(let downloadBytes, let writeBytes, let chunks, let files):
      downloads.setTotal(downloadBytes, at: time)
      writes.setTotal(writeBytes, at: time)
      processing.setTotal(UInt64(chunks), at: time)
      totalFiles = files
    case .fileTrimmed(let path):
      trims.advance(1, at: time)
      latest = "Trimmed: \(path.path)"
    case .chunkDownloaded(let id, let bytes):
      downloads.advance(bytes, at: time)
      downloadedChunks += 1
      latest = "Downloaded: \(id)"
    case .retryScheduled(let id, let attempt, let reason):
      retries += 1
      notices.append(installText("Retry \(attempt) for \(id): \(reason)", limit: 160))
      if notices.count > 5 { notices.removeFirst() }
      latest = notices.last ?? "Retry scheduled"
    case .chunkPostProcessed(let id, _, let bytes):
      processing.advance(1, at: time)
      processedBytes += bytes
      latest = "Processed: \(id)"
    case .chunkWritten(let path, _, _, let bytes):
      writes.advance(bytes, at: time)
      latest = "Wrote: \(path.path)"
    case .fileCompleted(let path):
      completedFiles += 1
      latest = "Completed: \(path.path)"
    case .phaseChanged(let next):
      guard next != phase else { return }
      durations[phase] = time - phaseStart
      switch phase {
      case .metadata: manifests.finish(at: time)
      case .scanning:
        scan.finish(at: time)
        reads.finish(at: time)
      case .trimming: trims.finish(at: time)
      case .running: break
      }
      phase = next
      phaseStart = time
      switch next {
      case .metadata: manifests.start(at: time)
      case .scanning:
        scan.start(at: time)
        reads.start(at: time)
      case .trimming:
        trims.setTotal(trimFiles, at: time)
        trims.start(at: time)
      case .running:
        downloads.start(at: time)
        processing.start(at: time)
        writes.start(at: time)
      }
      latest = "Starting \(installPhaseName(next).lowercased())"
      refresh(force: true)
    case .finished(let result):
      finish(result, at: time)
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
    sample(at: time)
    guard force || !plain || time - lastFrame >= 1 else { return }
    lastFrame = time
    frames.yield(InstallFrame(lines: lines(at: time), force: force))
  }

  func complete(_ result: InstallationOutcome) {
    if outcome == nil { finish(result, at: now) }
    frames.yield(InstallFrame(lines: lines(at: ended ?? now), force: true))
  }

  private func finish(_ result: InstallationOutcome, at time: Double) {
    outcome = result
    ended = time
    durations[phase] = time - phaseStart
    manifests.finish(at: time)
    scan.finish(at: time)
    reads.finish(at: time)
    trims.finish(at: time)
    downloads.finish(at: time)
    processing.finish(at: time)
    writes.finish(at: time)
  }

  private func sample(at time: Double) {
    manifests.sample(at: time)
    scan.sample(at: time)
    reads.sample(at: time)
    trims.sample(at: time)
    downloads.sample(at: time)
    processing.sample(at: time)
    writes.sample(at: time)
  }

  private func stageETA(at time: Double) -> Double? {
    switch phase {
    case .metadata: return manifests.eta(at: time)
    case .scanning: return scan.eta(at: time)
    case .trimming: return trims.eta(at: time)
    case .running:
      let estimates = [downloads, processing, writes].map { $0.eta(at: time) }
      guard estimates.allSatisfy({ $0 != nil }) else { return nil }
      return estimates.compactMap { $0 }.max()
    }
  }

  private func lines(at time: Double) -> [String] {
    let status: String
    switch outcome {
    case .completed?: status = "COMPLETED"
    case .cancelled?: status = "CANCELLED"
    case .failed?: status = "FAILED"
    case nil: status = cancelling ? "CANCELLING..." : installPhaseName(phase).uppercased()
    }
    var lines = [
      "  SOPHON / INSTALL",
      "  \(installText(title, limit: 70))",
      "  Target  \(installText(directory, limit: 65))",
      "",
      "  \(status)",
      "  Stage \(installDuration(time - phaseStart))   Total \(installDuration(time))   ETA \(installDuration(stageETA(at: time)))",
      "",
    ]
    switch phase {
    case .metadata:
      lines += [
        progressRow("Manifests", manifests, at: time),
        "  Loaded  \(manifests.value) / \(manifests.total.map(String.init) ?? "—") manifests",
        "  Cache   \(installText(cache, limit: 65))",
      ]
    case .scanning:
      lines += [
        progressRow("Verify", scan, at: time),
        "  Assessed  \(installBytes(Double(scan.value))) / \(scan.total.map { installBytes(Double($0)) } ?? "—")",
        "",
        "  Chunks  \(scanChunks) / \(totalScanChunks.map(String.init) ?? "—")   Files  \(scannedFiles) / \(totalFiles.map(String.init) ?? "—")",
        "  Missing \(missingFiles)   Needing repair \(brokenFiles)",
      ]
    case .trimming:
      lines += [
        progressRow("Trim", trims, at: time), "  Trimmed  \(trims.value) / \(trimFiles) files",
      ]
    case .running:
      lines += byteRow("Download", downloads, at: time)
      lines += [
        "",
        progressRow("Process", processing, at: time),
        "  \(installColumn("\(processing.value) / \(processing.total.map(String.init) ?? "—") chunks"))\(installBytes(Double(processedBytes)))",
        "  Elapsed \(installDuration(processing.elapsed(at: time)))   ETA \(installDuration(processing.eta(at: time)))",
        "",
      ]
      lines += byteRow("Write", writes, at: time)
    }
    // Keep verification reads visible after the pipeline moves on to downloads and writes.
    lines += [
      "",
      "  Read  \(installColumn(installBytes(Double(reads.value)), width: 20))\(installSpeed(reads.rate(at: time)))\(reads.ended != nil ? "  (last rate)" : "")",
    ]
    if phase == .running {
      lines.append(
        "  Files \(completedFiles) / \(totalFiles.map(String.init) ?? "—")   Downloaded chunks \(downloadedChunks)   Retries \(retries)"
      )
    }
    if let outcome {
      if case .failed(let reason) = outcome {
        lines.append("  Error  \(installText(reason, limit: 500))")
      }
      lines.append(
        "  Assessed \(installBytes(Double(scan.value))) (\(scanChunks) chunks)   Downloaded \(installBytes(Double(downloads.value)))   Written \(installBytes(Double(writes.value)))"
      )
      lines.append(
        "  "
          + [InstallationPhase.metadata, .scanning, .trimming, .running].compactMap { phase in
            durations[phase].map {
              "\(phase == .scanning ? "Verify" : installPhaseName(phase)) \(installDuration($0))"
            }
          }.joined(separator: " | "))
    } else {
      lines.append("  Latest  \(installText(latest, limit: 65))")
      if let notice = notices.last { lines.append("  \(installText(notice, limit: 72))") }
    }
    return lines
  }

  private func byteRow(_ label: String, _ meter: InstallMeter, at time: Double) -> [String] {
    [
      progressRow(label, meter, at: time),
      "  \(installColumn("\(installBytes(Double(meter.value))) / \(meter.total.map { installBytes(Double($0)) } ?? "—")"))\(installSpeed(meter.rate(at: time)))",
      "  Elapsed \(installDuration(meter.elapsed(at: time)))   ETA \(installDuration(meter.eta(at: time)))",
    ]
  }

  private func progressRow(_ label: String, _ meter: InstallMeter, at time: Double) -> String {
    "  \(installColumn(label, width: 12))\(installBar(meter.value, meter.total, at: time, unicode: !plain))  \(installPercent(meter.value, meter.total))"
  }
}

private func installColumn(_ text: String, width: Int = 38) -> String {
  text + String(repeating: " ", count: max(2, width - text.count))
}

private func installBar(_ value: UInt64, _ total: UInt64?, at time: Double, unicode: Bool) -> String
{
  let width = 28
  let fill = unicode ? "█" : "="
  let empty = unicode ? "░" : "-"
  if let total {
    let fraction = total == 0 ? 1 : min(1, Double(value) / Double(total))
    let filled = Int(fraction * Double(width))
    return "[" + String(repeating: fill, count: filled)
      + String(repeating: empty, count: width - filled) + "]"
  }
  let step = Int(time.truncatingRemainder(dividingBy: 12) * 4) % 48
  let position = step <= 24 ? step : 48 - step
  return "[" + String(repeating: empty, count: position) + String(repeating: fill, count: 4)
    + String(repeating: empty, count: width - position - 4) + "]"
}

private func installPhaseName(_ phase: InstallationPhase) -> String {
  switch phase {
  case .metadata: return "Metadata"
  case .scanning: return "Verification"
  case .trimming: return "Trimming"
  case .running: return "Running"
  }
}

private func installBytes(_ bytes: Double) -> String {
  let units = ["B", "kB", "MB", "GB", "TB", "PB", "EB"]
  var value = max(0, bytes)
  var unit = 0
  while value >= 1000 && unit < units.count - 1 {
    value /= 1000
    unit += 1
  }
  return String(
    format: unit == 0 ? "%.0f %@" : "%.3f %@",
    locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
}

private func installSpeed(_ rate: Double?) -> String {
  guard let rate, rate.isFinite else { return "—" }
  return installBytes(rate) + "/s"
}

private func installPercent(_ value: UInt64, _ total: UInt64?) -> String {
  guard let total else { return "—" }
  let percent = total == 0 ? 100 : min(100, Double(value) / Double(total) * 100)
  return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), percent)
}

private func installDuration(_ value: Double?) -> String {
  guard let value, value.isFinite, value >= 0 else { return "—" }
  if value > 86400 { return String(format: "%.1f d", value / 86400) }
  let seconds = Int(value.rounded(.up))
  return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}

private func installText(_ value: String, limit: Int = 140) -> String {
  let safe = String(
    String.UnicodeScalarView(
      value.unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(32)! : $0
      }))
  return safe.count > limit ? String(safe.prefix(limit)) + "..." : safe
}

// Mutable terminal state and potentially blocking writes are confined to this serial queue.
private final class InstallTerminal: @unchecked Sendable {
  let interactive: Bool
  private let colors: Bool
  private let queue = DispatchQueue(label: "sophon.cli.output")
  private var previousLines = 0
  private var previousWidth = 0
  private var lastPlain: ContinuousClock.Instant?

  init(plain: Bool) {
    #if os(Windows)
      // Plain output works without assuming the console supports ANSI processing.
      interactive = false
    #else
      interactive =
        !plain && isatty(STDERR_FILENO) == 1
        && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    #endif
    colors = interactive && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
  }

  func write(_ frame: InstallFrame) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        continuation.resume(
          with: Result {
            var width = 80
            var height = 24
            #if !os(Windows)
              var size = winsize()
              if ioctl(STDERR_FILENO, UInt(TIOCGWINSZ), &size) == 0 {
                if size.ws_col > 0 { width = Int(size.ws_col) }
                if size.ws_row > 0 { height = Int(size.ws_row) }
              }
            #endif
            // Our bar glyphs are one cell; conservatively budget other Unicode by UTF-8 length.
            let lines = frame.lines.flatMap { line -> [String] in
              var result: [String] = []
              var current = ""
              var bytes = 0
              for character in line {
                let count = character == "█" || character == "░" ? 1 : String(character).utf8.count
                if bytes + count > max(1, width - 1) && !current.isEmpty {
                  result.append(current)
                  current = ""
                  bytes = 0
                }
                current.append(character)
                bytes += count
              }
              result.append(current)
              return result
            }
            let redraw = interactive && width >= 40 && lines.count < height
            let time = ContinuousClock.now
            if !redraw && !frame.force, let lastPlain,
              lastPlain.duration(to: time) < .seconds(1)
            {
              return
            }
            if width != previousWidth { previousLines = 0 }
            var output = ""
            if redraw {
              if previousLines > 0 { output += "\u{1B}[\(previousLines)F" }
              let count = max(previousLines, lines.count)
              for index in 0..<count {
                output += "\u{1B}[2K" + (index < lines.count ? styled(lines[index]) : "") + "\n"
              }
              if count > lines.count { output += "\u{1B}[\(count - lines.count)F" }
              previousLines = lines.count
            } else {
              output = lines.joined(separator: "\n") + "\n\n"
              previousLines = 0
              lastPlain = time
            }
            previousWidth = width
            try FileHandle.standardError.write(contentsOf: Data(output.utf8))
          })
      }
    }
  }

  private func styled(_ line: String) -> String {
    guard colors else { return line }
    let style: String?
    if line.hasPrefix("  SOPHON") {
      style = "1;36"
    } else if line == "  COMPLETED" {
      style = "1;32"
    } else if line == "  FAILED" || line.hasPrefix("  Error") {
      style = "1;31"
    } else if line.hasPrefix("  CANCEL") || line.hasPrefix("  Retry") {
      style = "1;33"
    } else if ["  METADATA", "  VERIFICATION", "  TRIMMING", "  RUNNING"].contains(line)
      || line.hasPrefix("  Read")
    {
      style = "1"
    } else if line.hasPrefix("  Target") || line.hasPrefix("  Stage")
      || line.hasPrefix("  Elapsed") || line.hasPrefix("  Latest")
    {
      style = "90"
    } else {
      style = nil
    }
    if let style { return "\u{1B}[\(style)m" + line + "\u{1B}[0m" }
    var output = ""
    var activeStyle = ""
    for character in line {
      let nextStyle = character == "█" ? "36" : (character == "░" ? "90" : "")
      if nextStyle != activeStyle {
        output += "\u{1B}[0m" + (nextStyle.isEmpty ? "" : "\u{1B}[\(nextStyle)m")
        activeStyle = nextStyle
      }
      output.append(character)
    }
    if !activeStyle.isEmpty { output += "\u{1B}[0m" }
    return output
  }
}

private final class InstallInterrupts {
  #if os(Windows)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cancel: (@Sendable () -> Void)?
    private static let handler: @convention(c) (UInt32) -> WindowsBool = { event in
      guard event == UInt32(CTRL_C_EVENT) || event == UInt32(CTRL_BREAK_EVENT) else { return false }
      let action = InstallInterrupts.lock.withLock { InstallInterrupts.cancel }
      action?()
      return true
    }

    init(_ action: @escaping @Sendable () -> Void) {
      Self.lock.withLock { Self.cancel = action }
      SetConsoleCtrlHandler(Self.handler, true)
    }

    deinit {
      SetConsoleCtrlHandler(Self.handler, false)
      Self.lock.withLock { Self.cancel = nil }
    }
  #else
    private let source: DispatchSourceSignal
    private let previous: (@convention(c) (Int32) -> Void)?
    private let previousPipe: (@convention(c) (Int32) -> Void)?

    init(_ action: @escaping @Sendable () -> Void) {
      previous = signal(SIGINT, SIG_IGN)
      previousPipe = signal(SIGPIPE, SIG_IGN)
      source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
      source.setEventHandler(handler: action)
      source.activate()
    }

    deinit {
      source.cancel()
      signal(SIGINT, previous)
      signal(SIGPIPE, previousPipe)
    }
  #endif
}
