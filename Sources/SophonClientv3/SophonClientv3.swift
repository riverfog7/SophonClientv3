import Foundation
import HYPAPIClient

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

class SophonClientv3 {
  private let gameID: String
  private let maxRetries: Int
  private let retryInterval: Int
  internal let manifestManager: CachedManifestManager
  private let gameLaunchConfig: GameLaunchConfig

  public init(
    _ settings: SophonClientSettings
  )
    async throws
  {
    self.gameID = settings.gameID
    self.maxRetries = settings.maxRetries
    self.retryInterval = settings.retryInterval
    self.manifestManager = try await CachedManifestManager(
      baseURL: settings.baseURL, sophonBaseURL: settings.sophonBaseURL,
      launcherID: settings.launcherID, gameID: settings.gameID,
      manifestCacheDir: settings.manifestCacheDir, maxRetries: settings.maxRetries,
      retryInterval: settings.retryInterval)
    self.gameLaunchConfig = manifestManager.getGameLaunchConfig()
  }

}
