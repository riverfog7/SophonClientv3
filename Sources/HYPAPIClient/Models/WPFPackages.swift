public struct WPFPackageInfo: Decodable {
  public var version: String
  public var url: String
  public var md5: String
  public var size: String
}

public struct WPFPackage: Decodable {
  public var game: GameType
  public var wpfPackage: WPFPackageInfo

  enum CodingKeys: String, CodingKey {
    case game
    case wpfPackage = "wpf_package"
  }
}

public struct WPFPackages: Decodable {
  public var wpfPackages: [WPFPackage]

  enum CodingKeys: String, CodingKey {
    case wpfPackages = "wpf_packages"
  }

  public func findBy(id gameID: String) -> [WPFPackageInfo] {
    var packages: [WPFPackageInfo] = []
    for package in wpfPackages {
      if package.game.id == gameID {
        packages.append(package.wpfPackage)
      }
    }
    return packages
  }

  public func findBy(biz gameBiz: String) -> [WPFPackageInfo] {
    var packages: [WPFPackageInfo] = []
    for package in wpfPackages {
      if package.game.biz == gameBiz {
        packages.append(package.wpfPackage)
      }
    }
    return packages
  }
}
