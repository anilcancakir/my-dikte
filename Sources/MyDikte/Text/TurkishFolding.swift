import Foundation

/// Normalises Turkish (and other) text for hallucination-phrase matching.
///
/// `String.folding(options: .diacriticInsensitive)` alone folds ş, ğ, ç, ö, ü and the dotted
/// capital İ correctly, because each carries a combining mark that decomposition can strip. It
/// leaves dotless-i (ı, U+0131) untouched, because that letter has no combining mark: it is its
/// own base scalar. An explicit map for just that one letter (plus its dotted capital, folded
/// the same way for symmetry) is therefore required before the generic fold pipeline runs.
enum TurkishFolding {
    private static let explicitMap: [Character: String] = [
        "ı": "i",
        "İ": "i",
    ]

    /// Normalises text to lowercase ASCII-range words separated by single spaces.
    static func normalise(_ text: String) -> String {
        // 1. Fold the one Turkish letter NFD decomposition cannot handle on its own.
        let mapped: String = text.map { explicitMap[$0] ?? String($0) }.joined()

        // 2. Decompose so accented letters become a base scalar plus combining marks.
        let decomposed: String = mapped.decomposedStringWithCanonicalMapping

        // 3. Strip the combining marks, leaving the base letters.
        let strippedScalars: [Unicode.Scalar] = decomposed.unicodeScalars.filter {
            !CharacterSet.nonBaseCharacters.contains($0)
        }
        let stripped = String(String.UnicodeScalarView(strippedScalars))

        // 4. Lowercase.
        let lowercased: String = stripped.lowercased()

        // 5. Keep only alphanumerics and whitespace, dropping punctuation.
        let keptScalars: [Unicode.Scalar] = lowercased.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)
        }
        let kept = String(String.UnicodeScalarView(keptScalars))

        // 6. Collapse whitespace runs to a single space and trim the ends.
        return kept
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
