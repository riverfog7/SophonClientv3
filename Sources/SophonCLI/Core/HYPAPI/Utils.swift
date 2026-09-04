import HYPAPIClient

internal final class HYPAPIClientManager: Sendable {
  public static let shared = HYPAPIClientManager()

  public let cnClient: HYPAPIClient
  public let osClient: HYPAPIClient

  private init() {
    cnClient = try! HYPAPIClient(
      baseURL: HYPAPI_CN_BASE_URL, sophonBaseURL: SOPHON_API_CN_BASE_URL,
      launcherID: HYPAPI_CN_LAUNCHER_ID)
    osClient = try! HYPAPIClient(
      baseURL: HYPAPI_OS_BASE_URL, sophonBaseURL: SOPHON_API_OS_BASE_URL,
      launcherID: HYPAPI_OS_LAUNCHER_ID)
  }

  public func getClient(isCN: Bool) -> HYPAPIClient {
    return isCN ? cnClient : osClient
  }
}
