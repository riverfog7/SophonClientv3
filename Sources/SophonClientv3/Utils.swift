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
    throw SophonClientError.SizeMismatch(expected: UInt64(uncompressedSize), actual: UInt64(written))
  }

  return output
}
