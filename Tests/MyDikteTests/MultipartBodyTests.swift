import Foundation
import Testing

@testable import MyDikte

@Suite("MultipartBody")
struct MultipartBodyTests {
    @Test("byte layout matches the exact multipart shape for one field plus one file")
    func byteLayoutMatchesExpectedShape() {
        var body = MultipartBody(boundary: "TESTBOUNDARY")
        body.appendField(name: "model", value: "whisper-large-v3")
        body.appendFile(
            name: "file",
            filename: "audio.m4a",
            contentType: "audio/mp4",
            data: Data("FAKE-AUDIO".utf8)
        )

        let result = body.finalize()

        // Literal expected shape, not a length check: every CRLF is spelled out here so a
        // missing one fails the test instead of silently reaching the provider.
        let expected =
            "--TESTBOUNDARY\r\n"
            + "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
            + "whisper-large-v3\r\n"
            + "--TESTBOUNDARY\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n"
            + "Content-Type: audio/mp4\r\n\r\n"
            + "FAKE-AUDIO"
            + "\r\n--TESTBOUNDARY--\r\n"

        #expect(result.body == Data(expected.utf8))
        #expect(result.contentTypeHeaderValue == "multipart/form-data; boundary=TESTBOUNDARY")
    }

    @Test("decodes a response containing only text")
    func decodesTextOnlyResponse() throws {
        let json = """
            { "text": "merhaba dunya" }
            """

        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: Data(json.utf8))

        #expect(response.text == "merhaba dunya")
        #expect(response.segments == nil)
    }

    @Test("decodes a response with text plus populated segments")
    func decodesResponseWithSegments() throws {
        let json = """
            {
                "text": "merhaba dunya",
                "segments": [
                    { "no_speech_prob": 0.01, "avg_logprob": -0.2, "compression_ratio": 1.4 }
                ]
            }
            """

        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: Data(json.utf8))

        #expect(response.text == "merhaba dunya")
        #expect(response.segments?.count == 1)
        #expect(response.segments?.first?.noSpeechProb == 0.01)
        #expect(response.segments?.first?.avgLogprob == -0.2)
        #expect(response.segments?.first?.compressionRatio == 1.4)
    }

    @Test("decoding succeeds when an unknown top-level field is present")
    func decodingIgnoresUnknownTopLevelField() throws {
        let json = """
            { "text": "merhaba", "task": "transcribe" }
            """

        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: Data(json.utf8))

        #expect(response.text == "merhaba")
    }
}
