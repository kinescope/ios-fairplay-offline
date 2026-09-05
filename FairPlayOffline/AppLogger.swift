import Foundation
import OSLog

enum AppLog {
    static let api = Logger(subsystem: subsystem, category: "KinescopeAPI")
    static let drm = Logger(subsystem: subsystem, category: "FairPlay")
    static let download = Logger(subsystem: subsystem, category: "Download")
    static let player = Logger(subsystem: subsystem, category: "Player")

    private static let subsystem =
        Bundle.main.bundleIdentifier ?? "io.kinescope.example.fairplayoffline"

    static func error(
        _ error: Error,
        context: String,
        logger: Logger
    ) {
        var currentError: NSError? = error as NSError
        var depth = 0

        while let errorToLog = currentError, depth < 4 {
            let failureReason = errorToLog.localizedFailureReason ?? "none"
            logger.error(
                """
                [\(context, privacy: .public)] \
                depth=\(depth) \
                domain=\(errorToLog.domain, privacy: .public) \
                code=\(errorToLog.code) \
                description=\(errorToLog.localizedDescription, privacy: .public) \
                failureReason=\(failureReason, privacy: .public)
                """
            )
            currentError = errorToLog.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
    }

    static func endpoint(_ url: URL) -> String {
        "\(url.host ?? "unknown")\(url.path)"
    }
}
