import Foundation
import HYPAPIClient
import Logging
import Puppy

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public class SophonClientv3 {
  private let gameID: String
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
    self.gameID = settings.gameID
    var puppy = Puppy()
    if settings.logStdout {
      puppy.add(ConsoleLogger("SophonClientv3.stdout"))
    }
    if let path = settings.logFile {
      puppy.add(
        try FileLogger(
          "SophonClientv3.file",
          fileURL: URL(fileURLWithPath: path).absoluteURL,
          writeMode: .print))
    }
    self.logger = Logger(label: "SophonClientv3") { [puppy] label in
      guard !puppy.loggers.isEmpty else {
        return SwiftLogNoOpLogHandler()
      }
      var handler = PuppyLogHandler(label: label, puppy: puppy)
      handler.logLevel = .info
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
  }

  public func makeInstallationReporter(id: String = UUID().uuidString) -> InstallationReporter {
    var runLogger = logger
    runLogger[metadataKey: "game.id"] = "\(gameID)"
    runLogger[metadataKey: "operation.id"] = "\(id)"

    return InstallationReporter(logger: runLogger)
  }

  private func getInstalledVoicePacks() throws -> Set<String> {
    // TODO: detect installed voice packs from the game directory instead of returning an empty set
    let _ = manifestManager.getGameLaunchConfig()
    return Set<String>()
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

      let branch = try manifestManager.getGameSubbranch(
        predownload: predownload
      )
      let resources = branch.getGameBranchCategories(
        categoryScenario: mode,
        categoryType: .resource
      )
      guard !resources.isEmpty else {
        throw SophonClientError.UnknownError(
          "No resource manifests are available for the requested installation mode."
        )
      }

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

      var seen = Set<String>()
      let matchingFields = (resources.map(\.matchingField) + voicePackMatchingFields).filter {
        seen.insert($0).inserted
      }

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
