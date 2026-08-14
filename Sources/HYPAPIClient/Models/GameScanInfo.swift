public struct GameExecutableInfo: Decodable {
  var version: String
  var md5: String
}

public struct GameScanInfo: Decodable {
  var game_id: String
  var game_exe_list: [GameExecutableInfo]
}

public struct GameScanInfos: Decodable {
  var game_scan_info: [GameScanInfo]

  public func getVersion(id gameID: String, md5: String) -> String? {
    for scanInfo in game_scan_info {
      if scanInfo.game_id == gameID {
        for exeInfo in scanInfo.game_exe_list {
          if exeInfo.md5 == md5 { return exeInfo.version }
        }
      }
    }
    return nil
  }
}
