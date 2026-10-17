// swift-tools-version: 6.0
import PackageDescription
// HaishinKit 2.2.5 (dc880cb540b8feeb98f64e8b7dcfaaf320b6b2bd).
// See PATCHES.md for the small playback fixes carried by this source package.
let package = Package(name: "MediaStreaming", platforms: [.macOS(.v12), .tvOS(.v15)],
    products: [.library(name: "SRTHaishinKit", targets: ["SRTHaishinKit"])],
    dependencies: [.package(url: "https://github.com/shogo4405/Logboard.git", exact: "2.6.0"),
        .package(url: "https://github.com/HaishinKit/libsrt-xcframework.git", exact: "1.5.7")],
    targets: [
        .target(name: "HaishinKit", dependencies: ["Logboard"], swiftSettings: [.enableUpcomingFeature("ExistentialAny")]),
        .target(name: "SRTHaishinKit", dependencies: ["HaishinKit", .product(name: "libsrt", package: "libsrt-xcframework")], swiftSettings: [.enableUpcomingFeature("ExistentialAny")])
    ], swiftLanguageModes: [.v6, .v5])
