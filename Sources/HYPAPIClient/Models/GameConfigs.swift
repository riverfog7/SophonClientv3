public struct GameLaunchConfig: Codable, Sendable {
  public var game: GameType
  public var installationDir: String
  public var exeFileName: String
  public var audioPkgScanDir: String
  public var resCategoryDir: String
  public var wpfExeDir: String
  public var wpfPkgVersionDir: String
  public var enableLdiff: Bool
  public var enableScenarioPkg: Bool
  public var enableWriteVerifyResult: Bool
  public var writeVerifyResultPath: String

  enum CodingKeys: String, CodingKey {
    case game
    case installationDir = "installation_dir"
    case exeFileName = "exe_file_name"
    case audioPkgScanDir = "audio_pkg_scan_dir"
    case resCategoryDir = "res_category_dir"
    case wpfExeDir = "wpf_exe_dir"
    case wpfPkgVersionDir = "wpf_pkg_version_dir"
    case enableLdiff = "enable_ldiff"
    case enableScenarioPkg = "enable_scenario_pkg"
    case enableWriteVerifyResult = "enable_write_verify_result"
    case writeVerifyResultPath = "write_verify_result_path"
  }
}

public struct GameConfigs: Codable, Sendable {
  public var launchConfigs: [GameLaunchConfig]

  enum CodingKeys: String, CodingKey {
    case launchConfigs = "launch_configs"
  }

  public func findBy(id gameID: String) -> GameLaunchConfig? {
    for config in launchConfigs {
      if config.game.id == gameID {
        return config
      }
    }
    return nil
  }

  public func findBy(biz gameBiz: String) -> GameLaunchConfig? {
    for config in launchConfigs {
      if config.game.biz == gameBiz {
        return config
      }
    }
    return nil
  }
}
