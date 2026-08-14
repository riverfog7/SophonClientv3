public struct WPFPackageInfo: Decodable {
  var version: String
  var url: String
  var md5: String
  var size: String
}

public struct WPFPackage: Decodable {
  var game: GameType
  var wpf_package: WPFPackageInfo
}

public struct WPFPackages: Decodable {
  var wpf_packages: [WPFPackage]

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
