public enum GameBranchCategoryScenario: String, Decodable {
  // full install or base install
  case full = "CATEGORY_SCENARIO_FULL"
  case base = "CATEGORY_SCENARIO_BASE"
}

public enum GameBranchCategoryType: String, Decodable {
  // game resource or audio package
  case resource = "CATEGORY_TYPE_RESOURCE"
  case audio = "CATEGORY_TYPE_AUDIO"
}

public struct GameBranchCategory: Decodable {
  public var category_id: String
  public var matching_field: String
  public var type: GameBranchCategoryType
  public var scenarios: [GameBranchCategoryScenario]
}

public struct GameSubBranch: Decodable {
  // Represents a single branch, either predownload or main
  public var package_id: String
  public var branch: String
  public var password: String  // password for sophon endpoint
  public var tag: String  // current version tag
  public var diff_tags: [String]  // incremental upgrade supported version
  public var categories: [GameBranchCategory]
}

public struct GameBranch: Decodable {
  public var game: GameType
  public var main: GameSubBranch
  public var pre_download: GameSubBranch?
  public var enable_base_pkg_predownload: Bool  // what is this?
}

public struct GameBranches: Decodable {
  public var game_branches: [GameBranch]

  public func getGameSubBranch(id gameID: String, predownload: Bool) -> GameSubBranch? {
    for gameBranch in game_branches {
      if gameBranch.game.id == gameID {
        return predownload ? gameBranch.pre_download : gameBranch.main
      }
    }
    return nil
  }

  public func getGameSubBranch(biz gameBiz: String, predownload: Bool) -> GameSubBranch? {
    for gameBranch in game_branches {
      if gameBranch.game.biz == gameBiz {
        return predownload ? gameBranch.pre_download : gameBranch.main
      }
    }
    return nil
  }
}
