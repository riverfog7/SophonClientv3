import Foundation

enum SophonCLIError: Error {
  case FailedToFetchGameBranchError(gameIDOrBiz: String, predownload: Bool)
}

extension SophonCLIError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .FailedToFetchGameBranchError(let game, let predownload):
      let branch = predownload ? "predownload" : "main"
      return "No \(branch) branch was found for game '\(game)'."
    }
  }
}
