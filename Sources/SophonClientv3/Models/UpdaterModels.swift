import Foundation
import HYPAPIClient

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct PlannedDeleteFile: Sendable {
  let fileURL: URL
  let size: UInt64
}

struct PlannedPatchBundle: Sendable {
  let patchID: String
  let patchSize: UInt64
  let patchHash: String  // Checksum of the complete bundle.
  let downloadInfo: SophonDownloadInfo
  // File patches ordered by their offsets within the bundle.
  let patches: [PlannedPatch]
}

struct PlannedPatch: Sendable {
  let patchOffset: UInt64
  let patchLength: UInt64
  // No original means this payload can be applied without a source file.
  // Copy raw payloads or apply HDIFF payloads using empty input.
  let original: PlannedPatchSource?
  let target: PlannedUpdateFile
}

struct PlannedPatchSource: Sendable {
  let fileURL: URL
  let size: UInt64
  let md5: String
}

struct PlannedUpdateFile: Sendable {
  let fileURL: URL
  let size: UInt64
  let md5: String
  let installChunks: [RequiredChunk]
}

struct UpdatePlan: Sendable {
  let sourceVersion: String
  let patchBundles: [PlannedPatchBundle]
  // Full installation metadata for update targets, used for repair fallback.
  let installFiles: [PlannedUpdateFile]
  let deleteFiles: [PlannedDeleteFile]
  var patchSize: UInt64 {
    patchBundles.reduce(0) { $0 + $1.patchSize }
  }
  var installSize: UInt64 {
    installFiles.reduce(0) { $0 + $1.size }
  }
  var deleteSize: UInt64 {
    deleteFiles.reduce(0) { $0 + $1.size }
  }
}
