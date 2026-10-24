import AppKit
import Darwin

// A receiver can disconnect during either SDK's socket write. Let that write
// return EPIPE so the SDK can handle its connection failure, rather than
// terminating this destination's helper. Set the process policy before SDK
// loading, runtime checks, bootstrap or service worker creation.
_ = Darwin.signal(SIGPIPE, SIG_IGN)

// Explicit read-only qualification command for the installed, signed helper.
// It neither creates a sender nor opens a window. The caller owns a finite
// process deadline just as the app supervisor does.
if CommandLine.arguments == [CommandLine.arguments[0], "--check-runtime"]
    || CommandLine.arguments == [CommandLine.arguments[0], "--check-omt-runtime"] {
    do {
        let runtime = try NetworkHelperRuntime(technology: CommandLine.arguments.last == "--check-omt-runtime" ? .omt : .ndi)
        let result = ["runtime": runtime.version]
        let data = try JSONEncoder().encode(result)
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        runtime.close()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
    }
}

// stdin is an inherited private pipe, not a discoverable service name. Bound
// the bootstrap before decoding, then claim the inherited send capability.
let bootstrapData = FileHandle.standardInput.readData(ofLength: NetworkHelperWire.maximumMessageBytes + 1)
guard let bootstrap = try? NetworkHelperWire.decode(NetworkHelperBootstrap.self, bootstrapData),
      bootstrap.version == NetworkHelperWire.version, bootstrap.build == NetworkHelperWire.build,
      bootstrap.parentPID == getppid(), (0..<3).contains(bootstrap.portIndex), bootstrap.configuration.isValid else { _exit(64) }
let parentPort = eucaly_mach_inherited_port(bootstrap.portIndex)
guard parentPort != 0 else { _exit(64) }
NSApplication.shared.setActivationPolicy(.prohibited)
let parent = DispatchSource.makeProcessSource(identifier: bootstrap.parentPID, eventMask: .exit, queue: .global())
parent.setEventHandler { _exit(0) }; parent.resume()
guard getppid() == bootstrap.parentPID else { _exit(0) }
let service = NetworkHelperService(generation: bootstrap.generation, parentPID: bootstrap.parentPID, configuration: bootstrap.configuration)
do { try service.start(parentPort: parentPort) } catch { _exit(70) }
eucaly_mach_send_release(parentPort)
NSApplication.shared.run()
