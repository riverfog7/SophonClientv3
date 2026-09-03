import AsyncAlgorithms
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
  let maxCocurrentWrites: Int

  internal init(
    baseGameDir: URL, maxCocurrentChecks: Int, maxCocurrentDownloads: Int,
    maxCocurrentPostProcessors: Int, maxCocurrentWrites: Int, session: URLSession = .shared,
    maxRetries: Int = 10,
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
    self.maxCocurrentWrites = maxCocurrentWrites
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
    guard maxCocurrentWrites > 0 else {
      throw SophonClientError.UnknownError("MaxCocurrentWrites should be a positive integer")
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
    try checkManifests(manifests)  // this checks fileInfo too

    var manifestIndex = 0
    var fileIndex = 0
    func nextJob() -> ScanJob? {
      while manifestIndex < manifests.count {
        let files = manifests[manifestIndex].files

        if fileIndex < files.count {
          let file = files[fileIndex]
          fileIndex += 1
          if file.flags == FILE_FLAG_DIRECTORY {
            continue
          }

          return ScanJob(
            file: file,
            downloadInfo: chunkDownloadInfos[manifestIndex]
          )
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
      let downloadSize = requiredChunks.reduce(0) {
        $0 + ($1.downloadInfo.compression ? $1.compressedSize : $1.uncompressedSize)
      }
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

  // template function for workers with different input and outputs
  private func runStage<Input: Sendable, Output: Sendable>(
    workerCount: Int,
    input: AsyncChannel<Input>,
    output: AsyncChannel<Output>,
    transform: @escaping @Sendable (Input) async throws -> Output
  ) async throws {
    defer {
      output.finish()
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<workerCount {
        group.addTask {
          for await value in input {
            try Task.checkCancellation()

            let result = try await transform(value)
            await output.send(result)
          }
        }
      }

      do {
        while (try await group.next()) != nil {}
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  internal func install(installInfos: [(manifest: Manifest, chunkDownloadInfo: SophonDownloadInfo)])
    async throws
  {
    try Task.checkCancellation()

    let plan = try await scan(installInfos: installInfos)
    try trimFiles(plan: plan)
    try Task.checkCancellation()

    try await execute(plan)
  }

  private func trimFiles(
    plan: InstallationPlan
  ) throws {
    for file in plan.trimFiles {
      try Task.checkCancellation()

      let fileURL = file.fileURL.standardizedFileURL
      let handle = try FileHandle(forWritingTo: fileURL)
      do {
        let currentSize = try handle.seekToEnd()
        guard currentSize > file.size else {
          throw SophonClientError.UnknownError(
            """
            File marked for trimming is not oversized
            path: \(fileURL.path)
            expected maximum: \(file.size)
            actual: \(currentSize)
            """
          )
        }

        try handle.truncate(atOffset: file.size)
        try handle.close()
      } catch {
        try? handle.close()
        throw error
      }
    }
  }

  internal func execute(
    _ plan: InstallationPlan
  ) async throws {
    let requiredChunks = AsyncChannel<RequiredChunk>()
    let downloadedChunks = AsyncChannel<DownloadedChunk>()
    let processedChunks = AsyncChannel<ProcessedChunk>()

    let writeCoordinator = try ChunkWriteCoordinator(
      plannedFiles: plan.plannedFiles,
      workerCount: maxCocurrentWrites
    )

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          defer {
            requiredChunks.finish()
          }

          for chunk in plan.requiredChunks {
            try Task.checkCancellation()
            await requiredChunks.send(chunk)
          }
        }

        group.addTask { [self] in
          try await runStage(
            workerCount: maxCocurrentDownloads,
            input: requiredChunks,
            output: downloadedChunks
          ) { [self] chunk in
            try await download(chunk)
          }
        }

        group.addTask { [self] in
          try await runStage(
            workerCount: maxCocurrentPostProcessors,
            input: downloadedChunks,
            output: processedChunks
          ) { [self] chunk in
            try postProcessChunk(chunk)
          }
        }

        group.addTask {
          try await writeCoordinator.run(processedChunks)
        }

        do {
          while (try await group.next()) != nil {}
        } catch {
          group.cancelAll()

          requiredChunks.finish()
          downloadedChunks.finish()
          processedChunks.finish()

          throw error
        }
      }

      try Task.checkCancellation()
      try await writeCoordinator.ensureComplete()
    } catch {
      requiredChunks.finish()
      downloadedChunks.finish()
      processedChunks.finish()

      await writeCoordinator.closeAll()
      throw error
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

  private func postProcessChunk(_ chunk: DownloadedChunk) throws -> ProcessedChunk {
    if !chunk.downloadInfo.compression {
      return ProcessedChunk(data: chunk.data, chunkApplicationInfos: chunk.chunkApplicationInfos)
    }

    let data = try postProcessor.run(
      ChunkPostProcessRequest(size: chunk.size, md5: chunk.md5, data: chunk.data))
    return ProcessedChunk(data: data, chunkApplicationInfos: chunk.chunkApplicationInfos)
  }
}
