import Foundation
import HYPAPIClient
import SwiftProtobuf

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

class CachedManifestManager {
  private let gameID: String
  private let gameBiz: String
  internal let apiClient: HYPAPIClient
  private let manifestCacheDir: URL
  private let session: URLSession
  private let maxRetries: Int
  private let retryInterval: Int

  private let gameLaunchConfig: GameLaunchConfig
  private let gameBranches: GameBranches

  internal init(
    baseURL: String, sophonBaseURL: String, launcherID: String, gameBiz: String,
    manifestCacheDir: String, maxRetries: Int = 10,
    retryInterval: Int = 5, session: URLSession = .shared
  ) async throws {
    self.session = session
    self.gameBiz = gameBiz
    self.maxRetries = maxRetries
    self.retryInterval = retryInterval
    self.apiClient = try HYPAPIClient(
      baseURL: baseURL, sophonBaseURL: sophonBaseURL, launcherID: launcherID,
      maxRetries: maxRetries, retryInterval: retryInterval, session: session)
    guard let temp = try await apiClient.getGameConfigs().findBy(biz: gameBiz) else {
      throw SophonClientError.CannotFindValidGameError(gameBiz)
    }
    gameLaunchConfig = temp
    gameID = gameLaunchConfig.game.id
    gameBranches = try await apiClient.getGameBranches()

    self.manifestCacheDir = URL(filePath: manifestCacheDir)

    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: self.manifestCacheDir.path, isDirectory: &isDirectory)
    {
      if !isDirectory.boolValue {
        throw SophonClientError.InvalidManifestCacheDirectory(
          self.manifestCacheDir.path, "Specified path is a file, not a directory")
      }
    } else {
      try FileManager.default.createDirectory(
        at: self.manifestCacheDir, withIntermediateDirectories: true)
    }
  }

  internal func getGameLaunchConfig() -> GameLaunchConfig {
    return gameLaunchConfig
  }

  internal func getGameSubbranch(predownload: Bool = false) async throws -> GameSubBranch {
    guard let subBranch = gameBranches.getGameSubBranch(id: gameID, predownload: predownload) else {
      if predownload {
        throw SophonClientError.PredownloadNotAvailableError
      }
      throw SophonClientError.UnknownError("Failed to get sophon main branch contents.")
    }

    return subBranch
  }

  internal func checkCache(key: String) throws -> Data? {
    // key should be cache data md5
    let targetPath = self.manifestCacheDir.appendingPathComponent(key)

    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: targetPath.path, isDirectory: &isDirectory) {
      if isDirectory.boolValue {
        try FileManager.default.removeItem(at: targetPath)
        return nil
      }
      let data = try Data(contentsOf: targetPath)
      if md5Hex(data) != key {
        try FileManager.default.removeItem(at: targetPath)
        return nil
      }
      return data
    }
    return nil
  }

  internal func writeCache(key: String, data: Data) throws {
    // key should be cache data md5
    let targetPath = self.manifestCacheDir.appendingPathComponent(key)

    if FileManager.default.fileExists(atPath: targetPath.path) {
      try FileManager.default.removeItem(at: targetPath)
    }
    try data.write(to: targetPath)
  }

  internal func _getManifest(manifestInfo: SophonManifestInfo) async throws -> Manifest {
    let url = try manifestInfo.getManifestDownloadURL()
    let md5Target = manifestInfo.manifest.checksum
    let isCompressed = manifestInfo.manifestDownload.compression
    let isEncrypted = manifestInfo.manifestDownload.encryption
    let password = manifestInfo.manifestDownload.password
    let compressedSize = UInt64(manifestInfo.manifest.compressedSize)
    let uncompressedSize = UInt64(manifestInfo.manifest.uncompressedSize)

    guard let cachedData = try checkCache(key: md5Target) else {
      var request = URLRequest(url: url)
      request.httpMethod = "GET"

      if isEncrypted || !password.isEmpty {
        throw SophonClientError.UnsupportedManifestConfiguration(
          "Encrypted sophon manifest not supported")
      }

      var lastError: Error?

      for attempt in 0...maxRetries {
        do {
          let (downloadData, response) = try await session.data(for: request)

          guard let response = response as? HTTPURLResponse else {
            throw SophonClientError.InvalidHTTPResponse
          }
          guard (200..<300).contains(response.statusCode) else {
            throw SophonClientError.InvalidHTTPStatus(response.statusCode)
          }

          let data: Data
          if isCompressed {
            guard UInt64(downloadData.count) == compressedSize else {
              throw SophonClientError.SizeMismatch(
                expected: compressedSize, actual: UInt64(downloadData.count))
            }
            data = try decompressZstd(downloadData, uncompressedSize: Int(uncompressedSize))
          } else {
            guard UInt64(downloadData.count) == uncompressedSize else {
              throw SophonClientError.SizeMismatch(
                expected: uncompressedSize, actual: UInt64(downloadData.count))
            }
            data = downloadData
          }

          let checksum = md5Hex(data)
          guard checksum == md5Target else {
            throw SophonClientError.InvalidChecksumError(expected: checksum, actual: md5Target)
          }

          try writeCache(key: md5Target, data: data)
          return try Manifest(serializedBytes: data)
        } catch {
          lastError = error

          if attempt < maxRetries {
            try await Task.sleep(for: .seconds(retryInterval))
          }
        }
      }

      throw lastError
        ?? SophonClientError.UnknownError(
          "Downloading manifest failed with an error but there is no error")
    }

    return try Manifest(serializedBytes: cachedData)
  }

  internal func getSophonManifest(matchingField: String, predownload: Bool = false) async throws
    -> (Manifest, SophonDownloadInfo)
  {
    // returns manifest and sophon chunk download info
    let sophonBuildInfo = try await apiClient.getSophonBuildInfo(
      getGameSubbranch(predownload: predownload))
    guard let sophonManifestInfo = sophonBuildInfo.find(matchingField) else {
      throw SophonClientError.InvalidManifestMatchingFieldError(matchingField)
    }

    return (
      try await _getManifest(manifestInfo: sophonManifestInfo), sophonManifestInfo.chunkDownload
    )
  }
}
