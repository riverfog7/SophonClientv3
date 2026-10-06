import Foundation
import HYPAPIClient
import Testing

@testable import SophonClientv3

func getTestDataPath() -> URL {
  return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".testData")
}

func testManifestContents(_ manifest: Manifest) {
  for fileInfo in manifest.files {
    for chunkInfo in fileInfo.chunks {
      #expect(chunkInfo.chunkID.count > 0, "chunk ID should exist")
      #expect(chunkInfo.md5.count > 0, "chunk uncompressed md5 should exist")
      #expect(chunkInfo.compressedSize > 0, "chunk compressed size should be positive")
      #expect(chunkInfo.uncompressedSize > 0, "chunk uncompressed size should be positive")
      #expect(chunkInfo.compressedMd5.count > 0, "chunk compressed md5 should exist")
      #expect(
        UInt64(chunkInfo.uncompressedSize) + chunkInfo.offset <= UInt64(fileInfo.size),
        "chunk should be within file")
    }
  }
}

func testDiffManifestContents(_ manifest: DiffManifest) {
  for fileInfo in manifest.files {
    #expect(fileInfo.filename.count > 0, "file name should exist")
    #expect(fileInfo.size >= 0, "file size should not be negative")
    #expect(fileInfo.hash.count > 0, "file hash should exist")
    let sourceVersions = fileInfo.patches.map(\.key)
    #expect(
      Set(sourceVersions).count == sourceVersions.count,
      "file \(fileInfo.filename) should have at most one patch per source version")
    for patch in fileInfo.patches {
      #expect(patch.key.count > 0, "patch source version should exist")
      #expect(patch.hasInfo, "patch info should exist")
      #expect(patch.info.patchOffset >= 0, "patch offset should not be negative")
      #expect(patch.info.patchLength >= 0, "patch length should not be negative")
      #expect(
        patch.info.patchOffset + patch.info.patchLength <= patch.info.patchSize,
        "patch should be within the diff file")
    }
  }

  for deleteFile in manifest.filesDelete {
    #expect(deleteFile.key.count > 0, "delete source version should exist")
    #expect(deleteFile.hasInfo, "delete info should exist")
    for fileInfo in deleteFile.info.list {
      #expect(fileInfo.filename.count > 0, "delete file name should exist")
      #expect(fileInfo.size >= 0, "delete file size should not be negative")
      #expect(fileInfo.hash.count > 0, "delete file hash should exist")
    }
  }
}

func printUpdatePlanSummary(_ plan: UpdatePlan, gameID: String) {
  let patches = plan.patchBundles.flatMap(\.patches)
  let patchesWithSource = patches.filter { $0.original != nil }.count

  print(
    """
    update plan for \(gameID) from \(plan.sourceVersion):
      patch bundle files: \(plan.patchBundles.count)
      total bundle target files: \(patches.count)
      files to patch using an original: \(patchesWithSource)
      files supplied by bundles without an original: \(patches.count - patchesWithSource)
      files to delete: \(plan.deleteFiles.count)
      total file size to delete: \(Double(plan.deleteSize) / 1_073_741_824) GiB
      total patch bundle download size: \(Double(plan.patchSize) / 1_073_741_824) GiB
      total updated file size: \(Double(plan.installSize) / 1_073_741_824) GiB
    """)
}

func testDiffManifestParse(
  baseURL: String, sophonBaseURL: String, launcherID: String, gameList: [String]
) async throws {
  let cacheDir = getTestDataPath().appendingPathComponent("manifestCache")
  for gameID in gameList {
    let manager = try await CachedManifestManager(
      baseURL: baseURL, sophonBaseURL: sophonBaseURL, launcherID: launcherID,
      gameID: gameID, manifestCacheDir: cacheDir.path())
    let subBranch = try manager.getGameSubbranch(predownload: false)
    let patchBuildInfo = try await manager.apiClient.getSophonPatchBuildInfo(subBranch)
    #expect(patchBuildInfo.manifests.count > 0, "patch manifests should exist")
    let categories =
      subBranch.getGameBranchCategories(
        categoryScenario: .full, categoryType: .resource)
      + subBranch.getGameBranchCategories(categoryScenario: .full, categoryType: .audio)
    let matchingFields = Set(categories.map(\.matchingField))
    var installInfos: [(manifest: Manifest, chunkDownloadInfo: SophonDownloadInfo)] = []
    var updateInfos: [(manifest: DiffManifest, diffDownloadInfo: SophonDownloadInfo)] = []

    for manifestInfo in patchBuildInfo.manifests {
      let (manifest, diffDownloadInfo) = try await manager.getSophonPatchManifest(
        matchingField: manifestInfo.matchingField)
      #expect(
        manifest.files.count > 0 || manifest.filesDelete.count > 0,
        "manifest with matching field \(manifestInfo.matchingField) should not be empty")
      #expect(diffDownloadInfo.urlPrefix == manifestInfo.diffDownload.urlPrefix)
      #expect(diffDownloadInfo.urlSuffix == manifestInfo.diffDownload.urlSuffix)
      testDiffManifestContents(manifest)

      if matchingFields.contains(manifestInfo.matchingField) {
        installInfos.append(
          try await manager.getSophonManifest(matchingField: manifestInfo.matchingField))
        updateInfos.append((manifest, diffDownloadInfo))
      }
    }

    #expect(updateInfos.count > 0, "selected update manifests should exist")
    let baseGameDir = getTestDataPath().appendingPathComponent("updatePlan")
    let updater = try Updater(
      baseGameDir: baseGameDir, maxCocurrentDownloads: 8, maxCocurrentWrites: 4)
    var installFilesByPath: [String: (file: FileInfo, downloadInfo: SophonDownloadInfo)] = [:]
    for info in installInfos {
      for file in info.manifest.files where file.flags == FILE_FLAG_FILE {
        let path = baseGameDir.appendingPathComponent(file.filename).path.lowercased()
        installFilesByPath[path] = (file, info.chunkDownloadInfo)
      }
    }
    let retainedPaths = Set(installFilesByPath.keys)
    for sourceVersion in subBranch.diffTags {
      let plan = try updater.makePlan(
        sourceVersion: sourceVersion, installInfos: installInfos, updateInfos: updateInfos)
      var expectedPatchesByPath: [String: (info: PatchInfo, downloadInfo: SophonDownloadInfo)] = [:]
      for info in updateInfos {
        for file in info.manifest.files {
          if let patch = file.patches.first(where: { $0.key == sourceVersion }) {
            let path = baseGameDir.appendingPathComponent(file.filename).path.lowercased()
            expectedPatchesByPath[path] = (patch.info, info.diffDownloadInfo)
          }
        }
      }
      let expectedUpdatedPaths = Set(expectedPatchesByPath.keys)
      let plannedFiles = plan.patchBundles.flatMap { $0.patches.map(\.target) }
      #expect(plan.sourceVersion == sourceVersion)
      #expect(plannedFiles.count == expectedUpdatedPaths.count)
      #expect(Set(plannedFiles.map { $0.fileURL.path.lowercased() }) == expectedUpdatedPaths)
      for plannedFile in plan.installFiles + plannedFiles {
        let path = plannedFile.fileURL.path.lowercased()
        let target = try #require(installFilesByPath[path])
        #expect(plannedFile.fileURL == baseGameDir.appendingPathComponent(target.file.filename))
        #expect(plannedFile.size == UInt64(target.file.size))
        #expect(plannedFile.md5 == target.file.md5)
        #expect(plannedFile.installChunks.count == target.file.chunks.count)
        for (plannedChunk, chunk) in zip(plannedFile.installChunks, target.file.chunks) {
          #expect(plannedChunk.chunkID == chunk.chunkID)
          #expect(plannedChunk.uncompressedMd5 == chunk.md5)
          #expect(plannedChunk.compressedMd5 == chunk.compressedMd5)
          #expect(plannedChunk.compressedSize == UInt64(chunk.compressedSize))
          #expect(plannedChunk.uncompressedSize == UInt64(chunk.uncompressedSize))
          #expect(plannedChunk.downloadInfo.urlPrefix == target.downloadInfo.urlPrefix)
          #expect(plannedChunk.downloadInfo.urlSuffix == target.downloadInfo.urlSuffix)
          #expect(plannedChunk.downloadInfo.compression == target.downloadInfo.compression)
          #expect(plannedChunk.downloadInfo.encryption == target.downloadInfo.encryption)
          #expect(plannedChunk.downloadInfo.password == target.downloadInfo.password)
          #expect(plannedChunk.chunkApplicationInfos.count == 1)
          let application = try #require(plannedChunk.chunkApplicationInfos.first)
          #expect(application.fileURL == plannedFile.fileURL)
          #expect(application.offset == chunk.offset)
        }
      }

      #expect(plan.installFiles.count == expectedUpdatedPaths.count)
      #expect(
        Set(plan.installFiles.map { $0.fileURL.path.lowercased() }) == expectedUpdatedPaths)
      let expectedPatchIDs = Set(expectedPatchesByPath.values.map { $0.info.patchID })
      #expect(plan.patchBundles.count == expectedPatchIDs.count)
      #expect(Set(plan.patchBundles.map(\.patchID)) == expectedPatchIDs)
      for bundle in plan.patchBundles {
        #expect(bundle.patches.count > 0)
        let offsets = bundle.patches.map(\.patchOffset)
        #expect(offsets == offsets.sorted())
        for patch in bundle.patches {
          let expectedPatch = try #require(
            expectedPatchesByPath[patch.target.fileURL.path.lowercased()])
          #expect(bundle.patchID == expectedPatch.info.patchID)
          #expect(bundle.patchSize == UInt64(expectedPatch.info.patchSize))
          #expect(bundle.patchHash == expectedPatch.info.patchName)
          #expect(patch.patchOffset == UInt64(expectedPatch.info.patchOffset))
          #expect(patch.patchLength == UInt64(expectedPatch.info.patchLength))
          if expectedPatch.info.originalName.isEmpty {
            #expect(patch.original == nil)
          } else {
            let original = try #require(patch.original)
            #expect(
              original.fileURL
                == baseGameDir.appendingPathComponent(expectedPatch.info.originalName))
            #expect(original.size == UInt64(expectedPatch.info.originalSize))
            #expect(original.md5 == expectedPatch.info.originalHash)
          }
          #expect(bundle.downloadInfo.urlPrefix == expectedPatch.downloadInfo.urlPrefix)
          #expect(bundle.downloadInfo.urlSuffix == expectedPatch.downloadInfo.urlSuffix)
          #expect(bundle.downloadInfo.compression == expectedPatch.downloadInfo.compression)
          #expect(bundle.downloadInfo.encryption == expectedPatch.downloadInfo.encryption)
          #expect(bundle.downloadInfo.password == expectedPatch.downloadInfo.password)
        }
      }

      var expectedDeleteSizes: [String: UInt64] = [:]
      for deletion in updateInfos.flatMap({ $0.manifest.filesDelete })
      where deletion.key == sourceVersion {
        for file in deletion.info.list {
          let path = baseGameDir.appendingPathComponent(file.filename).path.lowercased()
          if !retainedPaths.contains(path) {
            expectedDeleteSizes[path] = UInt64(file.size)
          }
        }
      }
      let expectedDeletePaths = Set(expectedDeleteSizes.keys)
      #expect(plan.deleteFiles.count == expectedDeletePaths.count)
      #expect(Set(plan.deleteFiles.map { $0.fileURL.path.lowercased() }) == expectedDeletePaths)
      for file in plan.deleteFiles {
        let expectedSize = try #require(expectedDeleteSizes[file.fileURL.path.lowercased()])
        #expect(file.size == expectedSize)
      }
      #expect(plan.deleteSize == expectedDeleteSizes.values.reduce(UInt64(0), +))
      printUpdatePlanSummary(plan, gameID: gameID)
    }
  }
}

func testManifestParse(
  baseURL: String, sophonBaseURL: String, launcherID: String, gameList: [String]
) async throws {
  let cacheDir = getTestDataPath().appendingPathComponent("manifestCache")
  let installerTempDir = getTestDataPath().appendingPathComponent(
    "installerTemp-\(UUID().uuidString)")
  for gameID in gameList {
    let settings = SophonClientSettings(
      baseURL: baseURL, sophonBaseURL: sophonBaseURL,
      launcherID: launcherID, gameID: gameID,
      manifestCacheDir: cacheDir.path())
    let client = try await SophonClientv3(settings, baseGameDir: installerTempDir)
    let subBranch = try client.manifestManager.getGameSubbranch(predownload: false)

    let fullResourceCategory = subBranch.getGameBranchCategories(
      categoryScenario: GameBranchCategoryScenario.full,
      categoryType: GameBranchCategoryType.resource)
    let fullAudioCategory = subBranch.getGameBranchCategories(
      categoryScenario: GameBranchCategoryScenario.full, categoryType: GameBranchCategoryType.audio)

    for resource in fullAudioCategory {
      #expect(
        !fullResourceCategory.contains(where: { $0.matchingField == resource.matchingField }),
        "audio category and resource category must not overlap")
    }

    var installInfos: [(manifest: Manifest, chunkDownloadInfo: SophonDownloadInfo)] = []
    for matchingField in (fullResourceCategory + fullAudioCategory).map({ $0.matchingField }) {
      let (manifest, chunkDownloadInfo) = try await client.manifestManager.getSophonManifest(
        matchingField: matchingField)
      installInfos.append((manifest, chunkDownloadInfo))
      #expect(
        manifest.files.count > 0,
        "manifest with matching field \(matchingField) should not have no files")
      testManifestContents(manifest)

      if FileManager.default.fileExists(atPath: installerTempDir.path()) {
        try FileManager.default.removeItem(at: installerTempDir)
      }
      try FileManager.default.createDirectory(
        at: installerTempDir, withIntermediateDirectories: true)
    }
    try checkManifests(installInfos.map { $0.manifest })

    let installer = try Installer(
      baseGameDir: installerTempDir, maxCocurrentChecks: 8, maxCocurrentDownloads: 8,
      maxCocurrentPostProcessors: 8, maxCocurrentWrites: 8)
    let installationPlan = try await installer.scan(installInfos: installInfos)
    print("total chunk count for \(gameID): \(installationPlan.totalChunkCount)")
    print(
      "download size for \(gameID): \(Double(installationPlan.downloadSize) / 1_073_741_824) GiB")
    print(
      "disk write size for \(gameID): \(Double(installationPlan.diskWriteSize) / 1_073_741_824) GiB"
    )
  }
  try? FileManager.default.removeItem(at: installerTempDir)
}

@Test
func testOSManifestParse() async throws {
  try await testManifestParse(
    baseURL: HYPAPI_OS_BASE_URL, sophonBaseURL: SOPHON_API_OS_BASE_URL,
    launcherID: HYPAPI_OS_LAUNCHER_ID,
    gameList: [
      "U5hbdsT9W7",
      "4ziysqXOQ8",
      "gopR6Cufr3",
      "5TIVvvcwtM",
      "g0mMIvshDb",
      "uxB4MC7nzC",
      "bxPTXSET5t",
      "wkE5P5WsIf",
    ])
}

@Test
func testCNManifestParse() async throws {
  try await testManifestParse(
    baseURL: HYPAPI_CN_BASE_URL, sophonBaseURL: SOPHON_API_CN_BASE_URL,
    launcherID: HYPAPI_CN_LAUNCHER_ID,
    gameList: [
      "x6znKlJ0xK",
      "64kMb5iAWu",
      "1Z8W5NHUQb",
      "osvnlOc0S8",
    ])
}

@Test
func testOSDiffManifestParse() async throws {
  try await testDiffManifestParse(
    baseURL: HYPAPI_OS_BASE_URL, sophonBaseURL: SOPHON_API_OS_BASE_URL,
    launcherID: HYPAPI_OS_LAUNCHER_ID,
    gameList: [
      "U5hbdsT9W7",
      "4ziysqXOQ8",
      "gopR6Cufr3",
    ])
}

@Test
func testCNDiffManifestParse() async throws {
  try await testDiffManifestParse(
    baseURL: HYPAPI_CN_BASE_URL, sophonBaseURL: SOPHON_API_CN_BASE_URL,
    launcherID: HYPAPI_CN_LAUNCHER_ID,
    gameList: [
      "x6znKlJ0xK",
      "64kMb5iAWu",
      "1Z8W5NHUQb",
    ])
}
