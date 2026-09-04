enum SophonCLIError: Error {
  case FailedToFetchGameBranchError(gameIDOrBiz: String, predownload: Bool)
}
