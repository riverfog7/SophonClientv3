enum APIClientError: Error {
  case InvalidBaseURL(_ invalidURL: String)
  case InvalidHTTPResponse
  case BadStatusCode(_ statusCode: Int)
  case APIError(_ retCode: Int)
}
