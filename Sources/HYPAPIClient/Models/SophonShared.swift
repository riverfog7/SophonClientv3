public struct SophonManifestProperty: Decodable {
  public var id: String
  public var checksum: String
  public var compressed_size: String
  public var uncompressed_size: String
}

public struct SophonDownloadInfo: Decodable {
  public var encryption: Int
  public var password: String
  public var compression: Int
  public var url_prefix: String
  public var url_suffix: String
}

public struct SophonManifestStats: Decodable {
  public var compressed_size: String
  public var uncompressed_size: String
  public var file_count: String
  public var chunk_count: String
}
