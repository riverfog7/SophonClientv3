protocol OperationReporting<Event>: Sendable {
  associatedtype Event: Sendable

  func record(_ event: Event) async
}
