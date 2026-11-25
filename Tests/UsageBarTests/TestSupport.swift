import Foundation
import XCTest
@testable import usagebar

/// 테스트마다 새 임시 디렉터리.
func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("usagebar-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func posixMode(_ url: URL) -> Int {
    let attrs = try! FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as! NSNumber).intValue & 0o777
}

func fileLines(_ url: URL) throws -> [Substring] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
}

func snapshot(five: Double? = nil, seven: Double? = nil, at: Date = Date(),
              resolved: String? = nil) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: five.map { WindowUsage(percent: $0, resetsAt: nil) },
        sevenDay: seven.map { WindowUsage(percent: $0, resetsAt: nil) },
        fetchedAt: at, resolvedLabel: resolved)
}
