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
  var category_id: String
  var matching_field: String
  var type: GameBranchCategoryType
  var scenarios: [GameBranchCategoryScenario]
}

public struct GameSubBranch: Decodable {
  // Represents a single branch, either predownload or main
  var package_id: String
  var branch: String
  var password: String  // password for sophon endpoint
  var tag: String  // current version tag
  var diff_tags: [String]  // incremental upgrade supported version
  var categories: [GameBranchCategory]
}

public struct GameBranch: Decodable {
  var game: GameType
  var main: GameSubBranch
  var pre_download: GameSubBranch?
  var enable_base_pkg_predownload: Bool  // what is this?
}

public struct GameBranches: Decodable {
  var game_branches: [GameBranch]

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
