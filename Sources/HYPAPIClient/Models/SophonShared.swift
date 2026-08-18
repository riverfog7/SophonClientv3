import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct SophonManifestProperty: Decodable {
  public var id: String
  public var checksum: String
  public var compressedSize: String
  public var uncompressedSize: String

  enum CodingKeys: String, CodingKey {
    case id
    case checksum
    case compressedSize = "compressed_size"
    case uncompressedSize = "uncompressed_size"
  }
}

public struct SophonDownloadInfo: Decodable {
  public var encryption: Int
  public var password: String
  public var compression: Int
  public var urlPrefix: String
  public var urlSuffix: String

  enum CodingKeys: String, CodingKey {
    case encryption
    case password
    case compression
    case urlPrefix = "url_prefix"
    case urlSuffix = "url_suffix"
  }
}

public struct SophonManifestStats: Decodable {
  public var compressedSize: String
  public var uncompressedSize: String
  public var fileCount: String
  public var chunkCount: String

  enum CodingKeys: String, CodingKey {
    case compressedSize = "compressed_size"
    case uncompressedSize = "uncompressed_size"
    case fileCount = "file_count"
    case chunkCount = "chunk_count"
  }
}
