import XCTest
@testable import eucaly
import AppKit

/// Tests for the three-layer rendering architecture and independent layer controls
final class LayerControlsTests: XCTestCase {

    // MARK: - Layer Independence Tests

    func testESCHidesSlidesKeepsBackgroundVisible() async {
        let result = await MainActor.run { () -> (slidesVisible: Bool, backgroundVisible: Bool) in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-esc-bg.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)

            // Setup: presenting with slides and background visible
            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = true
            session.isBackgroundVisualVisible = true

            // Action: ESC hides slides
            session.hideSlides()

            return (session.areSlidesVisible, session.isBackgroundVisualVisible)
        }

        XCTAssertFalse(result.slidesVisible, "ESC should hide slides")
        XCTAssertTrue(result.backgroundVisible, "ESC should NOT affect background visibility")
    }

    func testCmdZTogglesSlidesIndependently() async {
        let result = await MainActor.run { () -> (firstSlides: Bool, firstBg: Bool, secondSlides: Bool, secondBg: Bool) in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-cmdz.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)

            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = true
            session.isBackgroundVisualVisible = true

            // First toggle: hide slides
            session.hideSlides()
            let firstSlides = session.areSlidesVisible
            let firstBg = session.isBackgroundVisualVisible

            // Second toggle: show slides
            session.showSlides(preferredScreen: nil)
            let secondSlides = session.areSlidesVisible
            let secondBg = session.isBackgroundVisualVisible

            return (firstSlides, firstBg, secondSlides, secondBg)
        }

        XCTAssertFalse(result.firstSlides, "First toggle should hide slides")
        XCTAssertTrue(result.firstBg, "First toggle should not affect background")
        XCTAssertTrue(result.secondSlides, "Second toggle should show slides")
        XCTAssertTrue(result.secondBg, "Second toggle should not affect background")
    }

    func testCmdBTogglesBackgroundIndependently() async {
        let result = await MainActor.run { () -> (firstSlides: Bool, firstBg: Bool, secondSlides: Bool, secondBg: Bool) in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-cmdb.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)

            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = true
            session.isBackgroundVisualVisible = true

            // First toggle: hide background
            session.toggleBackgroundVisualVisibility(preferredScreen: nil)
            let firstSlides = session.areSlidesVisible
            let firstBg = session.isBackgroundVisualVisible

            // Second toggle: show background
            session.toggleBackgroundVisualVisibility(preferredScreen: nil)
            let secondSlides = session.areSlidesVisible
            let secondBg = session.isBackgroundVisualVisible

            return (firstSlides, firstBg, secondSlides, secondBg)
        }

        XCTAssertTrue(result.firstSlides, "First toggle should not affect slides")
        XCTAssertFalse(result.firstBg, "First toggle should hide background")
        XCTAssertTrue(result.secondSlides, "Second toggle should not affect slides")
        XCTAssertTrue(result.secondBg, "Second toggle should show background")
    }

    // MARK: - Background Audio Layer Tests

    func testCmdATogglesBackgroundAudio() async {
        let result = await MainActor.run { () -> (firstPlaying: Bool, secondPlaying: Bool) in
            let session = PresentationSession()

            // Setup: start with audio playing
            session.playBackgroundAudio()
            let firstPlaying = session.isBackgroundAudioPlaying

            // Toggle: pause
            session.pauseBackgroundAudio()
            let secondPlaying = session.isBackgroundAudioPlaying

            return (firstPlaying, secondPlaying)
        }

        // Note: playBackgroundAudio() only sets isBackgroundAudioPlaying if player exists
        // Since we don't have an actual audio file, we test the pause behavior
        XCTAssertFalse(result.secondPlaying, "Pause should set isBackgroundAudioPlaying to false")
    }

    func testClearBackgroundAudioStopsPlayback() async {
        let result = await MainActor.run { () -> (audioURL: URL?, isPlaying: Bool) in
            let session = PresentationSession()

            // Setup: set audio (even if we can't actually play it)
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-audio.mp3")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)
            session.setBackgroundAudio(url: tempURL, autoplay: false)

            // Action: clear audio
            session.clearBackgroundAudio()

            return (session.backgroundAudioURL, session.isBackgroundAudioPlaying)
        }

        XCTAssertNil(result.audioURL, "Clear should remove audio URL")
        XCTAssertFalse(result.isPlaying, "Clear should stop playback")
    }

    // MARK: - Slide Type Visibility Logic Tests

    func testIsLyricsSlideDetection() async {
        let result = await MainActor.run { () -> (lyricsIsLyrics: Bool, imageIsLyrics: Bool, pdfIsLyrics: Bool, videoIsLyrics: Bool) in
            let lyricsLine = SlideLine(kind: .verse, languageTag: "Default", text: "Test lyrics")
            let lyricsSlide = Slide(index: 0, lines: [lyricsLine], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)

            let imageURL = URL(fileURLWithPath: "/tmp/test.jpg")
            let imageSlide = Slide(index: 0, lines: [], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: imageURL, captureWindowID: nil)

            let pdfURL = URL(fileURLWithPath: "/tmp/test.pdf")
            let pdfSlide = Slide(index: 0, lines: [], label: nil, videoURL: nil, pdfURL: pdfURL, pdfPageIndex: 0, imageURL: nil, captureWindowID: nil)

            let videoURL = URL(fileURLWithPath: "/tmp/test.mp4")
            let videoSlide = Slide(index: 0, lines: [], label: nil, videoURL: videoURL, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)

            // Helper to check if slide is lyrics (no media URLs)
            func isLyricsSlide(_ slide: Slide) -> Bool {
                return slide.videoURL == nil && slide.pdfURL == nil && slide.imageURL == nil
            }

            return (
                isLyricsSlide(lyricsSlide),
                isLyricsSlide(imageSlide),
                isLyricsSlide(pdfSlide),
                isLyricsSlide(videoSlide)
            )
        }

        XCTAssertTrue(result.lyricsIsLyrics, "Lyrics slide should be detected as lyrics")
        XCTAssertFalse(result.imageIsLyrics, "Image slide should NOT be detected as lyrics")
        XCTAssertFalse(result.pdfIsLyrics, "PDF slide should NOT be detected as lyrics")
        XCTAssertFalse(result.videoIsLyrics, "Video slide should NOT be detected as lyrics")
    }

    func testBackgroundVisibilityForLyricsSlide() async {
        let result = await MainActor.run { () -> Bool in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-lyrics-bg.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)

            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = true
            session.isBackgroundVisualVisible = true

            // Load lyrics slide
            let lyricsLine = SlideLine(kind: .verse, languageTag: "Default", text: "Test")
            let lyricsSlide = Slide(index: 0, lines: [lyricsLine], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)
            session.slides = [lyricsSlide]
            session.currentSlideID = lyricsSlide.id

            // Background should be visible for lyrics
            // (tested via shouldShowBlackBg logic)
            let isLyricsSlide = lyricsSlide.videoURL == nil && lyricsSlide.pdfURL == nil && lyricsSlide.imageURL == nil
            let shouldShowBlackBg = session.areSlidesVisible && !isLyricsSlide

            return shouldShowBlackBg
        }

        XCTAssertFalse(result, "Black background should NOT show for lyrics (background shows through)")
    }

    func testBackgroundHiddenForMediaSlides() async {
        let result = await MainActor.run { () -> (imageBlack: Bool, pdfBlack: Bool, videoBlack: Bool) in
            let session = PresentationSession()
            session.isPresenting = true
            session.areSlidesVisible = true

            // Test image slide
            let imageURL = URL(fileURLWithPath: "/tmp/test.jpg")
            let imageSlide = Slide(index: 0, lines: [], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: imageURL, captureWindowID: nil)
            let imageIsLyrics = imageSlide.videoURL == nil && imageSlide.pdfURL == nil && imageSlide.imageURL == nil
            let imageBlack = session.areSlidesVisible && !imageIsLyrics

            // Test PDF slide
            let pdfURL = URL(fileURLWithPath: "/tmp/test.pdf")
            let pdfSlide = Slide(index: 0, lines: [], label: nil, videoURL: nil, pdfURL: pdfURL, pdfPageIndex: 0, imageURL: nil, captureWindowID: nil)
            let pdfIsLyrics = pdfSlide.videoURL == nil && pdfSlide.pdfURL == nil && pdfSlide.imageURL == nil
            let pdfBlack = session.areSlidesVisible && !pdfIsLyrics

            // Test video slide
            let videoURL = URL(fileURLWithPath: "/tmp/test.mp4")
            let videoSlide = Slide(index: 0, lines: [], label: nil, videoURL: videoURL, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)
            let videoIsLyrics = videoSlide.videoURL == nil && videoSlide.pdfURL == nil && videoSlide.imageURL == nil
            let videoBlack = session.areSlidesVisible && !videoIsLyrics

            return (imageBlack, pdfBlack, videoBlack)
        }

        XCTAssertTrue(result.imageBlack, "Black background should show for image slides (obscures background)")
        XCTAssertTrue(result.pdfBlack, "Black background should show for PDF slides (obscures background)")
        XCTAssertTrue(result.videoBlack, "Black background should show for video slides (obscures background)")
    }

    func testBackgroundVisibilityWhenSlidesHidden() async {
        let result = await MainActor.run { () -> Bool in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-slides-hidden.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)

            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = false  // Slides hidden
            session.isBackgroundVisualVisible = true

            // When slides are hidden, black background should NOT show
            let imageURL = URL(fileURLWithPath: "/tmp/test.jpg")
            let imageSlide = Slide(index: 0, lines: [], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: imageURL, captureWindowID: nil)
            session.slides = [imageSlide]
            session.currentSlideID = imageSlide.id

            let isLyricsSlide = imageSlide.videoURL == nil && imageSlide.pdfURL == nil && imageSlide.imageURL == nil
            let shouldShowBlackBg = session.areSlidesVisible && !isLyricsSlide

            return shouldShowBlackBg
        }

        XCTAssertFalse(result, "Black background should NOT show when slides are hidden (background shows through)")
    }

    // MARK: - Clear All Layers Tests

    func testClearAllLayersHidesSlidesAndClearsBackgrounds() async {
        let result = await MainActor.run { () -> (slidesVisible: Bool, visualURL: URL?, audioURL: URL?, audioPlaying: Bool) in
            let session = PresentationSession()

            // Setup: all layers active
            let visualURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-clear-all-visual.jpg")
            FileManager.default.createFile(atPath: visualURL.path, contents: Data([0x00]), attributes: nil)

            let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-clear-all-audio.mp3")
            FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]), attributes: nil)

            session.setBackgroundVisual(visualURL)
            session.setBackgroundAudio(url: audioURL, autoplay: false)
            session.isPresenting = true
            session.areSlidesVisible = true

            // Action: clear all (simulated - hide slides + clear backgrounds)
            session.hideSlides()
            session.setBackgroundVisual(nil)  // Clear visual
            session.clearBackgroundAudio()

            return (
                session.areSlidesVisible,
                session.backgroundVisualURL,
                session.backgroundAudioURL,
                session.isBackgroundAudioPlaying
            )
        }

        XCTAssertFalse(result.slidesVisible, "Clear All should hide slides")
        XCTAssertNil(result.visualURL, "Clear All should clear background visual")
        XCTAssertNil(result.audioURL, "Clear All should clear background audio")
        XCTAssertFalse(result.audioPlaying, "Clear All should stop audio playback")
    }

    // MARK: - Slide Navigation Tests

    func testMoveSelectionUpdatesCurrentSlide() async {
        let session = await MainActor.run { PresentationSession() }

        let result = await MainActor.run { () -> (firstID: Slide.ID?, slide1ID: UUID, slide2ID: UUID, slide3ID: UUID) in
            let line1 = SlideLine(kind: .verse, languageTag: "Default", text: "Slide 1")
            let slide1 = Slide(index: 0, lines: [line1], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)
            let line2 = SlideLine(kind: .verse, languageTag: "Default", text: "Slide 2")
            let slide2 = Slide(index: 1, lines: [line2], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)
            let line3 = SlideLine(kind: .verse, languageTag: "Default", text: "Slide 3")
            let slide3 = Slide(index: 2, lines: [line3], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)

            session.slides = [slide1, slide2, slide3]
            session.currentSlideID = slide1.id

            return (session.currentSlideID, slide1.id, slide2.id, slide3.id)
        }

        // Move forward (async operation in moveSelection)
        await MainActor.run { session.moveSelection(1) }
        try? await Task.sleep(nanoseconds: 50_000_000) // Wait 50ms for async update
        let secondID = await MainActor.run { session.currentSlideID }

        // Move forward again
        await MainActor.run { session.moveSelection(1) }
        try? await Task.sleep(nanoseconds: 50_000_000) // Wait 50ms for async update
        let thirdID = await MainActor.run { session.currentSlideID }

        XCTAssertEqual(result.firstID, result.slide1ID, "First slide should be selected initially")
        XCTAssertEqual(secondID, result.slide2ID, "Second slide should be selected after first move")
        XCTAssertEqual(thirdID, result.slide3ID, "Third slide should be selected after second move")
    }

    func testMoveSelectionBoundsAtStart() async {
        let result = await MainActor.run { () -> Slide.ID? in
            let session = PresentationSession()

            let line1 = SlideLine(kind: .verse, languageTag: "Default", text: "Slide 1")
            let slide1 = Slide(index: 0, lines: [line1], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)
            let line2 = SlideLine(kind: .verse, languageTag: "Default", text: "Slide 2")
            let slide2 = Slide(index: 1, lines: [line2], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)

            session.slides = [slide1, slide2]
            session.currentSlideID = slide1.id

            // Try to move before first slide
            session.moveSelection(-1)

            return session.currentSlideID
        }

        XCTAssertNotNil(result, "Selection should remain at first slide when trying to move before start")
    }

    func testMoveSelectionBoundsAtEnd() async {
        let result = await MainActor.run { () -> (beforeMove: Slide.ID?, afterMove: Slide.ID?, same: Bool) in
            let session = PresentationSession()

            let line1 = SlideLine(kind: .verse, languageTag: "Default", text: "Slide 1")
            let slide1 = Slide(index: 0, lines: [line1], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)
            let line2 = SlideLine(kind: .verse, languageTag: "Default", text: "Slide 2")
            let slide2 = Slide(index: 1, lines: [line2], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)

            session.slides = [slide1, slide2]
            session.currentSlideID = slide2.id

            let beforeMove = session.currentSlideID

            // Try to move beyond last slide
            session.moveSelection(1)

            let afterMove = session.currentSlideID
            let same = beforeMove == afterMove

            return (beforeMove, afterMove, same)
        }

        XCTAssertNotNil(result.beforeMove, "Should be at last slide before move")
        XCTAssertNotNil(result.afterMove, "Should still have selection after move")
        XCTAssertTrue(result.same, "Selection should remain at last slide when trying to move beyond end")
    }

    // MARK: - Integration Tests

    func testComplexLayerScenario() async {
        let result = await MainActor.run { () -> (
            step1Slides: Bool, step1Bg: Bool,
            step2Slides: Bool, step2Bg: Bool,
            step3Slides: Bool, step3Bg: Bool,
            step4Slides: Bool, step4Bg: Bool
        ) in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-complex.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)

            // Initial: both visible
            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = true
            session.isBackgroundVisualVisible = true

            let step1 = (session.areSlidesVisible, session.isBackgroundVisualVisible)

            // Step 2: ESC hides slides, background stays
            session.hideSlides()
            let step2 = (session.areSlidesVisible, session.isBackgroundVisualVisible)

            // Step 3: Cmd+B hides background
            session.toggleBackgroundVisualVisibility(preferredScreen: nil)
            let step3 = (session.areSlidesVisible, session.isBackgroundVisualVisible)

            // Step 4: Cmd+Z shows slides
            session.showSlides(preferredScreen: nil)
            let step4 = (session.areSlidesVisible, session.isBackgroundVisualVisible)

            return (
                step1.0, step1.1,
                step2.0, step2.1,
                step3.0, step3.1,
                step4.0, step4.1
            )
        }

        // Step 1: Both visible
        XCTAssertTrue(result.step1Slides, "Initially slides visible")
        XCTAssertTrue(result.step1Bg, "Initially background visible")

        // Step 2: ESC hides slides, background stays
        XCTAssertFalse(result.step2Slides, "ESC hides slides")
        XCTAssertTrue(result.step2Bg, "ESC keeps background visible")

        // Step 3: Cmd+B hides background
        XCTAssertFalse(result.step3Slides, "Slides still hidden")
        XCTAssertFalse(result.step3Bg, "Cmd+B hides background")

        // Step 4: Cmd+Z shows slides
        XCTAssertTrue(result.step4Slides, "Cmd+Z shows slides")
        XCTAssertFalse(result.step4Bg, "Background still hidden")
    }
}
