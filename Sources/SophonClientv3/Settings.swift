public struct SophonClientSettings: Codable {
  let baseURL: String
  let sophonBaseURL: String
  var maxRetries: Int = 10
  var retryInterval: Int = 5
  let launcherID: String
  let gameID: String
  let manifestCacheDir: String
  var logStdout: Bool = true
  var logFile: String? = nil

  var maxCocurrentChecks: Int = 8
  var maxCocurrentDownloads: Int = 8
  var maxCocurrentPostProcessors: Int = 4
  var maxCocurrentWrites: Int = 4
}
