import Combine
import Foundation
import HaishinKit
import libsrt

struct SRTSocketURL {
    static let defaultPort: Int = 9710

    private static func getQueryItems(_ url: URL) -> [String: String] {
        let url = url.absoluteString
        if !url.contains("?") {
            return [:]
        }
        let queryString = url.split(separator: "?")[1]
        let queries = queryString.split(separator: "&")
        var paramsReturn: [String: String] = [:]
        for q in queries {
            let query = q.split(separator: "=", maxSplits: 1)
            if query.count == 2 {
                paramsReturn[String(query[0])] = String(query[1])
            }
        }
        return paramsReturn
    }

    let url: URL
    let mode: SRTMode
    let options: [SRTSocketOption]

    var remote: sockaddr_in? {
        guard let host = url.host else {
            return nil
        }
        return .init(host, port: url.port ?? Self.defaultPort)
    }

    var local: sockaddr_in? {
        let queryItems = Self.getQueryItems(url)
        let adapter = queryItems["adapter"] ?? "0.0.0.0"
        if let port = queryItems["port"] {
            return .init(adapter, port: Int(port) ?? url.port ?? Self.defaultPort)
        }
        return .init(adapter, port: url.port ?? Self.defaultPort)
    }

    init?(_ url: URL?) {
        guard let url, let scheme = url.scheme, scheme == "srt" else {
            return nil
        }
        let queryItems = Self.getQueryItems(url)
        var options: [SRTSocketOption] = []
        // SRTO_TRANSTYPE resets live-mode defaults (including latency). Apply it
        // before explicit overrides, regardless of URL/dictionary iteration order.
        let names = queryItems.keys.sorted {
            if $0 == "transtype" { return $1 != "transtype" }
            if $1 == "transtype" { return false }
            return $0 < $1
        }
        for key in names {
            let item = (key: key, value: queryItems[key]!)
            guard let name = SRTSocketOption.Name(rawValue: item.key) else {
                continue
            }
            if let option = try? SRTSocketOption(name: name, value: item.value) {
                options.append(option)
            }
        }
        self.url = url
        self.mode = {
            switch queryItems["mode"] {
            case "client", "caller":
                return .caller
            case "server", "listener":
                return .listener
            case "rendezvous":
                return .rendezvous
            default:
                if queryItems["adapter"] != nil {
                    return .rendezvous
                }
                if url.host?.isEmpty == true {
                    return .listener
                }
                return .caller
            }
        }()
        self.options = options
    }
}
