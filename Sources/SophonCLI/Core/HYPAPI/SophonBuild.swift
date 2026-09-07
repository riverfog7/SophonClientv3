import ArgumentParser
import Foundation
import HYPAPIClient

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct SophonBuildCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "get-sophon-build",
    abstract: "Parse Sophon (patch) manifest",
    aliases: ["get-build", "build"],
  )
  @Argument(
    help: "Game ID or Game Biz.",
    completion: .list(AVAILABLE_GAME_BIZS),
  )
  var gameIDOrBiz: String

  @Flag(
    name: [.customLong("cn")],
    help: "Wether to use the CN API endpoint or the OS API endpoint. Default is false (OS).",
  )
  var isCN: Bool = false

  @Flag(
    name: [.customLong("predownload")],
    help:
      "Whether to fetch the predownload manifest or the normal manifest. Default is false (normal).",
  )
  var predownload: Bool = false

  @Option(
    name: [.customLong("output"), .customShort("o")],
    help:
      "Output file path to save the manifest. If not specified, the manifest will be printed to stdout.",
    completion: .directory,
    transform: { URL(filePath: $0) },
  )
  var outputFile: URL?

  @Flag(
    name: [.customLong("pretty"), .customLong("format")],
    help: "Whether to pretty print the manifest JSON. Default is false (compact).",
  )
  var prettyPrint: Bool = false

  @Flag(
    name: [.customLong("patch")],
    help: "Wether to fetch the patch manifest or the normal manifest. Default is false (normal).",
  )
  var isPatch: Bool = false

  mutating func run() async throws {
    let client = HYPAPIClientManager.shared.getClient(isCN: isCN)
    let gameBranches = try await client.getGameBranches()

    var temp = gameBranches.getGameSubBranch(biz: gameIDOrBiz, predownload: predownload)
    if temp == nil {
      temp = gameBranches.getGameSubBranch(id: gameIDOrBiz, predownload: predownload)
    }
    guard let gameSubBranch = temp else {
      throw SophonCLIError.FailedToFetchGameBranchError(
        gameIDOrBiz: gameIDOrBiz, predownload: predownload)
    }

    let encoder = JSONEncoder()
    let defaultFormatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.outputFormatting = defaultFormatting.union(
      prettyPrint ? [.prettyPrinted] : []
    )

    var jsonData: Data
    if isPatch {
      let info = try await client.getSophonPatchBuildInfo(gameSubBranch)
      jsonData = try encoder.encode(info)
    } else {
      let info = try await client.getSophonBuildInfo(gameSubBranch)
      jsonData = try encoder.encode(info)
    }

    if let outputFile = outputFile {
      try jsonData.write(to: outputFile)
    } else {
      print(String(data: jsonData, encoding: .utf8)!)
    }
  }
}
