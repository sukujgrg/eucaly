import XCTest
@testable import eucaly

final class WebpageNavigationTests: XCTestCase {
    func testIsSupportedAcceptsHTTPAndHTTPSWithHost() {
        XCTAssertTrue(WebpageURLMatcher.isSupported(URL(string: "https://example.com")!))
        XCTAssertTrue(WebpageURLMatcher.isSupported(URL(string: "http://localhost:8080/path")!))
        XCTAssertFalse(WebpageURLMatcher.isSupported(URL(string: "file:///tmp/page.html")!))
        XCTAssertFalse(WebpageURLMatcher.isSupported(URL(string: "https:///missing-host")!))
    }

    func testRepresentSamePageIgnoresTrailingSlashAndSchemeCase() {
        let withSlash = URL(string: "https://Example.com/page/")!
        let withoutSlash = URL(string: "HTTPS://example.com/page")!

        XCTAssertTrue(WebpageURLMatcher.representSamePage(withSlash, withoutSlash))
    }

    func testRepresentSamePageTreatsDifferentPathsAsDistinct() {
        let first = URL(string: "https://example.com/a")!
        let second = URL(string: "https://example.com/b")!

        XCTAssertFalse(WebpageURLMatcher.representSamePage(first, second))
    }

    func testRepresentSamePageTreatsDifferentFragmentsAsDistinct() {
        let first = URL(string: "https://example.com/app#/song/1")!
        let second = URL(string: "https://example.com/app#/song/2")!

        XCTAssertFalse(WebpageURLMatcher.representSamePage(first, second))
    }

    func testRepresentSamePagePreservesPathCase() {
        let upper = URL(string: "https://example.com/Song")!
        let lower = URL(string: "https://example.com/song")!

        XCTAssertFalse(WebpageURLMatcher.representSamePage(upper, lower))
    }

    func testNavigatedSlidesAcceptsHashNavigation() {
        let slides = WebpageSlideCatalog.initialSlides(from: URL(string: "https://example.com/app#/song/1")!)
        let destination = URL(string: "https://example.com/app#/song/2")!

        let navigated = WebpageSlideCatalog.navigatedSlides(
            in: slides,
            to: destination,
            from: URL(string: "https://example.com/app#/song/1")!
        )

        XCTAssertEqual(navigated?.first?.webpageURL, destination)
        XCTAssertEqual(navigated?.first?.webpageNavigationRevision, 1)
    }

    func testNormalizedURLAddsSchemeForLocalhost() {
        XCTAssertEqual(
            WebpageURLMatcher.normalizedURL(from: "localhost:8000/path")?.absoluteString,
            "http://localhost:8000/path"
        )
    }

    func testNavigatedSlidesIncrementsRevisionAndPreservesSlideID() {
        let slideID = UUID()
        let initial = WebpageSlideCatalog.makeSlides(
            from: URL(string: "https://example.com/start")!,
            navigationRevision: 2,
            preservingSlideID: slideID
        )
        let start = URL(string: "https://example.com/start")!
        let destination = URL(string: "https://example.com/destination")!

        let navigated = WebpageSlideCatalog.navigatedSlides(
            in: initial,
            to: destination,
            from: start
        )

        XCTAssertEqual(navigated?.count, 1)
        XCTAssertEqual(navigated?.first?.id, slideID)
        XCTAssertEqual(navigated?.first?.webpageURL, destination)
        XCTAssertEqual(navigated?.first?.webpageNavigationRevision, 3)
    }

    func testNavigatedSlidesReturnsNilForUnsupportedOrDuplicateNavigation() {
        let slides = WebpageSlideCatalog.initialSlides(from: URL(string: "https://example.com")!)
        let same = URL(string: "https://example.com/")!

        XCTAssertNil(
            WebpageSlideCatalog.navigatedSlides(
                in: slides,
                to: same,
                from: URL(string: "https://example.com")!
            )
        )
        XCTAssertNil(
            WebpageSlideCatalog.navigatedSlides(
                in: slides,
                to: URL(string: "file:///tmp/test")!,
                from: URL(string: "https://example.com")!
            )
        )
    }

    func testShouldPreserveCurrentWebpageOverRestoreWhenRevisionAdvanced() {
        let preserved = WebpageSlideCatalog.makeSlides(
            from: URL(string: "https://example.com/a")!,
            navigationRevision: 1
        )
        let slideID = preserved[0].id
        let current = WebpageSlideCatalog.makeSlides(
            from: URL(string: "https://example.com/b")!,
            navigationRevision: 2,
            preservingSlideID: slideID
        )

        XCTAssertTrue(
            WebpageSlideCatalog.shouldPreserveCurrentWebpageOverRestore(
                preservedSlides: preserved,
                currentSlides: current
            )
        )
    }

    func testLiveWebpageTitleCacheFindsTitleAcrossTrailingSlashVariants() {
        var titles: [URL: String] = [:]
        var order: [URL] = []

        LiveWebpageTitleCache.store(
            "Example",
            for: URL(string: "https://example.com/")!,
            titles: &titles,
            accessOrder: &order
        )

        XCTAssertEqual(
            LiveWebpageTitleCache.title(for: URL(string: "https://example.com")!, in: titles),
            "Example"
        )
    }

    func testMatchingURLFindsSavedEntryAcrossTrailingSlashVariants() {
        let saved = URL(string: "https://example.com")!
        let reported = URL(string: "https://example.com/")!

        XCTAssertEqual(WebpageURLMatcher.matchingURL(in: [saved], for: reported), saved)
    }

    func testLiveWebpageTitleCacheTrimsToMaxEntries() {
        var titles: [URL: String] = [:]
        var order: [URL] = []

        for index in 0..<(LiveWebpageTitleCache.maxEntries + 5) {
            let url = URL(string: "https://example.com/page-\(index)")!
            LiveWebpageTitleCache.store("Title \(index)", for: url, titles: &titles, accessOrder: &order)
        }

        XCTAssertEqual(titles.count, LiveWebpageTitleCache.maxEntries)
        XCTAssertEqual(order.count, LiveWebpageTitleCache.maxEntries)
        XCTAssertNil(LiveWebpageTitleCache.title(for: URL(string: "https://example.com/page-0")!, in: titles))
        XCTAssertNotNil(
            LiveWebpageTitleCache.title(
                for: URL(string: "https://example.com/page-\(LiveWebpageTitleCache.maxEntries + 4)")!,
                in: titles
            )
        )
    }

    func testViewIdentityIncludesRevision() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(
            WebpageSlideCatalog.viewIdentity(url: url, navigationRevision: 3),
            "https://example.com#3"
        )
    }
}
