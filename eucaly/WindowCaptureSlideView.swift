import SwiftUI
import ScreenCaptureKit
import AppKit
import CoreGraphics
import CoreMedia
import CoreImage
import Combine

@available(macOS 12.3, *)
struct WindowCaptureSlideView: View {
    let windowID: CGWindowID
    @StateObject private var streamOutput = WindowStreamOutput()
    @State private var error: Error?
    @State private var activeCaptureWindowID: CGWindowID?
    @State private var activeCaptureOwnerID: UUID?
    @State private var captureOwnerID = UUID()

    var body: some View {
        ZStack {
            Color.black

            if let error = error {
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
            } else if let image = streamOutput.currentFrame {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ProgressView("Starting capture...")
            }
        }
        .task(id: windowID) {
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

@available(macOS 12.3, *)
final class WindowStreamOutput: NSObject, ObservableObject, SCStreamOutput {
    @MainActor @Published private(set) var currentFrame: NSImage?
    private let context = CIContext(options: nil)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        let frame = NSImage(cgImage: cgImage, size: NSSize(
            width: cgImage.width,
            height: cgImage.height
        ))

        Task { @MainActor [weak self] in
            self?.currentFrame = frame
        }
    }

    func clearFrame() {
        Task { @MainActor [weak self] in
            self?.currentFrame = nil
        }
    }
}
