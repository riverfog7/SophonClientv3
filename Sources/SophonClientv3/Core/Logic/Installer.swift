import Foundation
import HYPAPIClient

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class Installer: Sendable {
  let baseGameDir: URL
  let checker: ChunkCheckWorker
  let downloader: DownloadWorker
  let postProcessor: ChunkPostProcessWorker

  let maxCocurrentChecks: Int
  let maxCocurrentDownloads: Int
  let maxCocurrentPostProcessors: Int

  internal init(
    baseGameDir: URL, maxCocurrentChecks: Int, maxCocurrentDownloads: Int,
    maxCocurrentPostProcessors: Int, session: URLSession = .shared, maxRetries: Int = 10,
    retryInterval: Int = 5
  ) throws {
    self.baseGameDir = baseGameDir
    self.checker = ChunkCheckWorker(baseGameDir: self.baseGameDir)
    self.downloader = DownloadWorker(
      session: session, maxRetries: maxRetries, retryInterval: retryInterval)
    self.postProcessor = ChunkPostProcessWorker()

    self.maxCocurrentChecks = maxCocurrentChecks
    self.maxCocurrentDownloads = maxCocurrentDownloads
    self.maxCocurrentPostProcessors = maxCocurrentPostProcessors
    guard maxCocurrentChecks > 0 else {
      throw SophonClientError.UnknownError("MaxCocurrentChecks should be a positive integer")
    }
    guard maxCocurrentDownloads > 0 else {
      throw SophonClientError.UnknownError("MaxCocurrentDownloads should be a positive integer")
    }
    guard maxCocurrentPostProcessors > 0 else {
      throw SophonClientError.UnknownError(
        "MaxCocurrentPostProcessors should be a positive integer")
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
    let manifests = installInfos.map(\.manifest)
    let chunkDownloadInfos = installInfos.map(\.chunkDownloadInfo)

    var fileNameSet = Set<String>()
    for manifest in manifests {
      for file in manifest.files {
        let fileName = file.filename
        if fileNameSet.contains(fileName) {
          throw SophonClientError.DuplicateFileError(fileName)
        }
        fileNameSet.insert(fileName)
      }
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
      var requiredChunksByID: [String: RequiredChunk] = [:]
      var plannedFiles: [PlannedFile] = []

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

        let state = result.state
        plannedFiles.append(
          PlannedFile(
            fileURL: state.filePath, size: state.size, md5: state.md5,
            requiredChunkCount: state.requiredChunks.count, needsTrimming: state.needsTrimming))

        for chunk in state.requiredChunks {
          let applicationInfo = ChunkApplicationInfo(
            fileURL: state.filePath,
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
        requiredChunks: requiredChunks,
        plannedFiles: plannedFiles,
      )
    }
  }

  private func download(_ chunk: RequiredChunk) async throws -> DownloadedChunk {
    guard !chunk.downloadInfo.encryption,
      chunk.downloadInfo.password.isEmpty
    else {
      throw SophonClientError.UnsupportedManifestConfiguration(
        "Encrypted chunks are not supported"
      )
    }

    let downloadURL = try chunk.getDownloadURL()
    let md5 = chunk.downloadInfo.compression ? chunk.compressedMd5 : chunk.uncompressedMd5
    let size = chunk.downloadInfo.compression ? chunk.compressedSize : chunk.uncompressedSize
    let data = try await downloader.run(DownloadRequest(url: downloadURL, md5: md5, size: size))

    return DownloadedChunk(
      md5: chunk.uncompressedMd5, size: chunk.uncompressedSize, data: data,
      downloadInfo: chunk.downloadInfo,
      chunkApplicationInfos: chunk.chunkApplicationInfos)
  }

  private func postProcess(_ chunk: DownloadedChunk) throws -> ProcessedChunk {
    if !chunk.downloadInfo.compression {
      return ProcessedChunk(data: chunk.data, chunkApplicationInfos: chunk.chunkApplicationInfos)
    }

    let data = try postProcessor.run(
      ChunkPostProcessRequest(size: chunk.size, md5: chunk.md5, data: chunk.data))
    return ProcessedChunk(data: data, chunkApplicationInfos: chunk.chunkApplicationInfos)
  }
}
