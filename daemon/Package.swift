// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Switch2Bridge",
    platforms: [.macOS(.v15)],
    targets: [
        // Inicialización por USB: se hace en C porque las interfaces de IOKit
        // son de estilo COM y resultan mucho más claras así.
        .target(
            name: "USBSwitch2",
            path: "Sources/USBSwitch2",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "Switch2Bridge",
            dependencies: ["USBSwitch2"],
            path: "Sources/Switch2Bridge"
        ),
    ]
)
