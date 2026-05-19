import Foundation

struct SecurityScopedBookmarks {
    struct Resolution {
        let url: URL
        let updatedBookmark: String?
    }

    static func createBookmark(for url: URL) -> String? {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return data.base64EncodedString()
        } catch {
            return nil
        }
    }

    static func resolve(_ bookmark: String) -> Resolution? {
        guard !bookmark.isEmpty,
              let data = Data(base64Encoded: bookmark) else {
            return nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            var updatedBookmark: String? = nil
            if isStale {
                updatedBookmark = createBookmark(for: url)
            }
            return Resolution(url: url, updatedBookmark: updatedBookmark)
        } catch {
            return nil
        }
    }
}
