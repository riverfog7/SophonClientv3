import Foundation
import HYPAPIClient
import Testing

@testable import SophonClientv3

func getTestDataPath() -> URL {
  return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".testData")
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
