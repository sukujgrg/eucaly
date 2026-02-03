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
            await switchCapture(to: windowID)
        }
        .onDisappear {
            Task {
                await tearDownCapture()
            }
        }
    }

    private func switchCapture(to targetWindowID: CGWindowID) async {
        if let currentWindowID = activeCaptureWindowID, currentWindowID != targetWindowID {
            try? await ScreenCaptureManager.shared.stopCapture(windowID: currentWindowID)
            activeCaptureWindowID = nil
            streamOutput.clearFrame()
        }

        error = nil
        do {
            _ = try await ScreenCaptureManager.shared.startCapture(
                windowID: targetWindowID,
                outputHandler: streamOutput
            )
            activeCaptureWindowID = targetWindowID
        } catch {
            self.error = error
            streamOutput.clearFrame()
        }
    }

    private func tearDownCapture() async {
        if let currentWindowID = activeCaptureWindowID {
            try? await ScreenCaptureManager.shared.stopCapture(windowID: currentWindowID)
        }
        activeCaptureWindowID = nil
        streamOutput.clearFrame()
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
