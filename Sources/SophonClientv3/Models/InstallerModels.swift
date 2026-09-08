import Foundation
import HYPAPIClient

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct ChunkApplicationInfo: Sendable {
  let fileURL: URL
  let offset: UInt64
}

struct RequiredChunk: Sendable {
  let chunkID: String
  let uncompressedMd5: String
  let compressedMd5: String
  let compressedSize: UInt64
  let uncompressedSize: UInt64
  let downloadInfo: SophonDownloadInfo
  var chunkApplicationInfos: [ChunkApplicationInfo]

  internal func getDownloadURL() throws -> URL {
    return try downloadInfo.buildDownloadURL(chunkID)
  }
}

struct DownloadedChunk: Sendable {
  let chunkID: String
  let md5: String
  let size: UInt64
  let data: Data
  let downloadInfo: SophonDownloadInfo
  let chunkApplicationInfos: [ChunkApplicationInfo]
}

struct ProcessedChunk: Sendable {
  let chunkID: String
  let data: Data
  let chunkApplicationInfos: [ChunkApplicationInfo]
}

struct InstallationPlan: Sendable {
  let totalChunkCount: Int
  let downloadSize: UInt64
  let diskWriteSize: UInt64
  let requiredChunks: [RequiredChunk]
  let plannedFiles: [PlannedFile]
  var trimFiles: LazyFilterSequence<[PlannedFile]> {
    plannedFiles.lazy.filter { $0.needsTrimming }
  }
}

struct PlannedFile: Sendable {
  let fileURL: URL
  let size: UInt64
  let md5: String
  let requiredChunkCount: Int
  let needsTrimming: Bool
}

struct ScanJob: Sendable {
  let file: FileInfo
  let downloadInfo: SophonDownloadInfo
}

struct ScanResult: Sendable {
  let state: GameFileState
  let downloadInfo: SophonDownloadInfo
}
