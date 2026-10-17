// Shared with eucaly. DNS-SD only locates the SRT endpoint; it never carries secrets.
// Foundation and DNS-SD are available to a future tvOS receiver too.
import Foundation
import dnssd

nonisolated struct SRTMediaReceiver: Equatable, Sendable {
    static let serviceType = "_altviewmedia._udp"
    let id: UUID
    let name: String
    let host: String
    let port: Int

    static func txtRecord(id: UUID) -> Data {
        NetService.data(fromTXTRecord: ["version": Data("1".utf8), "receiverID": Data(id.uuidString.utf8)])
    }
    init?(name: String, host: String, port: Int, txtRecord: Data) {
        let record = NetService.dictionary(fromTXTRecord: txtRecord)
        guard record["version"] == Data("1".utf8), let raw = record["receiverID"],
              let value = String(data: raw, encoding: .utf8), let id = UUID(uuidString: value) else { return nil }
        var settings = SRTMediaSettings(); settings.host = host; settings.port = port
        guard settings.isValid else { return nil }
        self.id = id; self.name = name; self.host = host; self.port = port
    }
}

private nonisolated enum MediaDNSEvent {
    case registered(DNSServiceErrorType)
    case browsed(DNSServiceErrorType, DNSServiceFlags, String, String, String, UInt32)
    case resolved(DNSServiceErrorType, String, Int, Data)
}

private nonisolated final class MediaDNSCallback: @unchecked Sendable {
    let receive: (MediaDNSEvent) -> Void
    init(_ receive: @escaping (MediaDNSEvent) -> Void) { self.receive = receive }
}

private nonisolated struct MediaDNSRetirement: @unchecked Sendable {
    let reference: DNSServiceRef
    let callback: MediaDNSCallback
    func cancel() { DNSServiceRefDeallocate(reference); withExtendedLifetime(callback) {} }
}

// A callback context stays alive until its DNS reference has been deallocated on
// its own serial queue, including when a settings window/router is torn down.
private nonisolated final class MediaDNSOperation: @unchecked Sendable {
    private var reference: DNSServiceRef?
    private let queue: DispatchQueue
    private let callback: MediaDNSCallback
    init(queue: DispatchQueue, receive: @escaping (MediaDNSEvent) -> Void) {
        self.queue = queue; callback = MediaDNSCallback(receive)
    }
    func start(_ create: (UnsafeMutablePointer<DNSServiceRef?>, UnsafeMutableRawPointer) -> DNSServiceErrorType) -> DNSServiceErrorType {
        dispatchPrecondition(condition: .onQueue(queue))
        var error = create(&reference, Unmanaged.passUnretained(callback).toOpaque())
        if error == kDNSServiceErr_NoError, let reference { error = DNSServiceSetDispatchQueue(reference, queue) }
        if error != kDNSServiceErr_NoError { cancel() }
        return error
    }
    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let reference { DNSServiceRefDeallocate(reference) }; reference = nil
    }
    deinit {
        if let reference {
            let retirement = MediaDNSRetirement(reference: reference, callback: callback)
            queue.async { retirement.cancel() }
        }
    }
}

nonisolated final class SRTMediaAdvertisement: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.suku.media.advertisement")
    private var operation: MediaDNSOperation?
    private var retry: DispatchWorkItem?
    private var active: UUID?
    // Main-queue delivery guard; queued DNS callbacks cannot update a new run.
    private var generation = UUID()
    private let onChange: (String?) -> Void
    init(onChange: @escaping (String?) -> Void = { _ in }) { self.onChange = onChange }
    func start(id: UUID, port: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID(); let token = generation
        queue.async { [weak self] in
            guard let self else { return }
            self.cancel(); self.active = token; self.publish(id: id, port: port, token: token)
        }
    }
    private func publish(id: UUID, port: Int, token: UUID) {
        guard active == token, (1...65535).contains(port) else { return }
        let operation = MediaDNSOperation(queue: queue) { [weak self] event in
            guard let self, self.active == token, case .registered(let error) = event else { return }
            if error == kDNSServiceErr_NoError { self.deliver(nil, token: token) }
            else { self.failed(id: id, port: port, token: token) }
        }
        self.operation = operation
        let data = SRTMediaReceiver.txtRecord(id: id)
        let error = data.withUnsafeBytes { bytes in
            operation.start { reference, context in
                DNSServiceRegister(reference, 0, 0, nil, SRTMediaReceiver.serviceType, "local.", nil,
                    UInt16(port).bigEndian, UInt16(data.count), bytes.baseAddress, { _, _, error, _, _, _, context in
                        guard let context else { return }
                        Unmanaged<MediaDNSCallback>.fromOpaque(context).takeUnretainedValue().receive(.registered(error))
                    }, context)
            }
        }
        if error != kDNSServiceErr_NoError { failed(id: id, port: port, token: token) }
    }
    private func failed(id: UUID, port: Int, token: UUID) {
        operation?.cancel(); operation = nil
        deliver("Bonjour unavailable · use the local address. Retrying discovery…", token: token)
        let work = DispatchWorkItem { [weak self] in self?.publish(id: id, port: port, token: token) }
        retry?.cancel(); retry = work; queue.asyncAfter(deadline: .now() + 3, execute: work)
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID(); queue.async { [weak self] in self?.cancel() }
    }
    private func cancel() {
        active = nil; retry?.cancel(); retry = nil; operation?.cancel(); operation = nil
    }
    private func deliver(_ notice: String?, token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }; self.onChange(notice)
        }
    }
}

nonisolated final class SRTMediaDiscovery: @unchecked Sendable {
    private struct Service: Hashable {
        let name: String; let type: String; let domain: String; let interface: UInt32
    }
    private let queue = DispatchQueue(label: "com.suku.media.discovery")
    private var browser: MediaDNSOperation?
    private var resolvers: [Service: MediaDNSOperation] = [:]
    private var receivers: [Service: SRTMediaReceiver] = [:]
    private var retry: DispatchWorkItem?
    private var active: UUID?
    private var generation = UUID()
    private let onChange: ([SRTMediaReceiver], String?) -> Void
    init(onChange: @escaping ([SRTMediaReceiver], String?) -> Void) { self.onChange = onChange }
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID(); let token = generation
        queue.async { [weak self] in
            guard let self else { return }; self.cancel(); self.active = token; self.browse(token: token)
        }
    }
    private func browse(token: UUID) {
        guard active == token else { return }
        let browser = MediaDNSOperation(queue: queue) { [weak self] event in
            guard let self, self.active == token,
                  case .browsed(let error, let flags, let name, let type, let domain, let interface) = event else { return }
            guard error == kDNSServiceErr_NoError else { self.failed(token: token); return }
            let service = Service(name: name, type: type, domain: domain, interface: interface)
            if flags & UInt32(kDNSServiceFlagsAdd) == 0 {
                self.resolvers.removeValue(forKey: service)?.cancel(); self.receivers[service] = nil; self.deliver(token: token)
            } else if self.resolvers[service] == nil && self.resolvers.count < 64 {
                self.resolve(service, token: token)
            }
        }
        self.browser = browser
        let error = browser.start { reference, context in
            DNSServiceBrowse(reference, 0, 0, SRTMediaReceiver.serviceType, "local.", { _, flags, interface, error, name, type, domain, context in
                guard let context else { return }
                Unmanaged<MediaDNSCallback>.fromOpaque(context).takeUnretainedValue().receive(
                    .browsed(error, flags, name.map(String.init(cString:)) ?? "", type.map(String.init(cString:)) ?? "",
                        domain.map(String.init(cString:)) ?? "", interface))
            }, context)
        }
        if error != kDNSServiceErr_NoError { failed(token: token) }
    }
    private func resolve(_ service: Service, token: UUID) {
        let resolver = MediaDNSOperation(queue: queue) { [weak self] event in
            guard let self, self.active == token, self.resolvers[service] != nil,
                  case .resolved(let error, let host, let port, let data) = event else { return }
            if error == kDNSServiceErr_NoError {
                self.receivers[service] = SRTMediaReceiver(name: service.name, host: host, port: port, txtRecord: data)
                self.deliver(token: token)
            } else { self.failed(token: token) }
        }
        resolvers[service] = resolver
        let error = resolver.start { reference, context in
            DNSServiceResolve(reference, 0, service.interface, service.name, service.type, service.domain, { _, _, _, error, _, host, port, length, txt, context in
                guard let context else { return }
                let data = txt.map { Data(bytes: $0, count: Int(length)) } ?? Data()
                Unmanaged<MediaDNSCallback>.fromOpaque(context).takeUnretainedValue().receive(
                    .resolved(error, host.map(String.init(cString:)) ?? "", Int(UInt16(bigEndian: port)), data))
            }, context)
        }
        if error != kDNSServiceErr_NoError { failed(token: token) }
    }
    private func failed(token: UUID) {
        cancel(); active = token
        deliver(token: token, notice: "Bonjour unavailable · manual addressing is available. Retrying…")
        let work = DispatchWorkItem { [weak self] in self?.browse(token: token) }
        retry = work; queue.asyncAfter(deadline: .now() + 3, execute: work)
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID(); queue.async { [weak self] in self?.cancel() }
    }
    private func cancel() {
        active = nil; retry?.cancel(); retry = nil; browser?.cancel(); browser = nil
        resolvers.values.forEach { $0.cancel() }; resolvers.removeAll(); receivers.removeAll()
    }
    private func deliver(token: UUID, notice: String? = nil) {
        // A multihomed Mac can advertise the same stable receiver on several interfaces.
        var unique: [UUID: SRTMediaReceiver] = [:]
        for receiver in receivers.values { unique[receiver.id] = receiver }
        let result = unique.values.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }; self.onChange(result, notice)
        }
    }
}
