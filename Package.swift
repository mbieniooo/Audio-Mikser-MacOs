// swift-tools-version:6.0
import PackageDescription

let lang: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
  name: "Mikser",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "Mikser", targets: ["Mikser"]),
    .executable(name: "mikser-selftest", targets: ["MikserSelfTest"]),
    .executable(name: "mikserctl", targets: ["MikserCtl"]),
  ],
  targets: [
    .target(name: "MikserCore", swiftSettings: lang),
    .executableTarget(name: "Mikser", dependencies: ["MikserCore"], swiftSettings: lang),
    .executableTarget(name: "MikserSelfTest", dependencies: ["MikserCore"], swiftSettings: lang),
    .executableTarget(name: "MikserCtl", dependencies: ["MikserCore"], swiftSettings: lang),
  ]
)
