import Foundation
import HYPAPIClient

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct FileAndSize: Sendable {
  let fileURL: URL
  let size: UInt64
}

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

struct InstallationPlan: Sendable {
  let totalChunkCount: Int
  let downloadSize: UInt64
  let diskWriteSize: UInt64
  let trimFiles: [FileAndSize]
  let requiredChunks: [RequiredChunk]
}

private struct ScanJob: Sendable {
  let file: FileInfo
  let downloadInfo: SophonDownloadInfo
}

private struct ScanResult: Sendable {
  let state: GameFileState
  let downloadInfo: SophonDownloadInfo
}

final class Installer: Sendable {
  let baseGameDir: URL
  let maxCocurrentChecks: Int
  let checker: ChunkCheckWorker

  internal init(baseGameDir: URL, maxCocurrentChecks: Int) throws {
    self.baseGameDir = baseGameDir
    self.checker = ChunkCheckWorker(baseGameDir: self.baseGameDir)
    self.maxCocurrentChecks = maxCocurrentChecks
    guard maxCocurrentChecks > 0 else {
      throw SophonClientError.UnknownError("MaxCocurrentChecks should be a positive integer")
    }
  }

  private func ensureSameChunk(expected chunk1: RequiredChunk, got chunk2: ChunkInfo) throws {
    guard chunk1.uncompressedMd5 == chunk2.md5,
      chunk1.compressedMd5 == chunk2.compressedMd5,
      chunk1.compressedSize == UInt64(chunk2.compressedSize),
      chunk1.uncompressedSize == UInt64(chunk2.uncompressedSize)
    else {
      throw SophonClientError.UnknownError(
        "Conflicting metadata for chunk \(chunk2.chunkID)"
      )
    }
  }

  internal func scan(installInfos: [(manifest: Manifest, chunkDownloadInfo: SophonDownloadInfo)])
    async throws
    -> InstallationPlan
  {
    // TODO: flag duplicate files between manifests
    let manifests = installInfos.map(\.manifest)
    let chunkDownloadInfos = installInfos.map(\.chunkDownloadInfo)
    guard manifests.count == chunkDownloadInfos.count else {
      throw SophonClientError.UnknownError(
        "Manifest and downloadInfo counts do not match"
      )
    }

    var manifestIndex = 0
    var fileIndex = 0
    func nextJob() -> ScanJob? {
      while manifestIndex < manifests.count {
        let files = manifests[manifestIndex].files

        if fileIndex < files.count {
          let job = ScanJob(
            file: files[fileIndex],
            downloadInfo: chunkDownloadInfos[manifestIndex]
          )
          fileIndex += 1
          return job
        }
        manifestIndex += 1
        fileIndex = 0
      }
      return nil
    }

    let checker = self.checker
    return try await withThrowingTaskGroup(
      of: ScanResult.self
    ) {
      group in
      var trimFiles: [FileAndSize] = []
      var requiredChunksByID: [String: RequiredChunk] = [:]

      for _ in 0..<maxCocurrentChecks {
        guard let job = nextJob() else {
          break
        }

        group.addTask {
          ScanResult(
            state: try await checker.run(job.file),
            downloadInfo: job.downloadInfo
          )
        }
      }

      while let result = try await group.next() {
        if let job = nextJob() {
          group.addTask {
            ScanResult(
              state: try await checker.run(job.file),
              downloadInfo: job.downloadInfo
            )
          }
        }

        if result.state.needsTrimming {
          trimFiles.append(
            FileAndSize(
              fileURL: result.state.filePath,
              size: result.state.size
            )
          )
        }

        for chunk in result.state.requiredChunks {
          let applicationInfo = ChunkApplicationInfo(
            fileURL: result.state.filePath,
            offset: chunk.offset
          )

          if var existing = requiredChunksByID[chunk.chunkID] {
            try ensureSameChunk(expected: existing, got: chunk)
            existing.chunkApplicationInfos.append(applicationInfo)
            requiredChunksByID[chunk.chunkID] = existing
          } else {
            requiredChunksByID[chunk.chunkID] = RequiredChunk(
              chunkID: chunk.chunkID,
              uncompressedMd5: chunk.md5,
              compressedMd5: chunk.compressedMd5,
              compressedSize: UInt64(chunk.compressedSize),
              uncompressedSize: UInt64(chunk.uncompressedSize),
              downloadInfo: result.downloadInfo,
              chunkApplicationInfos: [applicationInfo]
            )
          }
        }
      }

      let requiredChunks = Array(requiredChunksByID.values)
      let downloadSize = requiredChunks.reduce(0) { $0 + $1.compressedSize }
      let diskWriteSize = requiredChunks.reduce(UInt64(0)) {
        $0 + $1.uncompressedSize * UInt64($1.chunkApplicationInfos.count)
      }
      return InstallationPlan(
        totalChunkCount: requiredChunks.count,
        downloadSize: downloadSize,
        diskWriteSize: diskWriteSize,
        trimFiles: trimFiles,
        requiredChunks: requiredChunks,
      )
    }
  }
}
