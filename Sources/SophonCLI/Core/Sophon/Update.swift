import ArgumentParser
import Foundation
import HYPAPIClient
import SophonClientv3

extension StorageIOPolicy: ExpressibleByArgument {}
extension UpdateWriteMode: ExpressibleByArgument {}

struct TransferCLIOptions: ParsableArguments, Sendable {
  @Option(help: "Fast local cache directory for resumable downloads and original snapshots.")
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
  @Flag(help: "Cache update payloads without applying patches or deleting game files.")
  var cacheOnly = false
  @Option(help: "Installation category scenario: full or base.") var mode = "full"
  @Option(help: "Maximum parallel HTTP range downloads.") var maxConcurrentDownloads = 8
  @Option(help: "Maximum file patch workers when --io-policy parallel is selected.")
  var maxConcurrentWrites = 4
  @Flag(help: "Print the selected update plan without applying it.") var plan = false
  @OptionGroup var transfer: TransferCLIOptions

  mutating func validate() throws {
    guard ["full", "base"].contains(mode), sourceVersion?.isEmpty != true,
      maxConcurrentDownloads > 0, maxConcurrentWrites > 0
    else { throw ValidationError("Invalid update scenario, source version, or worker count") }
  }

  mutating func run() async throws {
    let client = try await makeOperationClient(
      game: game, directory: directory, cn: cn, transfer: transfer.settings,
      downloads: maxConcurrentDownloads, writes: maxConcurrentWrites)
    let scenario: GameBranchCategoryScenario = mode == "base" ? .base : .full
    let sourceVersion = sourceVersion
    let predownload = predownload
    let cacheOnly = cacheOnly
    if plan {
      let plan = try await client.planUpdate(
        sourceVersion: sourceVersion, mode: scenario, predownload: predownload)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      print(String(decoding: try encoder.encode(plan), as: UTF8.self))
      return
    }
    try await runUpdateOperation(client: client) { reporter in
      try await client.update(
        sourceVersion: sourceVersion, mode: scenario, predownload: predownload,
        cacheOnly: cacheOnly, reporter: reporter)
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

private func runUpdateOperation(
  client: SophonClientv3, operation: @escaping @Sendable (UpdateReporter) async throws -> Void
) async throws {
  let reporter = client.makeUpdateReporter()
  let subscription = await reporter.subscribe()
  let progress = Task {
    for await _ in subscription.events {
      let state = await reporter.snapshot()
      print(
        "\(state.phase.rawValue): \(state.completedFiles + state.cachedFiles)/\(state.totalFiles) files, \(state.downloadedBytes) patch bytes ready"
      )
    }
  }
  let task = Task { try await operation(reporter) }
  let interrupts = InstallInterrupts { task.cancel() }
  do {
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  } catch {
    await reporter.unsubscribe(subscription.id)
    await progress.value
    await client.flushLogs()
    withExtendedLifetime(interrupts) {}
    throw error
  }
  await reporter.unsubscribe(subscription.id)
  await progress.value
  await client.flushLogs()
  withExtendedLifetime(interrupts) {}
}
