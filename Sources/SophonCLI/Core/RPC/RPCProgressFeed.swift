import Foundation
import SophonClientv3

struct RPCNotification: Sendable {
  let value: @Sendable () async -> JSONValue

  init(_ value: JSONValue) { self.value = { value } }

  init(_ value: @escaping @Sendable () async -> JSONValue) { self.value = value }
}

// Wakeups may coalesce; the raw events themselves are retained until consumed.
final class RPCEventBuffer<Event: Sendable>: @unchecked Sendable {
  static var batchLimit: Int { 128 }
  let wakeups: AsyncStream<Void>
  private let signal: AsyncStream<Void>.Continuation
  private let lock = NSLock()
  private var events: [Event?] = []
  private var head = 0
  private var terminal: JSONValue?
  private var accepting = true

  init() {
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    wakeups = pair.stream
    signal = pair.continuation
  }

  func append(_ event: Event) {
    let appended = lock.withLock {
      guard accepting else { return false }
      events.append(event)
      return true
    }
    if appended { signal.yield(()) }
  }

  func take() -> [Event] {
    lock.withLock {
      let end = min(events.count, head + Self.batchLimit)
      var batch: [Event] = []
      batch.reserveCapacity(end - head)
      while head < end {
        batch.append(events[head]!)
        events[head] = nil
        head += 1
      }
      if head == events.count {
        events.removeAll(keepingCapacity: true)
        head = 0
      } else if head >= 1024, head >= events.count / 2 {
        events.removeFirst(head)
        head = 0
      }
      return batch
    }
  }

  var finalStatus: JSONValue? { lock.withLock { terminal } }
  var hasEvents: Bool { lock.withLock { head < events.count } }

  func finish(_ status: JSONValue) {
    let finished = lock.withLock {
      guard accepting else { return false }
      accepting = false
      terminal = status
      return true
    }
    guard finished else { return }
    signal.yield(())
    signal.finish()
  }

  func discard() {
    lock.withLock {
      accepting = false
      events.removeAll()
      head = 0
      terminal = nil
    }
    signal.finish()
  }
}

protocol RPCEventDelivery: Sendable {
  func finish(_ status: JSONValue) async
  func drain() async
}

final class RPCProgressFeed<Reporter: OperationReporting>: RPCEventDelivery, Sendable
where Reporter.Event: Encodable, Reporter.Progress: Encodable {
  private let reporter: Reporter
  private let subscriptionID: UUID
  private let buffer: RPCEventBuffer<Reporter.Event>
  private let collector: Task<Void, Never>
  private let sender: Task<Void, Never>

  init(
    reporter: Reporter, operationID: String, kind: String,
    status: @escaping @Sendable () async -> JSONValue,
    send: @escaping @Sendable (RPCNotification) async throws -> Void,
    onDrained: @escaping @Sendable () async -> Void = {}
  ) async {
    self.reporter = reporter
    let subscription = await reporter.subscribe()
    subscriptionID = subscription.id
    let buffer = RPCEventBuffer<Reporter.Event>()
    self.buffer = buffer
    let collector = Task.detached {
      for await event in subscription.events { buffer.append(event) }
    }
    self.collector = collector
    sender = Task.detached {
      do {
        for await _ in buffer.wakeups {
          while buffer.hasEvents {
            try await send(
              RPCNotification {
                let batch = buffer.take()
                let current: JSONValue
                if let terminal = buffer.finalStatus {
                  current = terminal
                } else {
                  current = await status()
                }
                var params = current.object ?? [:]
                params["operationID"] = .string(operationID)
                params["kind"] = .string(kind)
                params["events"] = .encoded(batch)
                params["progress"] = .encoded(await reporter.snapshot())
                return .object([
                  "jsonrpc": .string("2.0"), "method": .string("operation.progress"),
                  "params": .object(params),
                ])
              })
          }
        }
        if let terminal = buffer.finalStatus {
          try await send(
            RPCNotification(
              .object([
                "jsonrpc": .string("2.0"), "method": .string("operation.finished"),
                "params": terminal,
              ])))
        }
      } catch {
        buffer.discard()
        collector.cancel()
        await reporter.unsubscribe(subscription.id)
        await collector.value
      }
      await onDrained()
    }
  }

  func finish(_ status: JSONValue) async {
    await reporter.unsubscribe(subscriptionID)
    await collector.value
    buffer.finish(status)
  }

  func drain() async { await sender.value }
}
