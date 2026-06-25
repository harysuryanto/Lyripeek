//
//  LRCParser.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import Foundation

struct LyricLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
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
    let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return []
    }

    var lines: [LyricLine] = []

    for rawLine in lrc.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let range = NSRange(line.startIndex..., in: line)
        let matches = regex.matches(in: line, options: [], range: range)

        guard !matches.isEmpty else { continue }

        // The lyric text begins after the last timestamp's closing bracket.
        let lastMatch = matches.last!
        let textStart = line.index(line.startIndex, offsetBy: lastMatch.range.upperBound)
        let text = String(line[textStart...]).trimmingCharacters(in: .whitespaces)

        for match in matches {
            guard let time = timeInterval(from: match, in: line) else { continue }
            lines.append(LyricLine(time: time, text: text))
        }
    }

    return lines.sorted { $0.time < $1.time }
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
