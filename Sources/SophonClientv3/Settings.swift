struct SophonClientSettings: Codable {
  let baseURL: String
  let sophonBaseURL: String
  var maxRetries: Int = 10
  var retryInterval: Int = 5
  let launcherID: String
  let gameBiz: String
  let manifestCacheDir: String
}
