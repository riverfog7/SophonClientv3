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
  public var categoryID: String
  public var matchingField: String
  public var type: GameBranchCategoryType
  public var scenarios: [GameBranchCategoryScenario]

  enum CodingKeys: String, CodingKey {
    case categoryID = "category_id"
    case matchingField = "matching_field"
    case type
    case scenarios
  }
}

public struct GameSubBranch: Decodable {
  // Represents a single branch, either predownload or main
  public var packageID: String
  public var branch: String
  public var password: String  // password for sophon endpoint
  public var tag: String  // current version tag
  public var diffTags: [String]  // incremental upgrade supported version
  public var categories: [GameBranchCategory]

  enum CodingKeys: String, CodingKey {
    case packageID = "package_id"
    case branch
    case password
    case tag
    case diffTags = "diff_tags"
    case categories
  }
}

public struct GameBranch: Decodable {
  public var game: GameType
  public var main: GameSubBranch
  public var preDownload: GameSubBranch?
  public var enableBasePkgPredownload: Bool  // what is this?

  enum CodingKeys: String, CodingKey {
    case game
    case main
    case preDownload = "pre_download"
    case enableBasePkgPredownload = "enable_base_pkg_predownload"
  }
}

public struct GameBranches: Decodable {
  public var gameBranches: [GameBranch]

  enum CodingKeys: String, CodingKey {
    case gameBranches = "game_branches"
  }

  public func getGameSubBranch(id gameID: String, predownload: Bool) -> GameSubBranch? {
    for gameBranch in gameBranches {
      if gameBranch.game.id == gameID {
        return predownload ? gameBranch.preDownload : gameBranch.main
      }
    }
    return nil
  }

  public func getGameSubBranch(biz gameBiz: String, predownload: Bool) -> GameSubBranch? {
    for gameBranch in gameBranches {
      if gameBranch.game.biz == gameBiz {
        return predownload ? gameBranch.preDownload : gameBranch.main
      }
    }
    return nil
  }
}
