import Foundation
import os

package enum ViewerooLog {
    enum Outcome: String {
        case completed, partial, offline, cancelled, failed

        var level: OSLogType {
            switch self {
            case .failed, .partial: .error
            case .completed, .offline, .cancelled: .default
            }
        }
    }

    private static let subsystem = "net.prdb.vieweroo"
    static let catalog = Logger(subsystem: subsystem, category: "catalog")
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let matching = Logger(subsystem: subsystem, category: "prdb")
    package static let airPlay = Logger(subsystem: subsystem, category: "airplay")

    static func failureCode(_ error: Error) -> String {
        switch error {
        case PRDBError.invalidKey: "invalidKey"
        case PRDBError.subscriptionRequired: "subscriptionRequired"
        case PRDBError.rateLimited: "rateLimited"
        case PRDBError.invalidResponse: "invalidResponse"
        case let PRDBError.service(status): "http-\(status)"
        case let error as URLError: "network-\(error.code.rawValue)"
        default: "error-\((error as NSError).code)"
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let duration = start.duration(to: .now).components
        return duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
    }
}
