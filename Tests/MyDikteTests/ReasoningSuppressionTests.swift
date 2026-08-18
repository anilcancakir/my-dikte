import Foundation
import Testing

@testable import MyDikte

@Suite("ReasoningSuppression")
struct ReasoningSuppressionTests {
    @Test(
        "Gemini models that support the minimal thinking level get it",
        arguments: [
            "gemini-3.6-flash",
            "gemini-3.5-flash-lite",
            "gemini-3.5-flash",
            "gemini-3.1-flash-lite",
        ]
    )
    func geminiMinimalThinkingModels(modelId: String) {
        let parameters = ReasoningSuppression.parameters(for: modelId)
        #expect(parameters == ReasoningSuppression.Parameters(reasoningEffort: "minimal"))
    }

    @Test(
        "Gemini models that do not support minimal fall back to low",
        arguments: [
            "gemini-3.7-flash",
            "gemini-3.1-pro-preview",
        ]
    )
    func geminiLowThinkingModels(modelId: String) {
        let parameters = ReasoningSuppression.parameters(for: modelId)
        #expect(parameters == ReasoningSuppression.Parameters(reasoningEffort: "low"))
    }

    @Test("Gemini 2.5 Flash-Lite needs no suppression parameter because thinking is already off")
    func geminiFlashLiteNeedsNothing() {
        #expect(ReasoningSuppression.parameters(for: "gemini-2.5-flash-lite") == nil)
    }

    @Test(
        "the GPT-5.4 through 5.6 family takes an explicit none reasoning effort",
        arguments: [
            "gpt-5.4",
            "gpt-5.5",
            "gpt-5.6",
        ]
    )
    func gpt5FamilyTakesNone(modelId: String) {
        let parameters = ReasoningSuppression.parameters(for: modelId)
        #expect(parameters == ReasoningSuppression.Parameters(reasoningEffort: "none"))
    }

    @Test("namespaced openai/gpt-oss-120b yields both low and include_reasoning false")
    func namespacedGptOss120bYieldsLowAndIncludeReasoningFalse() {
        let parameters = ReasoningSuppression.parameters(for: "openai/gpt-oss-120b")
        #expect(parameters?.reasoningEffort == "low")
        #expect(parameters?.extraBodyParameters == ["include_reasoning": false])
    }

    @Test("namespaced openai/gpt-oss-20b yields both low and include_reasoning false")
    func namespacedGptOss20bYieldsLowAndIncludeReasoningFalse() {
        let parameters = ReasoningSuppression.parameters(for: "openai/gpt-oss-20b")
        #expect(parameters?.reasoningEffort == "low")
        #expect(parameters?.extraBodyParameters == ["include_reasoning": false])
    }

    @Test("the bare, unnamespaced gpt-oss-120b is treated as unknown and yields nothing")
    func bareGptOss120bIsUnknown() {
        #expect(ReasoningSuppression.parameters(for: "gpt-oss-120b") == nil)
    }

    @Test("an unrecognised model id yields no parameters rather than a wrong guess")
    func unrecognisedModelYieldsNothing() {
        #expect(ReasoningSuppression.parameters(for: "some-vendor/some-future-model") == nil)
    }
}
