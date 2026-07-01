//
//  LRCParser.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import Foundation

/// Compiled once at process start. `NSRegularExpression` is thread-safe for
/// matching and immutable, so a single shared instance is safe to reuse
/// across all `parseLRC` calls.
private let lrcTimestampRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#,
    options: []
)

struct LyricWord: Identifiable, Codable {
    let id = UUID()
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct LyricLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
    let words: [LyricWord]
}

/// Parses an LRC formatted string into a sorted array of `LyricLine`.
///
/// Supported timestamp formats:
///   - [mm:ss.xx]
///   - [mm:ss]
///
/// Multiple timestamps on a single line are expanded into multiple lyric lines.
/// Invalid lines are ignored. The returned array is sorted by time ascending.
func parseLRC(_ lrc: String) -> [LyricLine] {
    guard let regex = lrcTimestampRegex else { return [] }

    var lines: [LyricLine] = []

    for rawLine in lrc.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let range = NSRange(line.startIndex..., in: line)
        let matches = regex.matches(in: line, options: [], range: range)

        guard !matches.isEmpty else { continue }

        // The lyric text begins after the last timestamp's closing bracket.
        let lastMatch = matches.last!
        let textStart = line.index(line.startIndex, offsetBy: lastMatch.range.upperBound)
        let rawText = String(line[textStart...]).trimmingCharacters(in: .whitespaces)

        for match in matches {
            guard let time = timeInterval(from: match, in: line) else { continue }
            let (cleanText, words) = parseEnhancedLRCText(rawText, lineStartTime: time)
            lines.append(LyricLine(time: time, text: cleanText, words: words))
        }
    }

    return lines.sorted { $0.time < $1.time }
}

private func parseEnhancedLRCText(_ rawText: String, lineStartTime: TimeInterval) -> (cleanText: String, words: [LyricWord]) {
    let wordRegex = try? NSRegularExpression(pattern: #"<(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?>"#, options: [])
    guard let regex = wordRegex else { return (rawText, []) }
    
    let nsString = rawText as NSString
    let matches = regex.matches(in: rawText, options: [], range: NSRange(location: 0, length: nsString.length))
    guard !matches.isEmpty else { return (rawText, []) }
    
    var words: [LyricWord] = []
    var cleanTextParts: [String] = []
    
    // Handle text before the first match (if any)
    if matches[0].range.location > 0 {
        let rawWord = nsString.substring(with: NSRange(location: 0, length: matches[0].range.location))
        let cleanWord = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanWord.isEmpty, let nextTime = timeInterval(from: matches[0], in: rawText) {
            words.append(LyricWord(text: cleanWord, startTime: lineStartTime, endTime: nextTime))
            cleanTextParts.append(cleanWord)
        }
    }
    
    for i in 0..<matches.count {
        let currentMatch = matches[i]
        guard let startTime = timeInterval(from: currentMatch, in: rawText) else { continue }
        
        let wordStart = currentMatch.range.upperBound
        let wordEnd = i + 1 < matches.count ? matches[i + 1].range.lowerBound : nsString.length
        
        let rawWord = nsString.substring(with: NSRange(location: wordStart, length: wordEnd - wordStart))
        let cleanWord = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWord.isEmpty else { continue }
        
        let endTime: TimeInterval
        if i + 1 < matches.count, let nextTime = timeInterval(from: matches[i + 1], in: rawText) {
            endTime = nextTime
        } else {
            endTime = startTime + 1.0
        }
        
        words.append(LyricWord(text: cleanWord, startTime: startTime, endTime: endTime))
        cleanTextParts.append(cleanWord)
    }
    
    let cleanText = cleanTextParts.joined(separator: " ")
    return (cleanText, words)
}

private func timeInterval(from match: NSTextCheckingResult, in line: String) -> TimeInterval? {
    guard match.numberOfRanges >= 3 else { return nil }

    let minuteString = substring(for: match.range(at: 1), in: line)
    let secondString = substring(for: match.range(at: 2), in: line)
    let fractionString = match.numberOfRanges > 3 ? substring(for: match.range(at: 3), in: line) : ""

    guard let minutes = Double(minuteString),
          let seconds = Double(secondString) else {
        return nil
    }

    var fraction: Double = 0
    if !fractionString.isEmpty {
        // Normalize fraction to milliseconds: "1" => 100, "10" => 100, "100" => 100.
        let padded = fractionString.padding(toLength: 3, withPad: "0", startingAt: 0)
        fraction = Double(padded) ?? 0
        fraction /= 1000.0
    }

    return minutes * 60.0 + seconds + fraction
}

private func substring(for range: NSRange, in string: String) -> String {
    guard let swiftRange = Range(range, in: string) else { return "" }
    return String(string[swiftRange])
}
