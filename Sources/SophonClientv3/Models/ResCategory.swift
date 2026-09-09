internal struct ResCategory: Codable, Hashable {
  var category: String  // this is category ID
  var isDelete: Bool

  enum CodingKeys: String, CodingKey {
    case category = "category"
    case isDelete = "is_delete"
  }
}
