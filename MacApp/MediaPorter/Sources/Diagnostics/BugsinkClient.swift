// Hand-rolled Sentry-envelope sender that talks to a self-hosted Bugsink
// instance. Picked over the official `sentry-cocoa` SDK because v1 only sends
// user-initiated diagnostic reports — no crash hooks, no breadcrumb capture,
// no auto-instrumentation. ~200 lines of Swift here vs. a multi-MB dependency
// with its own crash reporter that we'd have to argue with at notarization.
//
// If we later want automatic crash capture, swap this for `sentry-cocoa`
// and keep the same `BugsinkClient.send(...)` surface so callers don't move.
//
// Sentry envelope reference: https://develop.sentry.dev/sdk/envelopes/
// DSN format: https://<public_key>@<host>/<project_id>

import Foundation
import OSLog
#if canImport(AppKit)
import AppKit
#endif

public enum BugsinkClient {

    /// Resolved DSN, set once at app launch via `configure(dsn:)`. nil means
    /// the user hasn't pasted one yet — sends become no-ops with a clear
    /// error so the diagnostic sheet can show "Sending isn't configured".
    private static var dsn: ParsedDSN?
    private static let configureLock = NSLock()

    /// App version + build, surfaced as the Sentry `release` tag so events
    /// from different builds don't collide on the same issue page. Set by
    /// the App target from Bundle.main once at launch.
    public static var release: String = "mediaporter@unknown"

    /// "production" / "dev" / "ci" — Sentry's `environment` tag. Inferred
    /// from build context; the App target overrides with `.dev` for Xcode
    /// debug builds so we don't pollute the prod project with local tests.
    public static var environment: String = "production"

    public static func configure(dsn rawDSN: String?, release: String, environment: String = "production") {
        configureLock.lock()
        defer { configureLock.unlock() }
        Self.release = release
        Self.environment = environment
        guard let raw = rawDSN, !raw.isEmpty else {
            Self.dsn = nil
            DebugLog.notice("bugsink.configure", "no DSN — diagnostic sends will fail with .notConfigured")
            return
        }
        do {
            Self.dsn = try ParsedDSN.parse(raw)
            DebugLog.notice("bugsink.configure", "configured for project \(Self.dsn!.projectID) at \(Self.dsn!.host)")
        } catch {
            Self.dsn = nil
            DebugLog.error("bugsink.configure", "invalid DSN: \(error.localizedDescription)")
        }
    }

    public static var isConfigured: Bool {
        configureLock.lock()
        defer { configureLock.unlock() }
        return dsn != nil
    }

    // MARK: - Public send API

    public struct Attachment: Sendable {
        public let filename: String
        public let contentType: String
        public let data: Data
        public init(filename: String, contentType: String, data: Data) {
            self.filename = filename
            self.contentType = contentType
            self.data = data
        }
    }

    public enum SendError: LocalizedError {
        case notConfigured
        case http(Int, String)
        case transport(Error)
        case encoding

        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "Diagnostic sending isn't configured for this build."
            case .http(let code, let body): return "Server returned HTTP \(code). \(body.prefix(200))"
            case .transport(let e): return "Network error: \(e.localizedDescription)"
            case .encoding: return "Couldn't encode the report."
            }
        }
    }

    /// Send a user-initiated diagnostic. Returns the Sentry event ID on
    /// success — useful to show the user as a follow-up reference.
    @discardableResult
    public static func send(
        message: String,
        level: Level = .info,
        tags: [String: String] = [:],
        contexts: [String: [String: Any]] = [:],
        attachments: [Attachment] = []
    ) async throws -> String {
        configureLock.lock()
        let dsn = self.dsn
        let release = self.release
        let environment = self.environment
        configureLock.unlock()
        guard let dsn else { throw SendError.notConfigured }

        let eventID = randomHexID()
        let sentAt = ISO8601DateFormatter.utcMillis.string(from: Date())

        var event: [String: Any] = [
            "event_id": eventID,
            "timestamp": sentAt,
            "platform": "native",
            "level": level.rawValue,
            "release": release,
            "environment": environment,
            "logger": "mediaporter.diagnostic",
            "message": ["formatted": message],
            "sdk": ["name": "mediaporter.bugsink", "version": "1"],
        ]
        if !tags.isEmpty { event["tags"] = tags }
        if !contexts.isEmpty { event["contexts"] = contexts }

        let envelope: Data
        do {
            envelope = try buildEnvelope(
                eventID: eventID,
                sentAt: sentAt,
                event: event,
                attachments: attachments
            )
        } catch {
            throw SendError.encoding
        }

        var req = URLRequest(url: dsn.envelopeURL)
        req.httpMethod = "POST"
        req.setValue(dsn.authHeader, forHTTPHeaderField: "X-Sentry-Auth")
        req.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        req.setValue("mediaporter/\(release)", forHTTPHeaderField: "User-Agent")
        req.httpBody = envelope
        req.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SendError.transport(error)
        }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw SendError.http(code, body)
        }
        DebugLog.notice("bugsink.send", "OK eventID=\(eventID) bytes=\(envelope.count)")
        return eventID
    }

    public enum Level: String, Sendable {
        case fatal, error, warning, info, debug
    }

    // MARK: - Envelope assembly

    /// Sentry envelope = newline-separated JSON headers + arbitrary payloads.
    /// Concretely:
    ///   <envelope header>\n
    ///   <item header (event)>\n
    ///   <event JSON>\n
    ///   <item header (attachment)>\n
    ///   <attachment bytes>\n
    ///   ...
    private static func buildEnvelope(
        eventID: String,
        sentAt: String,
        event: [String: Any],
        attachments: [Attachment]
    ) throws -> Data {
        var out = Data()
        let envelopeHeader: [String: Any] = [
            "event_id": eventID,
            "sent_at": sentAt,
        ]
        out.append(try jsonLine(envelopeHeader))

        let eventBody = try JSONSerialization.data(
            withJSONObject: event,
            options: [.sortedKeys]
        )
        let eventItemHeader: [String: Any] = [
            "type": "event",
            "content_type": "application/json",
            "length": eventBody.count,
        ]
        out.append(try jsonLine(eventItemHeader))
        out.append(eventBody)
        out.append(0x0a)

        for a in attachments {
            let header: [String: Any] = [
                "type": "attachment",
                "filename": a.filename,
                "content_type": a.contentType,
                "length": a.data.count,
                "attachment_type": "event.attachment",
            ]
            out.append(try jsonLine(header))
            out.append(a.data)
            out.append(0x0a)
        }
        return out
    }

    private static func jsonLine(_ obj: [String: Any]) throws -> Data {
        var d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        d.append(0x0a) // newline
        return d
    }

    private static func randomHexID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - DSN parsing

private struct ParsedDSN {
    let publicKey: String
    let host: String        // host[:port]
    let scheme: String      // "http" / "https"
    let projectID: String
    let envelopeURL: URL
    let authHeader: String

    static func parse(_ raw: String) throws -> ParsedDSN {
        // Sentry DSN: https://<public_key>@<host>[:port]/<project_id>
        // (optional path prefix between host and project_id — we don't use it
        // for vanilla Bugsink installs)
        guard let url = URL(string: raw),
              let scheme = url.scheme,
              let user = url.user,
              let host = url.host else {
            throw DSNError.malformed
        }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { throw DSNError.missingProjectID }
        let projectID = path.split(separator: "/").last.map(String.init) ?? path
        let envelopeURL = URL(string: "\(scheme)://\(host)\(port)/api/\(projectID)/envelope/")!
        let authHeader = "Sentry sentry_version=7, sentry_key=\(user), sentry_client=mediaporter-bugsink/1.0"
        return ParsedDSN(
            publicKey: user,
            host: host + port,
            scheme: scheme,
            projectID: projectID,
            envelopeURL: envelopeURL,
            authHeader: authHeader
        )
    }
}

private enum DSNError: LocalizedError {
    case malformed
    case missingProjectID
    var errorDescription: String? {
        switch self {
        case .malformed: return "DSN is malformed — expected https://<key>@<host>/<project_id>"
        case .missingProjectID: return "DSN is missing the project ID"
        }
    }
}

// MARK: - Helpers

extension ISO8601DateFormatter {
    static let utcMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
