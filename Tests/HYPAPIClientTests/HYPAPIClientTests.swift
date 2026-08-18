import Testing

@testable import HYPAPIClient

@Test
func testCNAPI() async throws {
  let client = try HYPAPIClient(
    baseURL: HYPAPI_CN_BASE_URL, launcherID: HYPAPI_CN_LAUNCHER_ID)

  let gameBranches = try await client.getGameBranches()
  #expect(gameBranches.game_branches.count > 0)
  #expect(gameBranches.getGameSubBranch(biz: "nap_cn", predownload: false) != nil)
  #expect(gameBranches.getGameSubBranch(biz: "hkrpg_cn", predownload: false) != nil)
  #expect(gameBranches.getGameSubBranch(biz: "hk4e_cn", predownload: false) != nil)
  #expect(gameBranches.getGameSubBranch(biz: "bh3_cn", predownload: false) != nil)
  let gameConfigs = try await client.getGameConfigs()
  #expect(gameConfigs.launch_configs.count > 0)
  #expect(gameConfigs.findBy(biz: "nap_cn") != nil)
  #expect(gameConfigs.findBy(biz: "hkrpg_cn") != nil)
  #expect(gameConfigs.findBy(biz: "hk4e_cn") != nil)
  #expect(gameConfigs.findBy(biz: "bh3_cn") != nil)
  let wpfPackages = try await client.getWPFPackages()
  #expect(wpfPackages.wpf_packages.count > 0)
  #expect(wpfPackages.findBy(biz: "hk4e_cn").count > 0)
  let gameScanInfo = try await client.getGameScanInfo()
  #expect(gameScanInfo.game_scan_info.count > 0)
}

@Test
func testOSAPI() async throws {
  let client = try HYPAPIClient(
    baseURL: HYPAPI_OS_BASE_URL, launcherID: HYPAPI_OS_LAUNCHER_ID)

  let gameBranches = try await client.getGameBranches()
  #expect(gameBranches.getGameSubBranch(biz: "nap_global", predownload: false) != nil)
  #expect(gameBranches.getGameSubBranch(biz: "hkrpg_global", predownload: false) != nil)
  #expect(gameBranches.getGameSubBranch(biz: "hk4e_global", predownload: false) != nil)
  #expect(gameBranches.getGameSubBranch(biz: "bh3_global", predownload: false) != nil)
  let gameConfigs = try await client.getGameConfigs()
  #expect(gameConfigs.findBy(biz: "nap_global") != nil)
  #expect(gameConfigs.findBy(biz: "hkrpg_global") != nil)
  #expect(gameConfigs.findBy(biz: "hk4e_global") != nil)
  #expect(gameConfigs.findBy(biz: "bh3_global") != nil)
  let wpfPackages = try await client.getWPFPackages()
  #expect(wpfPackages.wpf_packages.count > 0)
  #expect(wpfPackages.findBy(biz: "hk4e_global").count > 0)
  let gameScanInfo = try await client.getGameScanInfo()
  #expect(gameScanInfo.game_scan_info.count > 0)
}
