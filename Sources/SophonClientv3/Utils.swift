import Crypto
import Foundation
import libzstd

func md5Hex(_ data: Data) -> String {
  Insecure.MD5.hash(data: data)
    .map { String(format: "%02x", $0) }
    .joined()
}

func decompressZstd(
  _ compressed: Data,
  uncompressedSize: Int
) throws -> Data {
  var output = Data(count: uncompressedSize)

  let written = output.withUnsafeMutableBytes { dst in
    compressed.withUnsafeBytes { src in
      ZSTD_decompress(
        dst.baseAddress,
        dst.count,
        src.baseAddress,
        src.count
      )
    }
  }

  guard ZSTD_isError(written) == 0 else {
    throw SophonClientError.ZstdError(
      String(cString: ZSTD_getErrorName(written))
    )
  }

  guard written == uncompressedSize else {
    throw SophonClientError.SizeMismatch(
      expected: UInt64(uncompressedSize), actual: UInt64(written))
  }

  return output
}

func checkFileInfo(_ file: FileInfo) throws {
  if file.flags == FILE_FLAG_DIRECTORY {
    guard file.md5.isEmpty, file.size == 0, file.chunks.isEmpty else {
      throw SophonClientError.UnknownError(
        "directory has strange attributes: md5: \(file.md5), size: \(file.size), chunk count: \(file.chunks.count)"
      )
    }
    return
  }
  guard file.flags == FILE_FLAG_FILE else {
    throw SophonClientError.UnknownError(
      "Unknown file flag: \(file.flags)"
    )
  }

  guard file.size > 0,
    !file.md5.isEmpty,
    !file.chunks.isEmpty
  else {
    throw SophonClientError.UnknownError(
      """
      Invalid regular file
      size: \(file.size)
      md5: \(file.md5)
      chunk count: \(file.chunks.count)
      """
    )
  }
}

func checkManifests(_ manifests: [Manifest]) throws {
  var fileNameSet = Set<String>()
  for manifest in manifests {
    for file in manifest.files {
      try checkFileInfo(file)
      guard file.flags == FILE_FLAG_FILE else {
        continue
      }

      // windows NTFS is case insensitive
      let fileName = file.filename.lowercased()
      if !fileNameSet.insert(fileName).inserted {
        throw SophonClientError.DuplicateFileError(
          fileName
        )
      }
    }
  }
}
