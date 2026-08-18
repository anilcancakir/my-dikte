import Foundation

// A measurement tool, not part of the app. It POSTs one WAV to an OpenAI-compatible
// `/audio/transcriptions` endpoint and prints what the app's own transcription client cannot
// easily show from inside the app: the network timing split, whether the connection was reused,
// the exact key set the provider returned, and the verbatim body behind a failure.
//
// It exists because four things the plan assumed needed measuring rather than asserting: the real
// latency from this network, whether Groq's `verbose_json` carries `no_speech_prob` and
// `avg_logprob` at the top level or only per segment, whether a realistic glossary fits the
// documented 224-token `prompt` cap, and what an error body actually looks like so the app's error
// parser survives one.
//
// Usage:
//   GROQ_API_KEY=... mydikte-probe <wav-path> <model-id> [--glossary <terms>]
//                                  [--endpoint <url>] [--repeat <n>]
//
// The API key comes from the environment and is never printed, logged, or echoed back, not even
// in an error message: a probe that leaks the key it was handed is worse than no probe.

// MARK: - Arguments

/// One parsed invocation.
struct Arguments {
    let wavPath: String
    let modelId: String
    let glossary: String?
    let endpoint: URL
    let repeatCount: Int

    /// Groq is the default because it is the provider the app ships pointed at. Any
    /// OpenAI-compatible transcription endpoint works through `--endpoint`, which is how two
    /// providers get compared on the same clip in the same run.
    static let defaultEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    static let usage = """
        Usage: mydikte-probe <wav-path> <model-id> [--glossary <terms>] [--endpoint <url>] [--repeat <n>]

        Reads the API key from GROQ_API_KEY. Sends response_format=verbose_json, language=tr and
        temperature=0. --repeat reuses one URLSession, which is the only way to see whether the
        second request reused the first one's connection.
        """

    static func parse(_ argv: [String]) throws -> Arguments {
        var positional: [String] = []
        var glossary: String?
        var endpoint = defaultEndpoint
        var repeatCount = 1

        var index = 0
        while index < argv.count {
            let argument = argv[index]
            switch argument {
            case "--glossary", "--endpoint", "--repeat":
                guard index + 1 < argv.count else {
                    throw ProbeError.usage("\(argument) needs a value")
                }
                let value = argv[index + 1]
                index += 2

                switch argument {
                case "--glossary":
                    glossary = value
                case "--endpoint":
                    guard let url = URL(string: value), url.scheme != nil else {
                        throw ProbeError.usage("--endpoint is not a URL: \(value)")
                    }
                    endpoint = url
                default:
                    guard let count = Int(value), count > 0 else {
                        throw ProbeError.usage("--repeat needs a positive integer, got \(value)")
                    }
                    repeatCount = count
                }
            case let unknown where unknown.hasPrefix("--"):
                throw ProbeError.usage("unknown option \(unknown)")
            default:
                positional.append(argument)
                index += 1
            }
        }

        guard positional.count == 2 else {
            throw ProbeError.usage("expected <wav-path> and <model-id>, got \(positional.count) argument(s)")
        }

        return Arguments(
            wavPath: positional[0],
            modelId: positional[1],
            glossary: glossary,
            endpoint: endpoint,
            repeatCount: repeatCount
        )
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case usage(String)
    case missingKey
    case unreadableFile(path: String, underlying: Error)

    var description: String {
        switch self {
        case .usage(let detail):
            return "\(detail)\n\n\(Arguments.usage)"
        case .missingKey:
            return "GROQ_API_KEY is not set. Export the key for the endpoint you are probing."
        case .unreadableFile(let path, let underlying):
            return "Cannot read \(path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Metrics

/// Collects `URLSessionTaskMetrics`, which arrive through a delegate callback rather than as part
/// of the response, so there is no way to get the timing split without one.
///
/// `@unchecked Sendable` with a lock: the callback lands on the session's delegate queue while the
/// awaiting task reads the value from another thread, and `URLSessionTaskMetrics` is not `Sendable`.
final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: URLSessionTaskMetrics?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        collected = metrics
        lock.unlock()
    }

    /// Takes the metrics and clears them, so a repeated run cannot read the previous request's
    /// numbers when a callback fails to arrive.
    func take() -> URLSessionTaskMetrics? {
        lock.lock()
        defer {
            collected = nil
            lock.unlock()
        }
        return collected
    }
}

/// One transaction's timing split, in milliseconds, plus whether the connection was reused.
struct TimingSplit {
    let domainLookupMs: Double?
    let connectMs: Double?
    let secureConnectionMs: Double?
    let timeToFirstByteMs: Double?
    let totalMs: Double?
    let reusedConnection: Bool
    let networkProtocol: String?

    init(_ transaction: URLSessionTaskTransactionMetrics) {
        func elapsed(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return end.timeIntervalSince(start) * 1000
        }

        domainLookupMs = elapsed(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        connectMs = elapsed(transaction.connectStartDate, transaction.connectEndDate)
        secureConnectionMs = elapsed(
            transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        timeToFirstByteMs = elapsed(transaction.requestStartDate, transaction.responseStartDate)
        totalMs = elapsed(transaction.fetchStartDate, transaction.responseEndDate)
        reusedConnection = transaction.isReusedConnection
        networkProtocol = transaction.networkProtocolName
    }

    var report: String {
        func format(_ label: String, _ value: Double?) -> String {
            guard let value else {
                // A reused connection legitimately has no DNS, connect or TLS phase, so an absent
                // number is information rather than a gap to paper over with a zero.
                return "\(label)=n/a"
            }
            return String(format: "%@=%.1fms", label, value)
        }

        return [
            format("dns", domainLookupMs),
            format("connect", connectMs),
            format("tls", secureConnectionMs),
            format("ttfb", timeToFirstByteMs),
            format("total", totalMs),
            "reused=\(reusedConnection)",
            "proto=\(networkProtocol ?? "n/a")",
        ].joined(separator: " ")
    }
}

// MARK: - Request

/// Builds the multipart body by hand. `URLSession` has no multipart encoder, and the app's own
/// client builds the same shape, so the probe measures the request the app actually sends.
func multipartBody(
    boundary: String,
    audio: Data,
    filename: String,
    modelId: String,
    glossary: String?
) -> Data {
    var body = Data()

    func appendField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    appendField("model", modelId)
    appendField("response_format", "verbose_json")
    appendField("language", "tr")
    appendField("temperature", "0")
    if let glossary, !glossary.isEmpty {
        // The provider calls this `prompt`; it is a decoding hint, not an instruction, and it is
        // where a term glossary buys accuracy on Turkish technical speech.
        appendField("prompt", glossary)
    }

    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
        "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
            .data(using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(audio)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    return body
}

// MARK: - Reporting

/// Reports what the response carried, including where the quality fields actually live.
///
/// The distinction matters to the app: a hallucination filter keyed on a top-level
/// `no_speech_prob` reads `nil` forever if the provider only emits it per segment.
func reportBody(_ data: Data, status: Int, contentType: String?) {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
        // Not JSON. This is the case the app's error parser has to survive: Groq's edge answers a
        // rejected User-Agent with an HTML error page, not a JSON error envelope.
        let preview = String(decoding: data.prefix(400), as: UTF8.self)
        print("  body: NOT JSON (content-type=\(contentType ?? "n/a"), \(data.count) bytes)")
        print("  preview: \(preview.replacingOccurrences(of: "\n", with: " "))")
        return
    }

    guard let payload = object as? [String: Any] else {
        print("  body: JSON but not an object (\(type(of: object)))")
        return
    }

    print("  top-level keys: \(payload.keys.sorted().joined(separator: ", "))")

    if status >= 400 {
        // Printed structurally rather than verbatim so a key echoed back inside an error message
        // cannot reach stdout.
        if let error = payload["error"] as? [String: Any] {
            print("  error keys: \(error.keys.sorted().joined(separator: ", "))")
            if let message = error["message"] as? String {
                print("  error.message: \(message)")
            }
            if let code = error["code"] {
                print("  error.code: \(code)")
            }
        }
        return
    }

    if let text = payload["text"] as? String {
        print("  text: \(text)")
        print("  text length: \(text.count) characters")
    } else {
        print("  text: MISSING from the response")
    }

    for field in ["no_speech_prob", "avg_logprob", "duration", "language"] {
        if let value = payload[field] {
            print("  top-level \(field): \(value)")
        } else {
            print("  top-level \(field): absent")
        }
    }

    guard let segments = payload["segments"] as? [[String: Any]] else {
        print("  segments: absent")
        return
    }

    print("  segments: \(segments.count)")
    guard let first = segments.first else { return }
    print("  segment keys: \(first.keys.sorted().joined(separator: ", "))")
    for field in ["no_speech_prob", "avg_logprob", "compression_ratio"] {
        let values = segments.compactMap { $0[field] as? Double }
        guard !values.isEmpty else {
            print("  segment \(field): absent")
            continue
        }
        let formatted = values.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        print("  segment \(field): \(formatted)")
    }
}

// MARK: - Main

func run() async throws {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))

    guard let apiKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !apiKey.isEmpty else {
        throw ProbeError.missingKey
    }

    let wavURL = URL(fileURLWithPath: arguments.wavPath)
    let audio: Data
    do {
        audio = try Data(contentsOf: wavURL)
    } catch {
        throw ProbeError.unreadableFile(path: arguments.wavPath, underlying: error)
    }

    print("endpoint: \(arguments.endpoint.absoluteString)")
    print("model: \(arguments.modelId)")
    print("clip: \(arguments.wavPath) (\(audio.count) bytes)")
    if let glossary = arguments.glossary {
        // Character count and a rough token estimate, because the documented cap on this field is
        // 224 tokens and a glossary that silently overruns it is dropped without a warning.
        print("glossary: \(glossary.count) characters, ~\(glossary.split(separator: " ").count) words")
    } else {
        print("glossary: none")
    }

    let collector = MetricsCollector()
    // One session across every repetition. A fresh session per request would show a cold
    // connection every time and hide the reuse the app gets from its own long-lived session.
    let session = URLSession(configuration: .ephemeral)

    for attempt in 1...arguments.repeatCount {
        let boundary = "mydikte-probe-\(UUID().uuidString)"
        var request = URLRequest(url: arguments.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            audio: audio,
            filename: wavURL.lastPathComponent,
            modelId: arguments.modelId,
            glossary: arguments.glossary
        )

        let wallClockStart = Date()
        let (data, response) = try await session.data(for: request, delegate: collector)
        let wallClockMs = Date().timeIntervalSince(wallClockStart) * 1000

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")

        print("")
        print("run \(attempt)/\(arguments.repeatCount): HTTP \(status), \(data.count) bytes")
        print(String(format: "  wall clock: %.1fms", wallClockMs))
        if let transaction = collector.take()?.transactionMetrics.last {
            print("  \(TimingSplit(transaction).report)")
        } else {
            print("  timing split: no metrics were collected for this request")
        }
        reportBody(data, status: status, contentType: contentType)
    }
}

do {
    try await run()
} catch let error as ProbeError {
    FileHandle.standardError.write(Data("\(error.description)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("request failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
