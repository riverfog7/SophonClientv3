import Foundation
import HYPAPIClient
import Logging
import Puppy

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public final class SophonClientv3: @unchecked Sendable {
  private let baseGameDir: URL
  private let gameID: String
  private let gameBiz: String
  private let logger: Logger
  private let puppy: Puppy
  private let installer: Installer
  private let updater: Updater
  private let downloadCache: DownloadCache
  private let transferSettings: TransferSettings
  internal let manifestManager: CachedManifestManager
  private let gameLaunchConfig: GameLaunchConfig

  public init(
    _ settings: SophonClientSettings,
    baseGameDir: URL
  )
    async throws
  {
    guard settings.maxRetries >= 0, settings.retryInterval >= 0,
      settings.maxCocurrentDownloads > 0, settings.transfer.entryLimit > 0,
      settings.transfer.diskLimit > 0
    else { throw SophonClientError.UnknownError("Invalid worker, retry, or cache settings") }
    self.baseGameDir = baseGameDir.standardizedFileURL.resolvingSymlinksInPath()
    self.gameID = settings.gameID
    self.transferSettings = settings.transfer
    var puppy = Puppy()
    if settings.logStdout {
      puppy.add(
        ConsoleLogger(
          "SophonClientv3.stdout",
          logFormat: SophonLogFormat(),
        ))
    }
    if let path = settings.logFile {
      puppy.add(
        try FileLogger(
          "SophonClientv3.file",
          logFormat: SophonLogFormat(),
          fileURL:
            URL(fileURLWithPath: path).absoluteURL, writeMode: .print),
      )
    }
    self.puppy = puppy
    self.logger = Logger(label: "SophonClientv3") { [puppy] label in
      guard !puppy.loggers.isEmpty else {
        return SwiftLogNoOpLogHandler()
      }
      var handler = PuppyLogHandler(label: label, puppy: puppy)
      handler.logLevel = settings.logLevel
      return handler
    }
    self.manifestManager = try await CachedManifestManager(
      baseURL: settings.baseURL, sophonBaseURL: settings.sophonBaseURL,
      launcherID: settings.launcherID, gameID: settings.gameID,
      manifestCacheDir: settings.manifestCacheDir, maxRetries: settings.maxRetries,
      retryInterval: settings.retryInterval)
    self.downloadCache = DownloadCache(
      directory: settings.transfer.cacheURL.appendingPathComponent("downloads"),
      diskLimit: settings.transfer.diskLimit,
      maxConcurrentDownloads: settings.maxCocurrentDownloads,
      maxRetries: settings.maxRetries, retryInterval: settings.retryInterval)
    self.installer = try Installer(
      baseGameDir: self.baseGameDir,
      maxCocurrentChecks: settings.transfer.ioPolicy == .serialized
        ? 1 : settings.maxCocurrentChecks,
      maxCocurrentDownloads: settings.maxCocurrentDownloads,
      maxCocurrentPostProcessors: settings.maxCocurrentPostProcessors,
      maxCocurrentWrites: settings.transfer.ioPolicy == .serialized
        ? 1 : settings.maxCocurrentWrites,
      maxRetries: settings.maxRetries,
      retryInterval: settings.retryInterval, maxCachedFileHandles: settings.maxCachedFileHandles,
      downloadCache: self.downloadCache)
    self.updater = try Updater(
      baseGameDir: self.baseGameDir, maxCocurrentDownloads: settings.maxCocurrentDownloads,
      maxCocurrentWrites: settings.maxCocurrentWrites)
    self.gameLaunchConfig = manifestManager.getGameLaunchConfig()
    self.gameBiz = gameLaunchConfig.game.biz
  }

  public func makeInstallationReporter(id: String = UUID().uuidString) -> InstallationReporter {
    var runLogger = logger
    runLogger[metadataKey: "game.id"] = "\(gameID)"
    runLogger[metadataKey: "operation.id"] = "\(id)"

    return InstallationReporter(logger: runLogger)
  }

  public func makeUpdateReporter(id: String = UUID().uuidString) -> UpdateReporter {
    var runLogger = logger
    runLogger[metadataKey: "game.id"] = "\(gameID)"
    runLogger[metadataKey: "operation.id"] = "\(id)"
    return UpdateReporter(logger: runLogger)
  }

  public func planUpdate(
    sourceVersion: String, mode: GameBranchCategoryScenario = .full, predownload: Bool = false
  ) async throws -> UpdatePlan {
    guard gameLaunchConfig.enableLdiff else {
      throw SophonClientError.UnsupportedManifestConfiguration(
        "This game does not support incremental patches")
    }
    let branch = try manifestManager.getGameSubbranch(predownload: predownload)
    if sourceVersion == branch.tag {
      return UpdatePlan(
        sourceVersion: sourceVersion, targetVersion: branch.tag, patchBundles: [], installFiles: [],
        deleteFiles: [])
    }
    guard branch.diffTags.contains(sourceVersion) else {
      throw SophonClientError.UnsupportedManifestConfiguration(
        "No update from \(sourceVersion) to \(branch.tag) is available")
    }
    let fields = try await getRequiredMatchingFields(mode: mode, predownload: predownload)
    let infos = try await manifestManager.getUpdateInfos(
      matchingFields: fields, predownload: predownload)
    return try updater.makePlan(
      sourceVersion: sourceVersion, targetVersion: branch.tag,
      installInfos: infos.install, updateInfos: infos.update)
  }

  public func update(
    sourceVersion: String, mode: GameBranchCategoryScenario = .full, reporter: UpdateReporter? = nil
  ) async throws {
    let reporter = reporter ?? makeUpdateReporter()
    do {
      await reporter.record(.phaseChanged(.metadata))
      let saved =
        transferSettings.preserveState
        ? try await Self.savedUpdateState(at: baseGameDir, settings: transferSettings) : nil
      let plan: UpdatePlan
      if let saved, !saved.finished {
        guard saved.plan.sourceVersion == sourceVersion else {
          throw SophonClientError.UnknownError(
            "Resume the unfinished update from \(saved.plan.sourceVersion) first")
        }
        plan = saved.plan
      } else {
        plan = try await planUpdate(sourceVersion: sourceVersion, mode: mode)
      }
      try await updater.execute(
        plan, settings: transferSettings, downloadCache: downloadCache, installer: installer,
        reporter: reporter)
    } catch {
      await reporter.record(
        .finished(Task.isCancelled ? .cancelled : .failed(reason: error.localizedDescription)))
      throw error
    }
  }

  public func predownload(
    sourceVersion: String, mode: GameBranchCategoryScenario = .full,
    futureBranch: Bool = true, reporter: UpdateReporter? = nil
  ) async throws {
    let reporter = reporter ?? makeUpdateReporter()
    do {
      let plan = try await planUpdate(
        sourceVersion: sourceVersion, mode: mode, predownload: futureBranch)
      try await updater.predownload(
        plan, settings: transferSettings, downloadCache: downloadCache, reporter: reporter)
    } catch {
      await reporter.record(
        .finished(Task.isCancelled ? .cancelled : .failed(reason: error.localizedDescription)))
      throw error
    }
  }

  public static func savedUpdateState(
    at directory: URL, settings: TransferSettings = TransferSettings()
  ) async throws -> SavedUpdateState? {
    let path = UpdateJournal.directory(
      settings: settings, gameDirectory: directory.standardizedFileURL.resolvingSymlinksInPath())
    return try await runTransferIO { try UpdateJournal.load(directory: path) }
  }

  public static func savedInstallationState(
    at directory: URL, settings: TransferSettings = TransferSettings()
  ) async throws -> SavedInstallationState? {
    let path = InstallationJournal.directory(
      settings: settings, gameDirectory: directory.standardizedFileURL.resolvingSymlinksInPath())
    return try await runTransferIO { try InstallationJournal.load(directory: path) }
  }

  public func flushLogs() async {
    for backend in puppy.loggers {
      await withCheckedContinuation { continuation in
        backend.flush { continuation.resume() }
      }
    }
  }

  private func getInstalledVoicePacks() throws -> Set<String> {
    let audioPkgFile = baseGameDir.appendingPathComponent(gameLaunchConfig.audioPkgScanDir)

    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: audioPkgFile.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    else {
      return []
    }

    var codes: Set<String> = []
    let contents = try String(contentsOf: audioPkgFile, encoding: .utf8)
    for line in contents.split(whereSeparator: \.isNewline) {
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedLine.isEmpty else { continue }

      guard let langCode = AUDIO_LANG_TO_CODE[trimmedLine] else {
        throw SophonClientError.UnknownError("Audio language \(trimmedLine) is not suported")
      }
      codes.insert(langCode)
    }
    return codes
  }

  private func writeInstalledVoicePacks(_ additional: Set<String>) throws {
    guard !additional.isEmpty, !gameLaunchConfig.audioPkgScanDir.isEmpty else { return }
    let languages = try getInstalledVoicePacks().union(additional).sorted().map { code in
      guard let name = AUDIO_LANG_TO_CODE.first(where: { $0.value == code })?.key else {
        throw SophonClientError.UnknownVoicePackError(code)
      }
      return name
    }
    let file = baseGameDir.appendingPathComponent(gameLaunchConfig.audioPkgScanDir)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (languages.joined(separator: "\n") + "\n").write(
      to: file, atomically: true, encoding: .utf8)
  }

  private func decodeResCategory() throws -> Set<ResCategory> {
    if gameLaunchConfig.resCategoryDir.isEmpty { return [] }
    let resCategoryDir = baseGameDir.appendingPathComponent(gameLaunchConfig.resCategoryDir)
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: resCategoryDir.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    else {
      return []
    }

    let decoder = JSONDecoder()
    var items: Set<ResCategory> = []
    var ids: Set<String> = []

    let contents = try String(contentsOf: resCategoryDir, encoding: .utf8)
    for line in contents.split(whereSeparator: \.isNewline) {
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedLine.isEmpty else { continue }

      if let data = trimmedLine.data(using: .utf8) {
        let item = try decoder.decode(ResCategory.self, from: data)
        guard ids.insert(item.category).inserted else {
          throw SophonClientError.UnknownError(
            "Duplicate resource category: \(item.category)"
          )
        }
        items.insert(item)
      }
    }
    return items
  }

  private func getRemovedMatchingFields() async throws -> Set<String> {
    var items: Set<String> = []
    for category in try decodeResCategory() {
      if category.isDelete {
        items.insert(category.category)
      }
    }
    return items
  }

  private func getRequiredMatchingFields(
    mode: GameBranchCategoryScenario, additionalVoicePackMatchingFields: Set<String> = [],
    predownload: Bool = false
  ) async throws -> Set<String> {
    let packageScenarioSupported = gameLaunchConfig.enableScenarioPkg
    if !packageScenarioSupported && mode != .full {
      throw SophonClientError.GameScenarioUnsupportedError(gameID: gameID, gameBiz: gameBiz)
    }

    let branch = try manifestManager.getGameSubbranch(
      predownload: predownload
    )
    let resources = branch.getGameBranchCategories(
      categoryScenario: mode,
      categoryType: .resource
    )

    // compute which resource category to install
    let deleted = try await getRemovedMatchingFields()
    var resourceMatchingFields: Set<String> = []
    for branchCategory in resources {
      if !deleted.contains(branchCategory.matchingField) {
        resourceMatchingFields.insert(branchCategory.matchingField)
      }
    }
    guard !resourceMatchingFields.isEmpty else {
      throw SophonClientError.UnknownError(
        "No resource manifests are available for the requested installation mode."
      )
    }

    // compute which voice packs to install
    let availableVoicePacks = Set(
      branch.categories
        .filter { $0.type == .audio }
        .map(\.matchingField)
    )
    let voicePackMatchingFields = try getInstalledVoicePacks().union(
      additionalVoicePackMatchingFields)
    for matchingField in voicePackMatchingFields {
      guard availableVoicePacks.contains(matchingField) else {
        throw SophonClientError.UnknownVoicePackError(matchingField)
      }
    }

    guard resourceMatchingFields.intersection(voicePackMatchingFields).isEmpty else {
      throw SophonClientError.UnknownError(
        "voice pack matching field overlaps with resource matching fields")
    }
    return resourceMatchingFields.union(voicePackMatchingFields)
  }

  public func install(
    mode: GameBranchCategoryScenario, additionalVoicePackMatchingFields: Set<String> = [],
    predownload: Bool = false,
    reporter: InstallationReporter? = nil
  ) async throws {
    // if reporter is not provided, create a new InstallationReporter instance
    // logging will not work if reporter does not exist
    let reporter: InstallationReporter =
      reporter ?? makeInstallationReporter()

    do {
      try Task.checkCancellation()
      await reporter.record(.phaseChanged(.metadata))
      let operationLock = try await runTransferIO { [baseGameDir] in
        try TransferFileLock(baseGameDir.appendingPathComponent(".sophon-operation.lock"))
      }
      defer { withExtendedLifetime(operationLock) {} }
      let updateDirectory = UpdateJournal.directory(
        settings: transferSettings, gameDirectory: baseGameDir)
      let update = try await runTransferIO { try UpdateJournal.load(directory: updateDirectory) }
      guard update?.finished != false else {
        throw SophonClientError.UnknownError(
          "Resume the unfinished update before starting an installation")
      }
      let directory = InstallationJournal.directory(
        settings: transferSettings, gameDirectory: baseGameDir)
      if !transferSettings.preserveState {
        try await runTransferIO { try removeOwnedFile(directory) }
      }
      let saved =
        transferSettings.preserveState
        ? try await runTransferIO { try InstallationJournal.load(directory: directory) } : nil
      let plan: InstallationPlan
      let journal: InstallationJournal?
      if let saved, !saved.finished {
        guard saved.gameID == gameID, saved.mode == mode, saved.predownload == predownload,
          saved.voicePacks == additionalVoicePackMatchingFields.sorted()
        else {
          throw SophonClientError.UnknownError(
            "Resume the unfinished installation with the same options, or use stateless verification"
          )
        }
        plan = saved.remainingPlan()
        journal = try await runTransferIO {
          try InstallationJournal(directory: directory, state: saved, resume: true)
        }
        await reporter.record(
          .planned(
            downloadBytes: plan.downloadSize, writeBytes: plan.diskWriteSize,
            totalChunk: plan.totalChunkCount, totalFile: plan.plannedFiles.count))
      } else {
        plan = try await makeInstallationPlan(
          mode: mode, voicePacks: additionalVoicePackMatchingFields, predownload: predownload,
          reporter: reporter)
        if transferSettings.preserveState {
          let version = try manifestManager.getGameSubbranch(predownload: predownload).tag
          let state = SavedInstallationState(
            gameID: gameID, version: version, mode: mode,
            voicePacks: additionalVoicePackMatchingFields.sorted(),
            predownload: predownload, plan: plan, completedApplications: [], trimmedFiles: [],
            finished: false)
          journal = try await runTransferIO {
            try InstallationJournal(directory: directory, state: state)
          }
        } else {
          journal = nil
        }
      }

      try Task.checkCancellation()
      try await installer.install(
        plan, reporter: reporter, journal: journal, finishReport: false)
      try writeInstalledVoicePacks(additionalVoicePackMatchingFields)
      try await runTransferIO(checkCancellation: false) { try journal?.complete() }
      await reporter.record(.finished(.completed))
    } catch {
      if error is CancellationError || Task.isCancelled {
        await reporter.record(.finished(.cancelled))
      } else {
        await reporter.record(
          .finished(.failed(reason: error.localizedDescription))
        )
      }

      throw error
    }

  }

  private func makeInstallationPlan(
    mode: GameBranchCategoryScenario, voicePacks: Set<String>, predownload: Bool,
    reporter: InstallationReporter
  ) async throws -> InstallationPlan {
    let matchingFields = try await getRequiredMatchingFields(
      mode: mode, additionalVoicePackMatchingFields: voicePacks, predownload: predownload)
    await reporter.record(.metadataPlanned(totalManifests: matchingFields.count))
    let manager = manifestManager
    let infos = try await withThrowingTaskGroup(of: (Manifest, SophonDownloadInfo).self) { group in
      for field in matchingFields {
        group.addTask {
          try Task.checkCancellation()
          return try await manager.getSophonManifest(
            matchingField: field, predownload: predownload, reporter: reporter)
        }
      }
      var infos: [(Manifest, SophonDownloadInfo)] = []
      for try await info in group { infos.append(info) }
      return infos
    }
    return try await installer.scan(installInfos: infos, reporter: reporter)
  }
}
