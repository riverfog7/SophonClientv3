import Foundation
import HYPAPIClient
import Testing

@testable import SophonClientv3

func getTestDataPath() -> URL {
  return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".testData")
}

func testManifestContents(_ manifest: Manifest) {
  for fileInfo in manifest.files {
    for chunkInfo in fileInfo.chunks {
      #expect(chunkInfo.chunkID.count > 0, "chunk ID should exist")
      #expect(chunkInfo.md5.count > 0, "chunk uncompressed md5 should exist")
      #expect(chunkInfo.compressedSize > 0, "chunk compressed size should be positive")
      #expect(chunkInfo.uncompressedSize > 0, "chunk uncompressed size should be positive")
      #expect(chunkInfo.compressedMd5.count > 0, "chunk compressed md5 should exist")
      #expect(
        UInt64(chunkInfo.uncompressedSize) + chunkInfo.offset <= UInt64(fileInfo.size),
        "chunk should be within file")
    }
  }
}

func testDiffManifestContents(_ manifest: DiffManifest) {
  for fileInfo in manifest.files {
    #expect(fileInfo.filename.count > 0, "file name should exist")
    #expect(fileInfo.size >= 0, "file size should not be negative")
    #expect(fileInfo.hash.count > 0, "file hash should exist")
    for patch in fileInfo.patches {
      #expect(patch.key.count > 0, "patch source version should exist")
      #expect(patch.hasInfo, "patch info should exist")
      #expect(patch.info.patchOffset >= 0, "patch offset should not be negative")
      #expect(patch.info.patchLength >= 0, "patch length should not be negative")
      #expect(
        patch.info.patchOffset + patch.info.patchLength <= patch.info.patchSize,
        "patch should be within the diff file")
    }
  }

  for deleteFile in manifest.filesDelete {
    #expect(deleteFile.key.count > 0, "delete source version should exist")
    #expect(deleteFile.hasInfo, "delete info should exist")
    for fileInfo in deleteFile.info.list {
      #expect(fileInfo.filename.count > 0, "delete file name should exist")
      #expect(fileInfo.size >= 0, "delete file size should not be negative")
      #expect(fileInfo.hash.count > 0, "delete file hash should exist")
    }
  }
}

func testDiffManifestParse(
  baseURL: String, sophonBaseURL: String, launcherID: String, gameList: [String]
) async throws {
  let cacheDir = getTestDataPath().appendingPathComponent("manifestCache")
  for gameID in gameList {
    let manager = try await CachedManifestManager(
      baseURL: baseURL, sophonBaseURL: sophonBaseURL, launcherID: launcherID,
      gameID: gameID, manifestCacheDir: cacheDir.path())
    let subBranch = try manager.getGameSubbranch(predownload: false)
    let patchBuildInfo = try await manager.apiClient.getSophonPatchBuildInfo(subBranch)
    #expect(patchBuildInfo.manifests.count > 0, "patch manifests should exist")

    for manifestInfo in patchBuildInfo.manifests {
      let (manifest, diffDownloadInfo) = try await manager.getSophonPatchManifest(
        matchingField: manifestInfo.matchingField)
      #expect(
        manifest.files.count > 0 || manifest.filesDelete.count > 0,
        "manifest with matching field \(manifestInfo.matchingField) should not be empty")
      #expect(diffDownloadInfo.urlPrefix == manifestInfo.diffDownload.urlPrefix)
      #expect(diffDownloadInfo.urlSuffix == manifestInfo.diffDownload.urlSuffix)
      testDiffManifestContents(manifest)
    }
  }
}

func testManifestParse(
  baseURL: String, sophonBaseURL: String, launcherID: String, gameList: [String]
) async throws {
  let cacheDir = getTestDataPath().appendingPathComponent("manifestCache")
  let installerTempDir = getTestDataPath().appendingPathComponent(
    "installerTemp-\(UUID().uuidString)")
  for gameID in gameList {
    let settings = SophonClientSettings(
      baseURL: baseURL, sophonBaseURL: sophonBaseURL,
      launcherID: launcherID, gameID: gameID,
      manifestCacheDir: cacheDir.path())
    let client = try await SophonClientv3(settings, baseGameDir: installerTempDir)
    let subBranch = try client.manifestManager.getGameSubbranch(predownload: false)

    let fullResourceCategory = subBranch.getGameBranchCategories(
      categoryScenario: GameBranchCategoryScenario.full,
      categoryType: GameBranchCategoryType.resource)
    let fullAudioCategory = subBranch.getGameBranchCategories(
      categoryScenario: GameBranchCategoryScenario.full, categoryType: GameBranchCategoryType.audio)

    for resource in fullAudioCategory {
      #expect(
        !fullResourceCategory.contains(where: { $0.matchingField == resource.matchingField }),
        "audio category and resource category must not overlap")
    }

    var installInfos: [(manifest: Manifest, chunkDownloadInfo: SophonDownloadInfo)] = []
    for matchingField in (fullResourceCategory + fullAudioCategory).map({ $0.matchingField }) {
      let (manifest, chunkDownloadInfo) = try await client.manifestManager.getSophonManifest(
        matchingField: matchingField)
      installInfos.append((manifest, chunkDownloadInfo))
      #expect(
        manifest.files.count > 0,
        "manifest with matching field \(matchingField) should not have no files")
      testManifestContents(manifest)

      if FileManager.default.fileExists(atPath: installerTempDir.path()) {
        try FileManager.default.removeItem(at: installerTempDir)
      }
      try FileManager.default.createDirectory(
        at: installerTempDir, withIntermediateDirectories: true)
    }
    try checkManifests(installInfos.map { $0.manifest })

    let installer = try Installer(
      baseGameDir: installerTempDir, maxCocurrentChecks: 8, maxCocurrentDownloads: 8,
      maxCocurrentPostProcessors: 8, maxCocurrentWrites: 8)
    let installationPlan = try await installer.scan(installInfos: installInfos)
    print("total chunk count for \(gameID): \(installationPlan.totalChunkCount)")
    print(
      "download size for \(gameID): \(Double(installationPlan.downloadSize) / 1_073_741_824) GiB")
    print(
      "disk write size for \(gameID): \(Double(installationPlan.diskWriteSize) / 1_073_741_824) GiB"
    )
  }
  try? FileManager.default.removeItem(at: installerTempDir)
}

@Test
func testOSManifestParse() async throws {
  try await testManifestParse(
    baseURL: HYPAPI_OS_BASE_URL, sophonBaseURL: SOPHON_API_OS_BASE_URL,
    launcherID: HYPAPI_OS_LAUNCHER_ID,
    gameList: [
      "U5hbdsT9W7",
      "4ziysqXOQ8",
      "gopR6Cufr3",
      "5TIVvvcwtM",
      "g0mMIvshDb",
      "uxB4MC7nzC",
      "bxPTXSET5t",
      "wkE5P5WsIf",
    ])
}

@Test
func testCNManifestParse() async throws {
  try await testManifestParse(
    baseURL: HYPAPI_CN_BASE_URL, sophonBaseURL: SOPHON_API_CN_BASE_URL,
    launcherID: HYPAPI_CN_LAUNCHER_ID,
    gameList: [
      "x6znKlJ0xK",
      "64kMb5iAWu",
      "1Z8W5NHUQb",
      "osvnlOc0S8",
    ])
}

@Test
func testOSDiffManifestParse() async throws {
  try await testDiffManifestParse(
    baseURL: HYPAPI_OS_BASE_URL, sophonBaseURL: SOPHON_API_OS_BASE_URL,
    launcherID: HYPAPI_OS_LAUNCHER_ID,
    gameList: [
      "U5hbdsT9W7",
      "4ziysqXOQ8",
      "gopR6Cufr3",
    ])
}

@Test
func testCNDiffManifestParse() async throws {
  try await testDiffManifestParse(
    baseURL: HYPAPI_CN_BASE_URL, sophonBaseURL: SOPHON_API_CN_BASE_URL,
    launcherID: HYPAPI_CN_LAUNCHER_ID,
    gameList: [
      "x6znKlJ0xK",
      "64kMb5iAWu",
      "1Z8W5NHUQb",
    ])
}
