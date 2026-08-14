import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public class HYPAPIClient {
  private let baseURL: URL
  private let launcherID: String
  private let session: URLSession
  private let maxRetries: Int
  private let retryInterval: Int

  init(
    baseURL: String, launcherID: String, maxRetries: Int = 10, retryInterval: Int = 5,
    session: URLSession = .shared
  ) throws {
    guard let temp = URL(string: baseURL) else {
      throw APIClientError.InvalidBaseURL(baseURL)
    }
    self.baseURL = temp
    self.launcherID = launcherID
    self.session = session
    self.maxRetries = maxRetries
    self.retryInterval = retryInterval
  }

  private func _getAPIGetURL(route: String) -> URL {
    return baseURL.appendingPathComponent(route).appending(queryItems: [
      URLQueryItem(name: "launcher_id", value: launcherID)
    ])
  }

  private func _makeAPIGetRequest<ResponseType: Decodable>(
    endpointURL: URL
  ) async throws -> ResponseType {
    var request = URLRequest(url: endpointURL)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    var lastError: Error?

    for attempt in 0...maxRetries {
      do {
        let (data, response) = try await session.data(for: request)

        guard let response = response as? HTTPURLResponse else {
          throw APIClientError.InvalidHTTPResponse
        }

        guard (200..<300).contains(response.statusCode) else {
          throw APIClientError.BadStatusCode(response.statusCode)
        }

        let apiResponse = try JSONDecoder().decode(
          HYPAPIResponse<ResponseType>.self,
          from: data
        )

        guard apiResponse.retcode == 0 else {
          throw APIClientError.APIError(apiResponse.retcode)
        }

        return apiResponse.data
      } catch {
        lastError = error

        if attempt < maxRetries {
          try await Task.sleep(for: .seconds(retryInterval))
        }
      }
    }

    throw lastError ?? APIClientError.InvalidHTTPResponse
  }

  public func getGameBranches() async throws -> GameBranches {
    return try await _makeAPIGetRequest(endpointURL: _getAPIGetURL(route: GET_GAME_BRANCHES_ROUTE))
  }

  public func getGameConfigs() async throws -> GameConfigs {
    return try await _makeAPIGetRequest(endpointURL: _getAPIGetURL(route: GET_GAME_CONFIGS_ROUTE))
  }

  public func getGameScanInfo() async throws -> GameScanInfos {
    return try await _makeAPIGetRequest(endpointURL: _getAPIGetURL(route: GET_GAME_SCAN_INFO_ROUTE))
  }

  public func getWPFPackages() async throws -> WPFPackages {
    return try await _makeAPIGetRequest(endpointURL: _getAPIGetURL(route: GET_WPF_PACKAGES_ROUTE))
  }
}
