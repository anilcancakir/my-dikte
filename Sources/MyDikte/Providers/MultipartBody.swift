import Foundation

/// Builds an in-memory `multipart/form-data` body for a provider file-upload request.
///
/// Built in memory rather than streamed: a 30-second dictation clip is small, and both reference
/// implementations do the same, see
/// `references/pindrop/Pindrop/Services/Transcription/OpenAITranscriptionEngine.swift:221-259`.
/// Field order matters to some providers: scalar fields are appended first, then the file, then
/// `finalize()` writes the closing boundary.
struct MultipartBody {
    let boundary: String
    private var body: Data = Data()

    init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
    }

    /// The value to send in the request's `Content-Type` header.
    var contentTypeHeaderValue: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Appends one scalar form field.
    mutating func appendField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    /// Appends one file part. Trailing CRLF closes the part; the closing boundary itself is
    /// written by `finalize()`, not here, so multiple fields plus one file can be appended in
    /// any order before the body is sealed.
    mutating func appendFile(name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// Closes the body with the terminating boundary and returns it alongside the header value
    /// the caller must send with it. Call once, after every field and the file are appended.
    func finalize() -> (body: Data, contentTypeHeaderValue: String) {
        var sealed = body
        sealed.append(contentsOf: "--\(boundary)--\r\n".utf8)
        return (sealed, contentTypeHeaderValue)
    }

    private mutating func append(_ string: String) {
        body.append(contentsOf: string.utf8)
    }
}
