public struct GameLaunchConfig: Decodable {
  var game: GameType
  var installation_dir: String
  var exe_file_name: String
  var audio_pkg_scan_dir: String
  var wpf_exe_dir: String
  var wpf_pkg_version_dir: String
  var enable_ldiff: Bool
}

public struct GameConfigs: Decodable {
  var launch_configs: [GameLaunchConfig]

  public func findBy(id gameID: String) -> GameLaunchConfig? {
    for config in launch_configs {
      if config.game.id == gameID {
        return config
      }
    }
    return nil
  }

  public func findBy(biz gameBiz: String) -> GameLaunchConfig? {
    for config in launch_configs {
      if config.game.biz == gameBiz {
        return config
      }
    }
    return nil
  }
}
