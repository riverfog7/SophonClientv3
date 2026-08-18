public struct WPFPackageInfo: Decodable {
  public var version: String
  public var url: String
  public var md5: String
  public var size: String
}

public struct WPFPackage: Decodable {
  public var game: GameType
  public var wpf_package: WPFPackageInfo
}

public struct WPFPackages: Decodable {
  public var wpf_packages: [WPFPackage]

  public func findBy(id gameID: String) -> [WPFPackageInfo] {
    var packages: [WPFPackageInfo] = []
    for package in wpf_packages {
      if package.game.id == gameID {
        packages.append(package.wpf_package)
      }
    }
    return packages
  }

  public func findBy(biz gameBiz: String) -> [WPFPackageInfo] {
    var packages: [WPFPackageInfo] = []
    for package in wpf_packages {
      if package.game.biz == gameBiz {
        packages.append(package.wpf_package)
      }
    }
    return packages
  }
}
