struct HYPAPIResponse<DataType: Decodable>: Decodable {
  public var retcode: Int
  public var message: String
  public var data: DataType
}
