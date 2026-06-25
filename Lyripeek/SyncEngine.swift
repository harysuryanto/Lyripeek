//
//  SyncEngine.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import Foundation

/// Returns the index of the lyric line that should be highlighted for
/// `currentTime`, using a binary search over the sorted `lines` array.
///
/// Rules:
///   - Empty array          → returns 0
///   - Before first line    → returns 0
///   - After last line      → returns last index
///   - Otherwise            → largest index where `lines[i].time <= currentTime`
func currentLineIndex(lines: [LyricLine], currentTime: TimeInterval) -> Int {
    guard !lines.isEmpty else { return 0 }

    var low = 0
    var high = lines.count - 1

    while low <= high {
        let mid = (low + high) / 2
        if lines[mid].time <= currentTime {
            low = mid + 1
        } else {
            high = mid - 1
        }
    }

    // `high` is the largest index with `time <= currentTime`.
    return max(0, min(high, lines.count - 1))
}
