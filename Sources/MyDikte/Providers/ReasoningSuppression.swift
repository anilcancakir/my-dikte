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
        ///
        /// Optional, because at least one provider needs the body flag **without** an effort
        /// value: sending both to Groq's GPT-OSS empties the response entirely. See
        /// `groqGPTOSSHiddenReasoningModels`.
        let reasoningEffort: String?
        /// Extra top-level body keys beyond `reasoning_effort`, such as Groq's
        /// `include_reasoning: false`.
        let extraBodyParameters: [String: Bool]

        init(reasoningEffort: String?, extraBodyParameters: [String: Bool] = [:]) {
            self.reasoningEffort = reasoningEffort
            self.extraBodyParameters = extraBodyParameters
        }
    }

    /// Gemini models that support the "minimal" thinking level.
    ///
    /// **Namespaced, and they were not before.** These were bare ids while this type's own resolution
    /// rule is that a bare id is treated as unknown, so every Gemini entry was dead: the app addresses
    /// models the way its provider names them, and OpenRouter names this one
    /// `google/gemini-3.5-flash-lite`. Nothing failed loudly, the suppression simply never went out.
    /// Measured against OpenRouter once the ids matched: `reasoning_effort: minimal` is accepted and
    /// the same cleanup came back in 759 ms rather than 929 ms.
    private static let geminiMinimalThinkingModels: Set<String> = [
        "google/gemini-3.6-flash",
        "google/gemini-3.5-flash-lite",
        "google/gemini-3.5-flash",
        "google/gemini-3.1-flash-lite",
    ]

    /// Gemini models that need "low" because "minimal" is not supported.
    private static let geminiLowThinkingModels: Set<String> = [
        "google/gemini-3.7-flash",
        "google/gemini-3.1-pro-preview",
    ]

    /// Gemini 2.5 Flash-Lite is intentionally absent from the two sets above: thinking is already off
    /// by default, so it needs no suppression parameter at all.
    private static let geminiNoSuppressionNeededModels: Set<String> = [
        "google/gemini-2.5-flash-lite"
    ]

    /// The GPT-5.4 through 5.6 family, which supports an explicit "none" reasoning effort.
    private static let openAINoneReasoningModels: Set<String> = [
        "gpt-5.4",
        "gpt-5.5",
        "gpt-5.6",
    ]

    /// Groq GPT-OSS models take `include_reasoning: false` **and nothing else**.
    ///
    /// The reference prescribes the lowest effort plus that flag together, and this table did too
    /// until the pair was measured against the live API on `openai/gpt-oss-120b`:
    ///
    ///     reasoning_effort=low + include_reasoning=false -> content    0 chars, reasoning    0
    ///     reasoning_effort=low alone                     -> content   55 chars, reasoning  582
    ///     include_reasoning=false alone                  -> content  144 chars, reasoning    0
    ///     neither                                        -> content  135 chars, reasoning 2726
    ///
    /// So the pair does not merely hide the trace, it silences the answer: `finish_reason` comes
    /// back `stop` with an empty `content` and no error, which is the worst possible failure shape.
    /// It was caught because Mode 2 produced nothing at all in the running app. The flag alone is
    /// strictly the best row in that table: the most content of any variant, and no trace.
    private static let groqGPTOSSHiddenReasoningModels: Set<String> = [
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
        if groqGPTOSSHiddenReasoningModels.contains(modelId) {
            return Parameters(reasoningEffort: nil, extraBodyParameters: ["include_reasoning": false])
        }
        return nil
    }
}
