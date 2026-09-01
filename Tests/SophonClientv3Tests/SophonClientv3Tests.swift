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
    #expect([0, 64].contains(fileInfo.flags), "unknown flag (not 0 or 64)")
    switch fileInfo.flags {
    case 0:  // is file
      #expect(fileInfo.size > 0, "file size should be positive int")
      #expect(fileInfo.md5.count > 0, "md5 should not be empty")
    case 64:
      #expect(fileInfo.size == 0, "dir size should be zero")
      #expect(fileInfo.md5.count == 0, "dir should not have md5")
    default:
      #expect(Bool(false), "unknown flag")
    }

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

func testManifestParse(
  baseURL: String, sophonBaseURL: String, launcherID: String, gameList: [String]
) async throws {
  let cacheDir = getTestDataPath().appendingPathComponent("manifestCache")
  for gameBiz in gameList {
    let settings = SophonClientSettings(
      baseURL: baseURL, sophonBaseURL: sophonBaseURL,
      launcherID: launcherID, gameBiz: gameBiz,
      manifestCacheDir: cacheDir.path())
    let client = try await SophonClientv3(settings)
    let subBranch = try await client.manifestManager.getGameSubbranch(predownload: false)

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

    for matchingField in (fullResourceCategory + fullAudioCategory).map({ $0.matchingField }) {
      let (manifest, _) = try await client.manifestManager.getSophonManifest(
        matchingField: matchingField)
      #expect(
        manifest.files.count > 0,
        "manifest with matching field \(matchingField) should not have no files")
      testManifestContents(manifest)
    }
  }
}

@Test
func testOSManifestParse() async throws {
  try await testManifestParse(
    baseURL: HYPAPI_OS_BASE_URL, sophonBaseURL: SOPHON_API_OS_BASE_URL,
    launcherID: HYPAPI_OS_LAUNCHER_ID, gameList: ["hkrpg_global", "hk4e_global", "nap_global"])
}

@Test
func testCNManifestParse() async throws {
  try await testManifestParse(
    baseURL: HYPAPI_CN_BASE_URL, sophonBaseURL: SOPHON_API_CN_BASE_URL,
    launcherID: HYPAPI_CN_LAUNCHER_ID, gameList: ["hkrpg_cn", "hk4e_cn", "nap_cn"])
}
