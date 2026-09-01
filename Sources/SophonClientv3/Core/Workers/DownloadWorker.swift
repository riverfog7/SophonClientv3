import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct DownloadWorker: Sendable {
  let session: URLSession
  let maxRetries: Int
  let retryInterval: Int

  private func downloadOnce(_ downloadRequest: DownloadRequest) async throws -> Data {
    let request = URLRequest(url: downloadRequest.url)
    let (data, response) = try await session.data(for: request)

    guard let response = response as? HTTPURLResponse else {
      throw SophonClientError.InvalidHTTPResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      throw SophonClientError.InvalidHTTPStatus(response.statusCode)
    }

    guard downloadRequest.size == data.count else {
      throw SophonClientError.SizeMismatch(
        expected: Int64(downloadRequest.size), actual: Int64(data.count))
    }

    let checksum = md5Hex(data)
    guard checksum == downloadRequest.md5 else {
      throw SophonClientError.InvalidChecksumError(expected: downloadRequest.md5, actual: checksum)
    }

    return data
  }

  internal func run(_ downloadRequest: DownloadRequest) async throws -> Data {
    var lastError: Error?

    for attempt in 0...maxRetries {
      do {
        return try await downloadOnce(downloadRequest)
      } catch {
        try Task.checkCancellation()

        // don't catch 4xx errors
        if let clientError = error as? SophonClientError,
          case .InvalidHTTPStatus(let code) = clientError,
          (400..<500).contains(code),
          code != 408,
          code != 429
        {
          throw error
        }

        lastError = error

        if attempt < maxRetries {
          try await Task.sleep(for: .seconds(retryInterval))
        }
      }
    }
    throw lastError
      ?? SophonClientError.UnknownError(
        "Downloading chunk failed with an error but there is no error")
  }
}
