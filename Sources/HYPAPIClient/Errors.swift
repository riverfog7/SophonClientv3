enum APIClientError: Error {
  case InvalidHTTPResponse
  case BadStatusCode(_ statusCode: Int)
  case APIError(_ retCode: Int)
}

enum ValidationError: Error {
  case StringConversionError(_ badString: String)
  case InvalidURL(_ invalidURL: String)
  case InvalidRetCode(_ invalidRetCode: Int)
}
