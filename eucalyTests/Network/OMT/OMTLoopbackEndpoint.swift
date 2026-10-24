import Foundation
import Darwin
@testable import eucaly

/// SDK loopback tests use the owned sender's TCP listener. The SDK's advertised
/// HOSTNAME (NAME) is a Bonjour discovery key, so using it would make these
/// media round trips depend on the test machine's multicast/DNS configuration.
nonisolated enum OMTLoopbackEndpoint {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let reason): "OMT loopback endpoint: \(reason)" }
        }
    }

    static func address(for supervisor: NetworkHelperSupervisor, generation: UUID) async throws -> String {
        try await address(currentPID: {
            await supervisor.diagnosticProcessIdentifier(generation: generation)
        }, listenerListing: { pid in
            try await Task.detached(priority: .userInitiated) { try listeners(for: pid) }.value
        })
    }

    /// Recheck the owner after inspection: a retired generation's socket must
    /// never become the endpoint of a receiver started by a late continuation.
    static func address(currentPID: @Sendable () async -> Int32?,
                        listenerListing: @Sendable (Int32) async throws -> String) async throws -> String {
        guard let pid = await currentPID(), pid > 0 else {
            throw Failure.unavailable("The requested helper generation has no running sender.")
        }
        let listing = try await listenerListing(pid)
        guard await currentPID() == pid else {
            throw Failure.unavailable("The sender retired or changed while its TCP listener was inspected.")
        }
        return try address(from: listing, expectedPID: pid)
    }

    private static func listeners(for pid: Int32) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        process.standardOutput = output
        process.standardError = output
        do { try process.run() }
        catch { throw Failure.unavailable("Could not inspect sender PID \(pid): \(error.localizedDescription)") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.unavailable("Listener inspection failed for sender PID \(pid) (status \(process.terminationStatus)): \(detail.isEmpty ? "no TCP listener" : detail)")
        }
        guard let listing = String(data: data, encoding: .utf8) else {
            throw Failure.unavailable("Sender PID \(pid) returned invalid listener text.")
        }
        return listing
    }

    static func address(from listing: String, expectedPID: Int32) throws -> String {
        guard expectedPID > 0 else { throw Failure.unavailable("The expected sender PID is invalid.") }
        var foundPID = false
        var waitingForName = false
        var ports = Set<UInt16>()
        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            switch line.first {
            case "p":
                guard !foundPID, let pid = Int32(line.dropFirst()), pid == expectedPID,
                      line.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
                    throw Failure.unavailable("Listener inspection did not identify only sender PID \(expectedPID).")
                }
                foundPID = true
            case "f":
                // lsof always emits descriptor fields, even with -Fpn.
                guard foundPID, !waitingForName, !line.dropFirst().isEmpty,
                      line.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
                    throw Failure.unavailable("Sender PID \(expectedPID) returned a malformed listener descriptor.")
                }
                waitingForName = true
            case "n":
                guard foundPID, waitingForName, let separator = line.lastIndex(of: ":"),
                      let port = UInt16(line[line.index(after: separator)...]), port > 0,
                      line[line.index(after: separator)...].allSatisfy({ $0.isASCII && $0.isNumber }),
                      isNumericHost(String(line[line.index(after: line.startIndex)..<separator])) else {
                    throw Failure.unavailable("Sender PID \(expectedPID) returned a malformed TCP listener.")
                }
                ports.insert(port)
                waitingForName = false
            default:
                throw Failure.unavailable("Sender PID \(expectedPID) returned an unexpected listener field.")
            }
        }
        guard foundPID, !waitingForName, ports.count == 1, let port = ports.first else {
            throw Failure.unavailable("Expected one TCP listener port for sender PID \(expectedPID); found \(ports.count).")
        }
        return "omt://127.0.0.1:\(port)"
    }

    private static func isNumericHost(_ host: String) -> Bool {
        if host == "*" { return true }
        guard !host.utf8.contains(0) else { return false }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        let ipv6Host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return ipv6Host.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }
}
