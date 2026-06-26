//
//  StatusBarController.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 24/06/26.
//

import AppKit
import Combine
import SwiftUI

/// Manages a custom NSStatusItem that shows the current lyric line in the
/// menu bar and toggles the lyrics popover on click.
final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var lyricsService: LyricsService?
    private var isPopoverOpen = false
    private var cancellables = Set<AnyCancellable>()

    func configure(nowPlayingService: NowPlayingService, lyricsService: LyricsService) {
        self.lyricsService = lyricsService

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "music.note.list",
                accessibilityDescription: "Lyripeek"
            )
            button.imagePosition = .imageLeft
            button.lineBreakMode = .byTruncatingTail
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(nowPlayingService)
                .environmentObject(lyricsService)
        )

        self.statusItem = statusItem
        self.popover = popover

        lyricsService.$isLoading
            .combineLatest(lyricsService.$currentLineText)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading, lineText in
                self?.updateMenuBarTitle(isLoading: isLoading, lineText: lineText)
            }
            .store(in: &cancellables)
    }

    private func updateMenuBarTitle(isLoading: Bool, lineText: String) {
        guard let button = statusItem?.button else { return }

        if isLoading {
            button.title = "Fetching lyrics…"
            if !isPopoverOpen { statusItem?.length = NSStatusItem.variableLength }
        } else if lineText.isEmpty {
            button.title = ""
            if !isPopoverOpen { statusItem?.length = NSStatusItem.squareLength }
        } else {
            button.title = lineText
            if !isPopoverOpen { statusItem?.length = NSStatusItem.variableLength }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Freeze the status item width while the popover is open so that
            // changing menu-bar lyric text cannot shift the popover.
            isPopoverOpen = true
            statusItem?.length = button.frame.width

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Keep the popover positioned under the menu bar item while visible.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        isPopoverOpen = false
        statusItem?.length = NSStatusItem.variableLength

        if let lyricsService {
            updateMenuBarTitle(
                isLoading: lyricsService.isLoading,
                lineText: lyricsService.currentLineText
            )
        }
    }
}
