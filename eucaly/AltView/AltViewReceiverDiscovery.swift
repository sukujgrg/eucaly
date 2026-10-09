// Adapted from AltView protocol v2 sender, source 9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd.
// Kept local so eucaly builds and runs without an AltView checkout or process.
import Foundation
import Network
import CryptoKit
import Darwin

nonisolated enum AltViewLocalReceiverMarker {
    static let current: String? = {
        var length = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, (1...128).contains(length) else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return nil }
        let value = String(cString: bytes)
        guard !value.isEmpty else { return nil }
        return SHA256.hash(data: Data("AltView local v1:\(value)".utf8)).map { String(format: "%02x", $0) }.joined()
    }()
}

nonisolated struct AltViewDiscoveredReceiver: Sendable {
    let name: String
    let endpoint: NWEndpoint
    var receiverID: UUID?
    var isLocal = false
}

nonisolated protocol AltViewReceiverDiscovering: AnyObject {
    func start()
    func stop()
}

nonisolated protocol AltViewReceiverBrowsing: AnyObject, Sendable {
    var browseResults: Set<NWBrowser.Result> { get }
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)? { get set }
    var browseResultsChangedHandler: (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

extension NWBrowser: AltViewReceiverBrowsing {}

nonisolated final class AltViewReceiverDiscovery: AltViewReceiverDiscovering, @unchecked Sendable {
    private let queue: DispatchQueue
    private let browserFactory: () -> AltViewReceiverBrowsing
    private let retryDelay: TimeInterval
    private var browser: AltViewReceiverBrowsing?
    private var activeGeneration: UUID?
    private var retryWork: DispatchWorkItem?
    private var retryAttempts = 0
    // UI entry points and delivery generations are main-queue owned.
    private var generation = UUID()
    private let excludingReceiverID: UUID?
    private let onChange: ([AltViewDiscoveredReceiver], String?) -> Void
    init(excludingReceiverID: UUID? = nil,
         queue: DispatchQueue = DispatchQueue(label: "com.suku.eucaly.altview.discovery"),
         retryDelay: TimeInterval = 1,
         browserFactory: @escaping () -> AltViewReceiverBrowsing = {
             NWBrowser(for: .bonjourWithTXTRecord(type: AltViewProtocol.serviceType, domain: nil), using: .tcp)
         }, onChange: @escaping ([AltViewDiscoveredReceiver], String?) -> Void) {
        self.queue = queue; self.retryDelay = retryDelay; self.browserFactory = browserFactory
        self.excludingReceiverID = excludingReceiverID; self.onChange = onChange
    }
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID()
        let generation = generation
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.activeGeneration = generation
            self.openBrowser(generation: generation)
        }
    }
    private func openBrowser(generation: UUID) {
        guard activeGeneration == generation else { return }
        let browser = browserFactory()
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            self.deliver(self.discoveredReceivers(in: results), error: nil, generation: generation)
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            switch state {
            case .failed(let error):
                self.cancelBrowser()
                self.deliver([], error: "Discovery unavailable: \(error.localizedDescription). Retrying…", generation: generation)
                self.scheduleRetry(generation: generation)
            case .waiting(let error):
                self.deliver([], error: "Discovery waiting: \(error.localizedDescription)", generation: generation)
            case .ready:
                self.retryAttempts = 0
                // Recovery can keep the same results without another change callback.
                self.deliver(self.discoveredReceivers(in: browser.browseResults), error: nil, generation: generation)
            default: break
            }
        }
        browser.start(queue: queue)
    }
    private func discoveredReceivers(in results: Set<NWBrowser.Result>) -> [AltViewDiscoveredReceiver] {
        results.compactMap { receiver(endpoint: $0.endpoint, metadata: $0.metadata) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func scheduleRetry(generation: UUID) {
        let delay = retryDelay * pow(2, Double(min(retryAttempts, 3)))
        retryAttempts += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeGeneration == generation, self.browser == nil else { return }
            self.retryWork = nil
            self.openBrowser(generation: generation)
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    // Keep identity parsing and filtering independent of live Bonjour availability.
    func receiver(endpoint: NWEndpoint, metadata: NWBrowser.Result.Metadata, localMarker: String? = AltViewLocalReceiverMarker.current) -> AltViewDiscoveredReceiver? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        let id: UUID?
        if case .bonjour(let record) = metadata { id = record["receiverID"].flatMap(UUID.init(uuidString:)) }
        else { id = nil }
        if let id, id == excludingReceiverID { return nil }
        if let id, let localMarker, case .bonjour(let record) = metadata,
           record["localMarker"] == localMarker, let raw = record["port"], let port = UInt16(raw), port > 0 {
            return AltViewDiscoveredReceiver(name: "This Mac · \(name)",
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), receiverID: id, isLocal: true)
        }
        return AltViewDiscoveredReceiver(name: name, endpoint: endpoint, receiverID: id)
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID()
        queue.async { [weak self] in self?.stopOnQueue() }
    }
    private func stopOnQueue() {
        activeGeneration = nil
        retryWork?.cancel(); retryWork = nil; retryAttempts = 0
        cancelBrowser()
    }
    private func cancelBrowser() {
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel(); browser = nil
    }
    private func deliver(_ receivers: [AltViewDiscoveredReceiver], error: String?, generation: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onChange(receivers, error)
        }
    }
}
