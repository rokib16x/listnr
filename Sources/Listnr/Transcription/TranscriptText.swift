import Foundation

/// Cleanup and non-speech detection for Whisper output.
///
/// Deliberately free of any WhisperKit dependency so it can be exercised
/// directly, and so the rules live in one readable place.
///
/// The guiding principle here is that **text alone cannot tell you whether
/// Whisper heard something.** "Okay" is both the single most common silence
/// hallucination and a completely ordinary thing to say in a meeting. Deciding
/// from the string means choosing which of the two to break. So the confidence
/// signals Whisper reports per segment do that job (see
/// `WhisperKitTranscriber`), and what remains here is limited to output that is
/// not speech in any language: bracketed stage directions, decoder tokens, and
/// training-data bleed from captioned video.
enum TranscriptText {
    /// Non-speech annotations Whisper emits, matched against the *contents* of a
    /// bracket, paren, or asterisk pair. Matching the content rather than the
    /// delimiter is what lets real speech keep its punctuation: "(v2)" and
    /// "*really*" survive, "(laughs)" and "[MUSIC]" do not.
    private static let annotationKeywords: Set<String> = [
        "music", "applause", "applauds", "silence", "blank audio", "blank_audio",
        "inaudible", "unintelligible", "indistinct", "crosstalk", "cross talk",
        "laugh", "laughs", "laughter", "laughing", "chuckles", "sighs", "sigh",
        "coughs", "cough", "clears throat", "throat clearing", "noise",
        "background noise", "static", "beep", "beeping", "ringing", "footsteps",
        "no audio", "no speech", "speaking foreign language", "foreign",
        "sound effect", "instrumental", "singing", "humming", "breathing",
    ]

    /// Phrases that are captioned-video artifacts rather than meeting speech.
    /// A person on a call does not say these; Whisper says them when it has
    /// nothing to transcribe. Matched only as the entire output.
    private static let captionArtifacts: Set<String> = [
        "thanks for watching",
        "thank you for watching",
        "thanks for watching!",
        "please subscribe",
        "subscribe to my channel",
        "like and subscribe",
        "don't forget to subscribe",
        "see you in the next video",
        "see you next time",
        "subtitles by the amara.org community",
        "transcription by castingwords",
        "www.mooji.org",
    ]

    private enum Delimiter {
        case brackets, parens, asterisks

        var pattern: String {
            switch self {
            case .brackets: return #"\[([^\]]*)\]"#
            case .parens: return #"\(([^)]*)\)"#
            case .asterisks: return #"\*([^*]*)\*"#
            }
        }
    }

    /// Strip decoder tokens and non-speech annotations, then normalise spacing.
    static func clean(_ text: String) -> String {
        // Decoder tokens like <|startoftranscript|> are never speech.
        var out = text.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: " ",
            options: .regularExpression
        )

        for delimiter in [Delimiter.brackets, .parens, .asterisks] {
            out = replaceMatches(in: out, pattern: delimiter.pattern) { inner in
                isAnnotation(inner, in: delimiter) ? " " : nil
            }
        }

        // Whisper sometimes tacks digits onto a trailing word: "Thank you.000".
        // The lookbehind requires a *letter* before the period, so genuine
        // decimals are untouched: "19.99" and "version 3.14" keep their digits.
        out = out.replacingOccurrences(
            of: #"(?<=\p{L})\.\d{2,}\s*$"#,
            with: "",
            options: .regularExpression
        )

        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the text carries no speech content at all.
    ///
    /// Note what is *not* here: "okay", "thanks", "bye", "you", "uh", and a
    /// minimum length. Those were all rejected previously, and each one threw
    /// away real speech. The length rule was the worst of them, because it
    /// counted `Character`s: Chinese 好的 ("okay") and Japanese はい ("yes") are
    /// two characters, so the most common replies in two of the languages
    /// `/lang` advertises were discarded before they could ever be printed.
    static func isNonSpeech(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        // Nothing but punctuation or symbols. Letters here includes ideographs
        // and Indic scripts, and digits are allowed so a bare "42" survives.
        let hasContent = trimmed.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        if !hasContent { return true }

        let normalised = trimmed
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,…\"' "))

        if captionArtifacts.contains(normalised) { return true }
        // A whole segment that is only a stage direction, brackets already gone.
        if annotationKeywords.contains(normalised) { return true }
        if isRepetitionLoop(trimmed) { return true }

        return false
    }

    /// True when the text is a decoder loop rather than speech.
    ///
    /// The non-Latin confidence gates are deliberately permissive (see
    /// `DecodeTuning`), because the English ones were rejecting correct Bangla
    /// and Hindi outright. This is the counterweight for what that lets through.
    ///
    /// It reads the *shape* of the output rather than matching a keyword list, so
    /// it works the same in every language, including the ones nobody has written
    /// a keyword list for. The two thresholds are set where emphasis stops and
    /// degeneracy starts: three repeats of a word is a person insisting, four is
    /// the decoder stuck. Two occurrences of a phrase is a callback, three is a
    /// loop.
    static func isRepetitionLoop(_ text: String) -> Bool {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalisedToken(String($0)) }
            .filter { !$0.isEmpty }

        if hasDegenerateRun(words, sameTokenLimit: 4, gramRepeatLimit: 3) { return true }

        // Han, Kana, and Hangul are not word-spaced, so the whole utterance
        // arrives as one or two tokens and the pass above cannot see the loop.
        // Character granularity is the only view that can, and the limits go up
        // to match: characters repeat far more readily than words do.
        if words.count <= 2 {
            let characters = text
                .filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
                .map(String.init)
            if characters.count >= 8,
               hasDegenerateRun(characters, sameTokenLimit: 6, gramRepeatLimit: 4) {
                return true
            }
        }

        return false
    }

    // MARK: - Repetition helpers

    /// Lowercase and shed surrounding punctuation, so "YES!" and "yes," are the
    /// same token for repetition purposes.
    private static func normalisedToken(_ token: String) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    /// True when `tokens` contains either one token repeated `sameTokenLimit`
    /// times in a row, or an n-gram (n of 2...4) repeated `gramRepeatLimit` times
    /// back to back. Only *consecutive* repetition counts: a word recurring
    /// throughout a sentence is normal speech, a word recurring immediately is
    /// not.
    private static func hasDegenerateRun(
        _ tokens: [String],
        sameTokenLimit: Int,
        gramRepeatLimit: Int
    ) -> Bool {
        guard tokens.count >= 2 else { return false }

        var run = 1
        for index in 1..<tokens.count {
            if tokens[index] == tokens[index - 1] {
                run += 1
                if run >= sameTokenLimit { return true }
            } else {
                run = 1
            }
        }

        for gramLength in 2...4 {
            let span = gramLength * gramRepeatLimit
            guard tokens.count >= span else { continue }
            for start in 0...(tokens.count - span) {
                let gram = Array(tokens[start ..< start + gramLength])
                var repeats = 1
                var cursor = start + gramLength
                while cursor + gramLength <= tokens.count,
                      Array(tokens[cursor ..< cursor + gramLength]) == gram {
                    repeats += 1
                    if repeats >= gramRepeatLimit { return true }
                    cursor += gramLength
                }
            }
        }

        return false
    }

    // MARK: - Helpers

    private static func isAnnotation(_ inner: String, in delimiter: Delimiter) -> Bool {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let lowered = trimmed.lowercased()
        if annotationKeywords.contains(lowered) { return true }
        if annotationKeywords.contains(where: { lowered.contains($0) }) { return true }

        // Whisper writes its markers in caps: [MUSIC], [BLANK_AUDIO], [SILENCE].
        // Only inside square brackets, where real speech essentially never goes.
        // Parenthesised acronyms in real speech, like "(API)", must survive.
        if delimiter == .brackets,
           trimmed.count <= 24,
           trimmed == trimmed.uppercased(),
           trimmed.rangeOfCharacter(from: .letters) != nil {
            return true
        }

        return false
    }

    /// Rewrite regex matches whose captured content `transform` opts into.
    /// Returning nil from `transform` leaves that match untouched.
    private static func replaceMatches(
        in text: String,
        pattern: String,
        transform: (String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        var result = text
        // Reverse order keeps the ranges of earlier matches valid as we edit.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let inner = source.substring(with: match.range(at: 1))
            guard let replacement = transform(inner) else { continue }
            result = (result as NSString).replacingCharacters(in: match.range(at: 0), with: replacement)
        }
        return result
    }
}
