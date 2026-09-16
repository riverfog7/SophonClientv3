import Foundation
import Logging

public actor UpdateReporter: OperationReportingInternal {
  public typealias Event = UpdateEvent
  public typealias Progress = UpdateProgress

  internal let logger: Logger
  internal var progress = UpdateProgress()
  internal var subscribers: [UUID: AsyncStream<UpdateEvent>.Continuation] = [:]

  public init(logger: Logger) {
    self.logger = logger
  }

  public func record(_ event: UpdateEvent) {
    guard progress.outcome == nil else {
      return
    }

    switch event {
    // TODO: Add events
    }

    for subscriber in subscribers.values {
      subscriber.yield(event)
    }

    if progress.outcome != nil {
      for subscriber in subscribers.values {
        subscriber.finish()
      }

      subscribers.removeAll()
    }
  }

  deinit {
    for subscriber in subscribers.values {
      subscriber.finish()
    }
  }
}
