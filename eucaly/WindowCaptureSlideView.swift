import SwiftUI
import ScreenCaptureKit
import AppKit
import CoreGraphics
import CoreMedia
import CoreImage

nonisolated enum WindowCaptureFrameRate {
    static func normalized(_ value: Int) -> Int {
        switch value {
        case 24, 30, 60:
            return value
        default:
            return 60
        }
    }
}

nonisolated struct WindowCaptureFrameGate {
    private var minimumFrameInterval = CMTime(value: 1, timescale: 60)
    private var minimumFrameIntervalNanoseconds: UInt64 = 1_000_000_000 / 60
    private var lastAcceptedFrameTime = CMTime.invalid
    private var lastAcceptedFrameUptime: UInt64 = 0

    init(frameRate: Int = 60) {
        updateFrameRate(frameRate)
    }

    mutating func updateFrameRate(_ frameRate: Int) {
        let normalizedFrameRate = WindowCaptureFrameRate.normalized(frameRate)
        minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(normalizedFrameRate))
        minimumFrameIntervalNanoseconds = 1_000_000_000 / UInt64(normalizedFrameRate)
        lastAcceptedFrameTime = .invalid
        lastAcceptedFrameUptime = 0
    }

    mutating func shouldAcceptFrame(
        at frameTime: CMTime,
        fallbackUptimeNanoseconds: UInt64
    ) -> Bool {
        if frameTime.isValid {
            if !lastAcceptedFrameTime.isValid
                || CMTimeSubtract(frameTime, lastAcceptedFrameTime) >= minimumFrameInterval {
                lastAcceptedFrameTime = frameTime
                return true
            }
            return false
        }

        if lastAcceptedFrameUptime == 0
            || fallbackUptimeNanoseconds - lastAcceptedFrameUptime >= minimumFrameIntervalNanoseconds {
            lastAcceptedFrameUptime = fallbackUptimeNanoseconds
            return true
        }

        return false
    }
}

nonisolated struct WindowCaptureCommitGeneration {
    private var value = 0

    var current: Int {
        value
    }

    mutating func advance() {
        value += 1
    }

    func allowsCommit(_ generation: Int) -> Bool {
        generation == value
    }
}

@available(macOS 14.0, *)
struct WindowCaptureSlideView: View {
    let windowID: CGWindowID
    @ObservedObject private var captureManager = ScreenCaptureManager.shared
    @State private var streamOutput = WindowStreamOutput()
    @State private var error: Error?
    @State private var activeCaptureWindowID: CGWindowID?
    @State private var activeCaptureOwnerID: UUID?
    @State private var captureOwnerID = UUID()

    var body: some View {
        let isWindowAvailable = captureManager.hasPickedWindow(windowID)
        ZStack {
            Color.black

            if !isWindowAvailable {
                unavailableWindowView
            } else if let error = error {
                captureErrorView(error)
            } else {
                WindowCaptureLayerView(streamOutput: streamOutput)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(windowID)-\(isWindowAvailable)") {
            guard isWindowAvailable else {
                error = nil
                streamOutput.clearFrame()
                return
            }
            captureOwnerID = UUID()
            let ownerID = captureOwnerID
            await switchCapture(to: windowID, ownerID: ownerID)
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } onCancel: {
                Task { @MainActor in
                    await tearDownCapture(windowID: windowID, ownerID: ownerID)
                }
            }
        }
    }

    private var unavailableWindowView: some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.yellow)
            Text("Window Unavailable")
                .font(.headline)
            Text("Load the newly picked window to Current, or pick this window again.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func captureErrorView(_ error: Error) -> some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.yellow)
            Text("Capture Error")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func switchCapture(to targetWindowID: CGWindowID, ownerID: UUID) async {
        if let currentWindowID = activeCaptureWindowID, currentWindowID != targetWindowID {
            try? await ScreenCaptureManager.shared.stopCapture(
                windowID: currentWindowID,
                ownerID: activeCaptureOwnerID
            )
            activeCaptureWindowID = nil
            activeCaptureOwnerID = nil
            streamOutput.clearFrame()
        }

        error = nil
        streamOutput.setFrameRate(ScreenCaptureManager.shared.normalizedPreferredFrameRate)
        do {
            _ = try await ScreenCaptureManager.shared.startCapture(
                windowID: targetWindowID,
                ownerID: ownerID,
                outputHandler: streamOutput
            )
            activeCaptureWindowID = targetWindowID
            activeCaptureOwnerID = ownerID
        } catch {
            self.error = error
            streamOutput.clearFrame()
        }
    }

    private func tearDownCapture(windowID: CGWindowID, ownerID: UUID) async {
        try? await ScreenCaptureManager.shared.stopCapture(windowID: windowID, ownerID: ownerID)
        if activeCaptureWindowID == windowID, activeCaptureOwnerID == ownerID {
            activeCaptureWindowID = nil
            activeCaptureOwnerID = nil
            streamOutput.clearFrame()
        }
    }
}

// MARK: - Stream Output Handler

@available(macOS 14.0, *)
private struct WindowCaptureLayerView: NSViewRepresentable {
    let streamOutput: WindowStreamOutput

    func makeCoordinator() -> Coordinator {
        Coordinator(streamOutput: streamOutput)
    }

    func makeNSView(context: Context) -> WindowCaptureLayerHostView {
        let view = WindowCaptureLayerHostView()
        streamOutput.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: WindowCaptureLayerHostView, context: Context) {
        streamOutput.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: WindowCaptureLayerHostView, coordinator: Coordinator) {
        coordinator.streamOutput.detach(from: nsView)
    }

    final class Coordinator {
        let streamOutput: WindowStreamOutput

        init(streamOutput: WindowStreamOutput) {
            self.streamOutput = streamOutput
        }
    }
}

@available(macOS 14.0, *)
private final class WindowCaptureLayerHostView: NSView {
    private var didConfigureLayer = false
    private var currentContentsScale: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayerIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayerIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScaleIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScaleIfNeeded()
    }

    private func configureLayerIfNeeded() {
        guard !didConfigureLayer else { return }
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
        didConfigureLayer = true
        updateContentsScaleIfNeeded()
    }

    private func updateContentsScaleIfNeeded() {
        let nextScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard currentContentsScale != nextScale else { return }
        currentContentsScale = nextScale
        layer?.contentsScale = nextScale
    }

    func displayFrame(_ image: CGImage) {
        configureLayerIfNeeded()
        layer?.contents = image
    }

    func clearFrame() {
        layer?.contents = nil
    }
}

@available(macOS 14.0, *)
private final class WindowStreamOutput: NSObject, SCStreamOutput {
    private struct CapturedFrame: @unchecked Sendable {
        let image: CGImage
    }

    private let context = CIContext(options: nil)
    private let frameGateLock = NSLock()
    private let pendingFrameLock = NSLock()

    private var frameGate = WindowCaptureFrameGate()
    private var pendingFrame: CapturedFrame?
    private var isCommitScheduled = false
    private var commitGeneration = WindowCaptureCommitGeneration()

    @MainActor private weak var targetView: WindowCaptureLayerHostView?

    @MainActor
    func attach(to view: WindowCaptureLayerHostView) {
        targetView = view
    }

    @MainActor
    func detach(from view: WindowCaptureLayerHostView) {
        if targetView === view {
            targetView = nil
        }
        view.clearFrame()
    }

    func setFrameRate(_ frameRate: Int) {
        frameGateLock.lock()
        frameGate.updateFrameRate(frameRate)
        frameGateLock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let frameTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard shouldAcceptFrame(at: frameTime) else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        scheduleCommit(CapturedFrame(image: cgImage))
    }

    func clearFrame() {
        pendingFrameLock.lock()
        pendingFrame = nil
        commitGeneration.advance()
        isCommitScheduled = false
        pendingFrameLock.unlock()

        Task { @MainActor [weak self] in
            self?.targetView?.clearFrame()
        }
    }

    private func shouldAcceptFrame(at frameTime: CMTime) -> Bool {
        frameGateLock.lock()
        defer { frameGateLock.unlock() }

        return frameGate.shouldAcceptFrame(
            at: frameTime,
            fallbackUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    private func scheduleCommit(_ frame: CapturedFrame) {
        pendingFrameLock.lock()
        pendingFrame = frame
        let generation = commitGeneration.current
        guard !isCommitScheduled else {
            pendingFrameLock.unlock()
            return
        }
        isCommitScheduled = true
        pendingFrameLock.unlock()

        Task { @MainActor [weak self] in
            self?.commitLatestFrame(generation: generation)
        }
    }

    @MainActor
    private func commitLatestFrame(generation: Int) {
        pendingFrameLock.lock()
        guard commitGeneration.allowsCommit(generation) else {
            pendingFrameLock.unlock()
            return
        }
        let frame = pendingFrame
        pendingFrame = nil
        isCommitScheduled = false
        pendingFrameLock.unlock()

        if let frame {
            targetView?.displayFrame(frame.image)
        }
    }
}
