import Foundation
import HYPAPIClient
import Logging
import Puppy

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public class SophonClientv3 {
  private let baseGameDir: URL
  private let gameID: String
  private let gameBiz: String
  private let logger: Logger
  private let installer: Installer
  internal let manifestManager: CachedManifestManager
  private let gameLaunchConfig: GameLaunchConfig

  public init(
    _ settings: SophonClientSettings,
    baseGameDir: URL
  )
    async throws
  {
    self.baseGameDir = baseGameDir
    self.gameID = settings.gameID
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
    self.installer = try Installer(
      baseGameDir: baseGameDir, maxCocurrentChecks: settings.maxCocurrentChecks,
      maxCocurrentDownloads: settings.maxCocurrentDownloads,
      maxCocurrentPostProcessors: settings.maxCocurrentPostProcessors,
      maxCocurrentWrites: settings.maxCocurrentWrites, maxRetries: settings.maxRetries,
      retryInterval: settings.retryInterval)
    self.gameLaunchConfig = manifestManager.getGameLaunchConfig()
    self.gameBiz = gameLaunchConfig.game.biz
  }

  public func makeInstallationReporter(id: String = UUID().uuidString) -> InstallationReporter {
    var runLogger = logger
    runLogger[metadataKey: "game.id"] = "\(gameID)"
    runLogger[metadataKey: "operation.id"] = "\(id)"

    return InstallationReporter(logger: runLogger)
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

  private func getRemovedCategoryIDs() async throws -> Set<String> {
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
    let deleted = try await getRemovedCategoryIDs()
    var resourceMatchingFields: Set<String> = []
    for branchCategory in resources {
      if !deleted.contains(branchCategory.categoryID) {
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
    reporter: (any OperationReporting<InstallationEvent>)? = nil
  ) async throws {
    // if reporter is not provided, create a new InstallationReporter instance
    // logging will not work if reporter does not exist
    let reporter: any OperationReporting<InstallationEvent> =
      reporter ?? makeInstallationReporter()

    var installInfos: [(manifest: Manifest, chunkDownloadInfo: SophonDownloadInfo)] = []
    do {
      try Task.checkCancellation()
      await reporter.record(.phaseChanged(.metadata))

      let matchingFields = try await getRequiredMatchingFields(
        mode: mode, additionalVoicePackMatchingFields: additionalVoicePackMatchingFields,
        predownload: predownload)

      await reporter.record(.metadataPlanned(totalManifests: matchingFields.count))
      for matchingField in matchingFields {
        try Task.checkCancellation()

        let info = try await manifestManager.getSophonManifest(
          matchingField: matchingField,
          predownload: predownload,
          reporter: reporter
        )

        installInfos.append(info)
      }
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

    try await installer.install(
      installInfos: installInfos,
      reporter: reporter
    )
  }
}
