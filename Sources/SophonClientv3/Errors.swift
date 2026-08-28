enum SophonClientError: Error {
  case CannotFindValidGameError(_ gameBiz: String)
  case InvalidGameBranchError(_ gameBiz: String, _ gameBranch: String)
  case InvalidManifestCacheDirectory(_ manifestCacheDir: String, _ reason: String)
  case InvalidManifestMatchingFieldError(_ matchingField: String)
  case InvalidHTTPResponse
  case InvalidHTTPStatus(_ code: Int)
  case SizeMismatch(expected: Int64, actual: Int64)
  case ZstdError(_ errString: String)
  case UnsupportedManifestConfiguration(_ reason: String)
  case UnknownError(_ reason: String)
  case PredownloadNotAvailableError
  case InvalidChecksumError(expected: String, actual: String)
}
