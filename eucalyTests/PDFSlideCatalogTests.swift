import XCTest
@testable import eucaly

final class PDFSlideCatalogTests: XCTestCase {
    func testStableSlideIDRoundTripsPageIndex() {
        let url = URL(fileURLWithPath: "/tmp/sample.pdf")
        let slideID = PDFSlideCatalog.stableSlideID(url: url, pageIndex: 42)
        let pageIndex = PDFSlideCatalog.pageIndex(fromStableSlideID: slideID, url: url)
        XCTAssertEqual(pageIndex, 42)
    }

    func testVirtualCatalogThresholdUsesPageLimit() {
        XCTAssertFalse(PDFSlideCatalog.shouldUseVirtualCatalog(pageCount: 100))
        XCTAssertTrue(PDFSlideCatalog.shouldUseVirtualCatalog(pageCount: 101))
        XCTAssertTrue(PDFSlideCatalog.shouldUseVirtualCatalog(pageCount: 278))
    }

    func testSlideFactoryUsesStableIdentity() {
        let url = URL(fileURLWithPath: "/tmp/sample.pdf")
        let slide = PDFSlideCatalog.slide(url: url, pageIndex: 3)
        XCTAssertEqual(slide.pdfPageIndex, 3)
        XCTAssertEqual(slide.id, PDFSlideCatalog.stableSlideID(url: url, pageIndex: 3))
        XCTAssertEqual(slide.label, "Page 4")
    }
}
