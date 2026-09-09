import ArgumentParser

struct HYPAPIClientEntrypoint: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "api",
    abstract: "HYP API client",
    subcommands: [
      SophonBuildCLI.self, GamesCLI.self, GameConfigsCLI.self, GameBranchesCLI.self,
      GameScanInfoCLI.self, WPFPackagesCLI.self,
    ],
  )
}
