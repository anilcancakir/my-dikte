// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyDikte",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "MyDikte", targets: ["MyDikte"]),
        .executable(name: "mydikte-probe", targets: ["mydikte-probe"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MyDikteKit",
            path: "Sources/MyDikteKit"
        ),
        .executableTarget(
            name: "MyDikte",
            dependencies: ["MyDikteKit"],
            path: "Sources/MyDikte"
        ),
        .executableTarget(
            name: "mydikte-probe",
            path: "Sources/mydikte-probe"
        ),
        .testTarget(
            name: "MyDikteTests",
            dependencies: ["MyDikte", "MyDikteKit"],
            path: "Tests/MyDikteTests"
        ),
    ]
)
