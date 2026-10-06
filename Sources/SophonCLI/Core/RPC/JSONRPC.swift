import Foundation
import HYPAPIClient
import SophonClientv3

indirect enum JSONValue: Codable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case integer(Int64)
  case unsigned(UInt64)
  case decimal(Double)
  case bool(Bool)
  case null

  init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let object = try? value.decode([String: JSONValue].self) {
      self = .object(object)
    } else if let array = try? value.decode([JSONValue].self) {
      self = .array(array)
    } else if let string = try? value.decode(String.self) {
      self = .string(string)
    } else if let bool = try? value.decode(Bool.self) {
      self = .bool(bool)
    } else if let integer = try? value.decode(Int64.self) {
      self = .integer(integer)
    } else if let unsigned = try? value.decode(UInt64.self) {
      self = .unsigned(unsigned)
    } else {
      self = .decimal(try value.decode(Double.self))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .object(let object): try value.encode(object)
    case .array(let array): try value.encode(array)
    case .string(let string): try value.encode(string)
    case .integer(let integer): try value.encode(integer)
    case .unsigned(let unsigned): try value.encode(unsigned)
    case .decimal(let decimal): try value.encode(decimal)
    case .bool(let bool): try value.encode(bool)
    case .null: try value.encodeNil()
    }
  }

  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }
  var object: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }
  var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  static func value<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
}

private struct RPCFailure: Error {
  let code: Int64
  let message: String
}

private struct RPCOperationParameters: Decodable, Sendable {
  let game: String
  let directory: String
  let sourceVersion: String?
  let cn: Bool
  let mode: String
  let predownload: Bool
  let cacheOnly: Bool
  let voicePacks: [String]
  let downloads: Int
  let writes: Int
  let transfer: TransferSettings

  enum CodingKeys: String, CodingKey {
    case game, directory, sourceVersion, cn, mode, predownload, cacheOnly, voicePacks, downloads,
      writes,
      transfer
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    game = try values.decode(String.self, forKey: .game)
    directory = try values.decode(String.self, forKey: .directory)
    sourceVersion = try values.decodeIfPresent(String.self, forKey: .sourceVersion)
    cn = try values.decodeIfPresent(Bool.self, forKey: .cn) ?? false
    mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? "full"
    predownload = try values.decodeIfPresent(Bool.self, forKey: .predownload) ?? false
    cacheOnly = try values.decodeIfPresent(Bool.self, forKey: .cacheOnly) ?? false
    voicePacks = try values.decodeIfPresent([String].self, forKey: .voicePacks) ?? []
    downloads = try values.decodeIfPresent(Int.self, forKey: .downloads) ?? 8
    writes = try values.decodeIfPresent(Int.self, forKey: .writes) ?? 4
    transfer =
      try values.decodeIfPresent(TransferSettings.self, forKey: .transfer) ?? TransferSettings()
    guard ["full", "base"].contains(mode), downloads > 0, writes > 0,
      transfer.entryLimit > 0, transfer.diskLimit > 0, !directory.isEmpty
    else {
      throw RPCFailure(code: -32602, message: "Invalid scenario or worker/cache count")
    }
  }
}

private struct RPCStateParameters: Decodable {
  let directory: String
  let transfer: TransferSettings?
  let operation: String?
}

actor RPCDispatcher {
  private(set) var stopping = false
  private let notify: @Sendable (JSONValue) async -> Void
  private var operations: [String: Task<Void, Never>] = [:]
  private var status: [String: JSONValue] = [:]
  private var directories: [String: String] = [:]
  private var completed: [String] = []

  init(notify: @escaping @Sendable (JSONValue) async -> Void = { _ in }) { self.notify = notify }

  func handle(_ data: Data) async -> Data? {
    let value: JSONValue
    do { value = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
      return encode(failure(id: .null, code: -32700, message: "Parse error"))
    }
    if case .array(let requests) = value {
      guard !requests.isEmpty, requests.count <= 128 else {
        return encode(
          failure(id: .null, code: -32600, message: "A batch must contain 1 to 128 requests"))
      }
      let responses = await withTaskGroup(of: JSONValue?.self) { group in
        for request in requests { group.addTask { await self.process(request) } }
        var responses: [JSONValue] = []
        for await response in group { if let response { responses.append(response) } }
        return responses
      }
      return responses.isEmpty ? nil : encode(.array(responses))
    }
    return await process(value).flatMap(encode)
  }

  private func process(_ value: JSONValue) async -> JSONValue? {
    guard let request = value.object,
      request["jsonrpc"]?.string == "2.0", let method = request["method"]?.string
    else { return failure(id: .null, code: -32600, message: "Invalid request") }
    let id = request["id"]
    if let id {
      switch id {
      case .string, .integer, .unsigned, .decimal, .null: break
      default: return failure(id: .null, code: -32600, message: "Invalid request ID")
      }
    }
    let params = request["params"] ?? .object([:])
    switch params {
    case .object, .array: break
    default: return failure(id: id ?? .null, code: -32600, message: "Parameters must be structured")
    }
    do {
      let result = try await dispatch(method, params: params)
      guard let id else { return nil }
      return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    } catch {
      guard let id else { return nil }
      if let error = error as? RPCFailure {
        return failure(id: id, code: error.code, message: error.message)
      }
      if error is DecodingError {
        return failure(id: id, code: -32602, message: "Invalid parameters")
      }
      return failure(id: id, code: -32000, message: error.localizedDescription)
    }
  }

  private func dispatch(_ method: String, params: JSONValue) async throws -> JSONValue {
    switch method {
    case "rpc.discover":
      return .object([
        "methods": .array(
          [
            "rpc.discover", "rpc.shutdown", "api.games", "api.configs", "api.branches",
            "api.scanInfo", "api.wpfPackages",
            "api.resolveGame", "api.gameInfo", "api.lookupVersion", "api.compareBranches",
            "api.checkUpdatePath",
            "api.sophonBuild", "api.sophonPatchBuild", "update.plan", "update.start",
            "game.nextAction", "game.version", "install.start", "state.inspect", "operation.status",
            "operation.wait", "operation.cancel",
          ].map(JSONValue.string))
      ])
    case "rpc.shutdown":
      await shutdown()
      return .bool(true)
    case "install.start", "update.start":
      return try start(method, params: decode(RPCOperationParameters.self, params))
    case "update.plan":
      let params = try decode(RPCOperationParameters.self, params)
      let client = try await client(params)
      return try .value(
        await client.planUpdate(
          sourceVersion: params.sourceVersion, mode: params.mode == "base" ? .base : .full,
          predownload: params.predownload))
    case "game.nextAction", "game.version":
      let parameters = try decode(RPCOperationParameters.self, params)
      let client = try await client(parameters)
      if method == "game.version" { return try .value(await client.detectInstalledVersion()) }
      return try .value(await client.nextAction())
    case "state.inspect":
      let params = try decode(RPCStateParameters.self, params)
      if params.operation == "install" {
        return try .value(
          await SophonClientv3.savedInstallationState(
            at: URL(fileURLWithPath: params.directory),
            settings: params.transfer ?? TransferSettings()))
      }
      guard params.operation == nil || params.operation == "update" else {
        throw RPCFailure(code: -32602, message: "operation must be update or install")
      }
      return try .value(
        await SophonClientv3.savedUpdateState(
          at: URL(fileURLWithPath: params.directory),
          settings: params.transfer ?? TransferSettings()))
    case "operation.status":
      let id = try operationID(params)
      guard let value = status[id] else {
        throw RPCFailure(code: -32001, message: "Unknown operation")
      }
      return value
    case "operation.wait":
      let id = try operationID(params)
      guard status[id] != nil else { throw RPCFailure(code: -32001, message: "Unknown operation") }
      if let task = operations[id] { await task.value }
      return status[id] ?? .null
    case "operation.cancel":
      let id = try operationID(params)
      guard let task = operations[id] else {
        throw RPCFailure(code: -32001, message: "Unknown operation")
      }
      task.cancel()
      return .bool(true)
    case "api.games", "api.configs", "api.branches", "api.scanInfo", "api.wpfPackages",
      "api.resolveGame", "api.gameInfo", "api.lookupVersion", "api.compareBranches",
      "api.checkUpdatePath",
      "api.sophonBuild", "api.sophonPatchBuild":
      return try await api(method, params: params)
    default: throw RPCFailure(code: -32601, message: "Method not found")
    }
  }

  private func start(_ method: String, params: RPCOperationParameters) throws -> JSONValue {
    guard !stopping else { throw RPCFailure(code: -32003, message: "RPC server is stopping") }
    let path = URL(fileURLWithPath: params.directory).standardizedFileURL.resolvingSymlinksInPath()
      .path
    guard !directories.values.contains(path) else {
      throw RPCFailure(code: -32002, message: "An operation is already using this game directory")
    }
    let id = UUID().uuidString
    directories[id] = path
    status[id] = .object(["operationID": .string(id), "status": .string("starting")])
    operations[id] = Task { await run(id: id, method: method, params: params) }
    return .object(["operationID": .string(id)])
  }

  private func run(id: String, method: String, params: RPCOperationParameters) async {
    var client: SophonClientv3?
    do {
      let operationClient = try await self.client(params)
      client = operationClient
      let mode: GameBranchCategoryScenario = params.mode == "base" ? .base : .full
      if method == "install.start" {
        let reporter = operationClient.makeInstallationReporter(id: id)
        let subscription = await reporter.subscribe()
        let forwarding = Task {
          for await _ in subscription.events {
            let snapshot = await reporter.snapshot()
            let value: JSONValue = .object([
              "phase": .string(snapshot.phase.rawValue),
              "downloadedBytes": .unsigned(snapshot.downloadedBytes),
              "writtenBytes": .unsigned(snapshot.writtenBytes),
              "completedFiles": .integer(Int64(snapshot.completedFiles)),
              "totalFiles": snapshot.totalFile.map { .integer(Int64($0)) } ?? .null,
            ])
            await self.progress(id, value: value)
          }
        }
        do {
          try await operationClient.install(
            mode: mode, additionalVoicePackMatchingFields: Set(params.voicePacks),
            predownload: params.predownload, reporter: reporter)
        } catch {
          await reporter.unsubscribe(subscription.id)
          await forwarding.value
          throw error
        }
        await reporter.unsubscribe(subscription.id)
        await forwarding.value
      } else {
        let reporter = operationClient.makeUpdateReporter(id: id)
        let subscription = await reporter.subscribe()
        let forwarding = Task {
          for await _ in subscription.events {
            let value = try? JSONValue.value(await reporter.snapshot())
            if let value { await self.progress(id, value: value) }
          }
        }
        do {
          try await operationClient.update(
            sourceVersion: params.sourceVersion, mode: mode, predownload: params.predownload,
            cacheOnly: params.cacheOnly, reporter: reporter)
        } catch {
          await reporter.unsubscribe(subscription.id)
          await forwarding.value
          throw error
        }
        await reporter.unsubscribe(subscription.id)
        await forwarding.value
      }
      await finish(id, outcome: "completed")
    } catch {
      await finish(
        id, outcome: Task.isCancelled ? "cancelled" : "failed", error: error.localizedDescription)
    }
    await client?.flushLogs()
    directories.removeValue(forKey: id)
    operations.removeValue(forKey: id)
  }

  private func progress(_ id: String, value: JSONValue) async {
    status[id] = .object([
      "operationID": .string(id), "status": .string("running"), "progress": value,
    ])
    await notify(
      .object([
        "jsonrpc": .string("2.0"), "method": .string("operation.progress"), "params": status[id]!,
      ]))
  }

  private func finish(_ id: String, outcome: String, error: String? = nil) async {
    var value = status[id]?.object ?? [:]
    value["status"] = .string(outcome)
    if let error { value["error"] = .string(error) }
    status[id] = .object(value)
    completed.append(id)
    while completed.count > 128 { status.removeValue(forKey: completed.removeFirst()) }
    await notify(
      .object([
        "jsonrpc": .string("2.0"), "method": .string("operation.finished"),
        "params": .object(value),
      ]))
  }

  func shutdown() async {
    stopping = true
    let tasks = Array(operations.values)
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
  }

  private func client(_ params: RPCOperationParameters) async throws -> SophonClientv3 {
    try await makeOperationClient(
      game: params.game, directory: params.directory, cn: params.cn,
      transfer: params.transfer, downloads: params.downloads, writes: params.writes)
  }

  private func api(_ method: String, params: JSONValue) async throws -> JSONValue {
    guard let values = params.object else {
      throw RPCFailure(code: -32602, message: "Expected named parameters")
    }
    let cn = values["cn"]?.bool ?? false
    let api = HYPAPIClientManager.shared.getClient(isCN: cn)
    let language = values["language"]?.string ?? (cn ? "zh-cn" : "en-us")
    switch method {
    case "api.games", "api.resolveGame":
      var identities = gameIdentities(try await api.getGames(language: language))
      if method == "api.resolveGame" {
        guard let query = values["query"]?.string ?? values["game"]?.string else {
          throw RPCFailure(code: -32602, message: "query is required")
        }
        let byID = identities.filter { $0.id == query }
        let byBiz = identities.filter { $0.biz == query }
        identities =
          !byID.isEmpty
          ? byID
          : !byBiz.isEmpty
            ? byBiz
            : identities.filter {
              $0.name.caseInsensitiveCompare(query) == .orderedSame
            }
      } else if let search = values["search"]?.string {
        identities = identities.filter {
          [$0.name, $0.biz, $0.id, $0.server ?? ""].contains {
            $0.localizedCaseInsensitiveContains(search)
          }
        }
      }
      return try .value(identities)
    case "api.configs":
      var configs = try await api.getGameConfigs()
      if let game = values["game"]?.string {
        configs.launchConfigs = [try resolveHYPGame(game, in: configs)]
      }
      return try .value(configs)
    case "api.branches":
      var branches = try await api.getGameBranches()
      if let game = values["game"]?.string {
        let config = try resolveHYPGame(game, in: await api.getGameConfigs())
        branches.gameBranches = branches.gameBranches.filter { $0.game.id == config.game.id }
      }
      return try .value(branches)
    case "api.scanInfo":
      var info = try await api.getGameScanInfo()
      if let game = values["game"]?.string {
        let config = try resolveHYPGame(game, in: await api.getGameConfigs())
        info.gameScanInfo = info.gameScanInfo.filter { $0.gameID == config.game.id }
      }
      if let version = values["version"]?.string {
        for index in info.gameScanInfo.indices {
          info.gameScanInfo[index].gameExeList = info.gameScanInfo[index].gameExeList.filter {
            $0.version == version
          }
        }
        info.gameScanInfo.removeAll { $0.gameExeList.isEmpty }
      }
      return try .value(info)
    case "api.wpfPackages":
      var packages = try await api.getWPFPackages()
      if let game = values["game"]?.string {
        let config = try resolveHYPGame(game, in: await api.getGameConfigs())
        packages.wpfPackages = packages.wpfPackages.filter { $0.game.id == config.game.id }
      }
      if let version = values["version"]?.string {
        packages.wpfPackages = packages.wpfPackages.filter { $0.wpfPackage.version == version }
      }
      if values["urlsOnly"]?.bool == true {
        return try .value(packages.wpfPackages.map { $0.wpfPackage.url.absoluteString })
      }
      return try .value(packages)
    default:
      guard let game = values["game"]?.string else {
        throw RPCFailure(code: -32602, message: "game is required")
      }
      if method == "api.gameInfo" {
        return try .value(await gameInfo(game, client: api, language: language))
      }
      if method == "api.compareBranches" {
        return try .value(await compareBranches(game, client: api))
      }
      let config = try resolveHYPGame(game, in: await api.getGameConfigs())
      if method == "api.lookupVersion" {
        guard let md5 = values["md5"]?.string, md5.utf8.count == 32,
          md5.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
          })
        else {
          throw RPCFailure(code: -32602, message: "md5 must contain 32 hexadecimal characters")
        }
        let info = try await api.getGameScanInfo()
        return try .value(
          info.gameScanInfo.filter { $0.gameID == config.game.id }
            .flatMap(\.gameExeList).filter { $0.md5.lowercased() == md5.lowercased() })
      }
      let branches = try await api.getGameBranches()
      guard
        let branch = branches.getGameSubBranch(
          id: config.game.id, predownload: values["predownload"]?.bool ?? false)
      else {
        throw RPCFailure(code: -32000, message: "Requested branch is unavailable")
      }
      if method == "api.checkUpdatePath" {
        guard let version = values["sourceVersion"]?.string, !version.isEmpty else {
          throw RPCFailure(code: -32602, message: "sourceVersion is required")
        }
        return .object([
          "id": .string(config.game.id), "biz": .string(config.game.biz),
          "fromVersion": .string(version), "targetVersion": .string(branch.tag),
          "predownload": .bool(values["predownload"]?.bool ?? false),
          "status": .string(
            version == branch.tag
              ? "already-current"
              : branch.diffTags.contains(version) ? "direct-update-advertised" : "not-advertised"),
        ])
      }
      if method == "api.sophonPatchBuild" {
        return try .value(await api.getSophonPatchBuildInfo(branch))
      }
      return try .value(await api.getSophonBuildInfo(branch))
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, _ params: JSONValue) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(params))
  }

  private func operationID(_ params: JSONValue) throws -> String {
    guard let id = params.object?["operationID"]?.string else {
      throw RPCFailure(code: -32602, message: "operationID is required")
    }
    return id
  }

  private func failure(id: JSONValue, code: Int64, message: String) -> JSONValue {
    .object([
      "jsonrpc": .string("2.0"), "id": id,
      "error": .object(["code": .integer(code), "message": .string(message)]),
    ])
  }

  private func encode(_ value: JSONValue) -> Data? { try? JSONEncoder().encode(value) }
}
