// swift-tools-version: 5.9
// libFLAC 1.5.0 decoder (https://github.com/xiph/flac, tag 1.5.0, commit 1507800), BSD licence in
// COPYING.Xiph. Only the files the stream decoder needs, unmodified; config.h is ours.
import PackageDescription

let package = Package(
    name: "CFLAC",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CFLAC", targets: ["CFLAC"])],
    targets: [
        .target(
            name: "CFLAC",
            // Included by bitreader.c and lpc.c, not compiled on their own.
            exclude: ["deduplication"],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .define("NDEBUG"),
                .headerSearchPath("."),
                .headerSearchPath("internal"),
                // Upstream narrows 64-bit values on purpose.
                .unsafeFlags(["-Wno-shorten-64-to-32"]),
            ]
        ),
    ]
)
