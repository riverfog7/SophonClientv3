public struct GameLaunchConfig: Decodable {
  public var game: GameType
  public var installation_dir: String
  public var exe_file_name: String
  public var audio_pkg_scan_dir: String
  public var wpf_exe_dir: String
  public var wpf_pkg_version_dir: String
  public var enable_ldiff: Bool
}

public struct GameConfigs: Decodable {
  public var launch_configs: [GameLaunchConfig]

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
