// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LlamaSPM",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "LlamaSPM",
            targets: ["LlamaSPM"]
        )
    ],
    targets: [
        .target(
            name: "LlamaSPM",
            dependencies: [
                .target(name: "LlamaFramework")
            ]
        ),
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10217/llama-b10217-xcframework.zip",
            checksum: "266c00e5ce847e7011ec72660cb204e5e2693176113e4db0e1f5739f83472f55"
        )
    ]
)
