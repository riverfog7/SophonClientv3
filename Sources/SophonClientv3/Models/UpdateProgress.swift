import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum UpdatePhase: String, Sendable {
  case metadata
  // TODO: Add more
}

public enum UpdateOutcome: Sendable {
  case completed
  case failed(reason: String)
  case cancelled
}

public enum UpdateEvent: Sendable {
  // TODO: Add more
}

public struct UpdateProgress: BaseProgress {
  // TODO: Add more
  public internal(set) var phase: UpdatePhase = .metadata
  public internal(set) var outcome: UpdateOutcome?
}
