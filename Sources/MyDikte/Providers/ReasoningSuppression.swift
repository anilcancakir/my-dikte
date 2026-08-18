import Foundation

/// Maps a fully namespaced OpenRouter model id to the extra chat-completions parameters that stop
/// the model from emitting a reasoning trace before its answer.
///
/// A reasoning model silently adds tens of seconds to first token: the same OpenAI nano tier
/// measures 0.87 s at minimal effort and 94 s at default (see
/// `.ac/plans/my-dikte-swift-macos/research/oracle-latency-architecture.md`). This table is the
/// per-model antidote, ported from
/// `references/VoiceInk/VoiceInk/Services/AIEnhancement/ReasoningConfig.swift:1-85`.
///
/// Resolution rule: the reference table keys some entries by provider and some by a bare model
/// id, and the two forms of the same model disagree (`gpt-oss-120b` on Cerebras wants
/// `reasoning_format: "hidden"`; `openai/gpt-oss-120b` on Groq wants `include_reasoning: false`).
/// This client only ever addresses models by their fully namespaced id, so the table is keyed on
/// that namespaced id only; a bare id is treated as unknown rather than guessing which provider
/// it meant.
enum ReasoningSuppression {
    /// One suppression parameter set for a model: a `reasoning_effort` or thinking-level string,
    /// plus any additional body keys the provider needs to fully silence the trace.
    struct Parameters: Equatable {
        /// The value to send as `reasoning_effort` (or, for Gemini, the thinking level string).
        let reasoningEffort: String
        /// Extra top-level body keys beyond `reasoning_effort`, such as Groq's
        /// `include_reasoning: false`.
        let extraBodyParameters: [String: Bool]

        init(reasoningEffort: String, extraBodyParameters: [String: Bool] = [:]) {
            self.reasoningEffort = reasoningEffort
            self.extraBodyParameters = extraBodyParameters
        }
    }

    /// Gemini models that support the "minimal" thinking level.
    private static let geminiMinimalThinkingModels: Set<String> = [
        "gemini-3.6-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.5-flash",
        "gemini-3.1-flash-lite",
    ]

    /// Gemini models that need "low" because "minimal" is not supported.
    private static let geminiLowThinkingModels: Set<String> = [
        "gemini-3.7-flash",
        "gemini-3.1-pro-preview",
    ]

    /// Gemini 2.5 Flash-Lite is intentionally absent: thinking is already off by default, so it
    /// needs no suppression parameter at all.
    private static let geminiNoSuppressionNeededModels: Set<String> = [
        "gemini-2.5-flash-lite"
    ]

    /// The GPT-5.4 through 5.6 family, which supports an explicit "none" reasoning effort.
    private static let openAINoneReasoningModels: Set<String> = [
        "gpt-5.4",
        "gpt-5.5",
        "gpt-5.6",
    ]

    /// Groq GPT-OSS models have no true "none"; the lowest effort plus a provider-specific flag
    /// is what actually strips the `reasoning` field from the response, confirmed against the
    /// live API in `.ac/plans/my-dikte-swift-macos/evidence/step-02-groq-seam.txt` section C.
    private static let groqGPTOSSMinimumReasoningModels: Set<String> = [
        "openai/gpt-oss-120b",
        "openai/gpt-oss-20b",
    ]

    /// The suppression parameters for `modelId`, or `nil` when the model needs none (either
    /// because it is unrecognised, or because it is known to already default to no reasoning).
    static func parameters(for modelId: String) -> Parameters? {
        if geminiMinimalThinkingModels.contains(modelId) {
            return Parameters(reasoningEffort: "minimal")
        }
        if geminiLowThinkingModels.contains(modelId) {
            return Parameters(reasoningEffort: "low")
        }
        if geminiNoSuppressionNeededModels.contains(modelId) {
            return nil
        }
        if openAINoneReasoningModels.contains(modelId) {
            return Parameters(reasoningEffort: "none")
        }
        if groqGPTOSSMinimumReasoningModels.contains(modelId) {
            return Parameters(reasoningEffort: "low", extraBodyParameters: ["include_reasoning": false])
        }
        return nil
    }
}
