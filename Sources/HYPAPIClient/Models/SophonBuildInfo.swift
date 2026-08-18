public struct SophonManifestInfo: Decodable {
  public var category_id: String
  public var category_name: String
  public var manifest: SophonManifestProperty
  public var chunk_download: SophonDownloadInfo
  public var manifest_download: SophonDownloadInfo
  public var matching_field: String
  public var stats: SophonManifestStats
  public var deduplicated_stats: SophonManifestStats
}

public struct SophonBuildInfo: Decodable {
  public var build_id: String
  public var tag: String
  public var manifests: [SophonManifestInfo]
}
