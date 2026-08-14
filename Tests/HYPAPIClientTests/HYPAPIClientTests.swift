import Testing

@testable import HYPAPIClient

@Test
func testCNAPI() async throws {
  let client = try HYPAPIClient(
    baseURL: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api", launcherID: "jGHBHlcOq1")

  _ = try await client.getGameBranches()
  _ = try await client.getGameConfigs()
  _ = try await client.getWPFPackages()
  _ = try await client.getGameScanInfo()
}

@Test
func testOSAPI() async throws {
  let client = try HYPAPIClient(
    baseURL: "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api", launcherID: "VYTpXlbWo8")

  _ = try await client.getGameBranches()
  _ = try await client.getGameConfigs()
  _ = try await client.getWPFPackages()
  _ = try await client.getGameScanInfo()
}
