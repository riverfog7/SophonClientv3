struct HYPAPIResponse<DataType: Decodable>: Decodable {
  var retcode: Int
  var message: String
  var data: DataType
}
