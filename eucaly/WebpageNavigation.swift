import Foundation

nonisolated enum WebpageURLMatcher {
    static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        return url.host(percentEncoded: false)?.isEmpty == false
    }

    static func representSamePage(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return representSamePage(lhs, rhs)
    }

    static func representSamePage(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedIdentity(lhs) == normalizedIdentity(rhs)
    }

    static func matchingURL(in urls: [URL], for url: URL) -> URL? {
        urls.first { representSamePage($0, url) }
    }

    static func normalizedIdentity(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }

        if let scheme = components.scheme {
            components.scheme = scheme.lowercased()
        }
        if let host = components.host {
            components.host = host.lowercased()
        }

        var path = components.path
        if path.isEmpty || path == "/" {
            components.path = ""
        } else if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
            components.path = path
        }

        return components.string ?? url.absoluteString
    }

    static func normalizedURL(from rawValue: String) -> URL? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmedValue), isSupported(url) {
            return url
        }

        let defaultScheme = shouldDefaultToHTTP(trimmedValue) ? "http" : "https"
        let prefixedValue = "\(defaultScheme)://\(trimmedValue)"
        guard let prefixedURL = URL(string: prefixedValue), isSupported(prefixedURL) else {
            return nil
        }

        return prefixedURL
    }

    private static func shouldDefaultToHTTP(_ rawValue: String) -> Bool {
        guard
            let url = URL(string: "http://\(rawValue)"),
            let host = url.host(percentEncoded: false)?.lowercased()
        else {
            return false
        }

        if url.port != nil {
            return true
        }

        return host == "localhost"
            || host == "127.0.0.1"
            || host == "0.0.0.0"
            || host == "::1"
            || host.hasSuffix(".local")
    }
}

nonisolated enum WebpageSlideCatalog {
    static func url(from slides: [Slide]) -> URL? {
        slides.first { $0.webpageURL != nil }?.webpageURL
    }

    static func navigationRevision(from slides: [Slide]) -> Int {
        slides.first { $0.webpageURL != nil }?.webpageNavigationRevision ?? 0
    }

    static func viewIdentity(url: URL, navigationRevision: Int) -> String {
        "\(url.absoluteString)#\(navigationRevision)"
    }

    static func makeSlides(
        from url: URL,
        navigationRevision: Int = 0,
        preservingSlideID: Slide.ID? = nil
    ) -> [Slide] {
        let label = url.host(percentEncoded: false) ?? url.absoluteString
        return [
            Slide(
                id: preservingSlideID ?? UUID(),
                index: 1,
                lines: [],
                label: label,
                videoURL: nil,
                pdfURL: nil,
                pdfPageIndex: nil,
                imageURL: nil,
                webpageURL: url,
                webpageNavigationRevision: navigationRevision
            )
        ]
    }

    static func initialSlides(from url: URL) -> [Slide] {
        makeSlides(from: url, navigationRevision: 0)
    }

    static func navigatedSlides(
        in slides: [Slide],
        to newURL: URL,
        from previousURL: URL
    ) -> [Slide]? {
        guard WebpageURLMatcher.isSupported(newURL) else { return nil }
        guard slides.contains(where: { $0.webpageURL != nil }) else { return nil }
        guard !WebpageURLMatcher.representSamePage(newURL, previousURL) else { return nil }

        let preservedSlideID = slides.first { $0.webpageURL != nil }?.id
        let navigationRevision = navigationRevision(from: slides) + 1
        return makeSlides(
            from: newURL,
            navigationRevision: navigationRevision,
            preservingSlideID: preservedSlideID
        )
    }

    static func shouldPreserveCurrentWebpageOverRestore(
        preservedSlides: [Slide],
        currentSlides: [Slide]
    ) -> Bool {
        guard url(from: currentSlides) != nil else { return false }
        let preservedRevision = navigationRevision(from: preservedSlides)
        let currentRevision = navigationRevision(from: currentSlides)
        return currentRevision > preservedRevision
    }
}

nonisolated enum LiveWebpageTitleCache {
    static let maxEntries = 20

    static func title(for url: URL, in titles: [URL: String]) -> String? {
        guard let key = titles.keys.first(where: { WebpageURLMatcher.representSamePage($0, url) }) else {
            return nil
        }
        return titles[key]
    }

    static func store(
        _ title: String,
        for url: URL,
        titles: inout [URL: String],
        accessOrder: inout [URL]
    ) {
        if let existingKey = titles.keys.first(where: { WebpageURLMatcher.representSamePage($0, url) }) {
            titles.removeValue(forKey: existingKey)
            accessOrder.removeAll { WebpageURLMatcher.representSamePage($0, existingKey) }
        }

        titles[url] = title
        accessOrder.append(url)

        while accessOrder.count > maxEntries {
            let removed = accessOrder.removeFirst()
            if let existingKey = titles.keys.first(where: { WebpageURLMatcher.representSamePage($0, removed) }) {
                titles.removeValue(forKey: existingKey)
            }
        }
    }
}
