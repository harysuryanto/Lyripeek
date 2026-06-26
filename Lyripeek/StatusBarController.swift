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
    private var statusView: CrossfadeStatusView?
    private var popover: NSPopover?
    private var lyricsService: LyricsService?
    private var isPopoverOpen = false
    private var cancellables = Set<AnyCancellable>()

    func configure(nowPlayingService: NowPlayingService, lyricsService: LyricsService) {
        self.lyricsService = lyricsService

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let statusView = CrossfadeStatusView()
        statusView.icon = NSImage(
            systemSymbolName: "music.note.list",
            accessibilityDescription: "Lyripeek"
        )
        statusView.onClick = { [weak self] in
            self?.togglePopover()
        }
        statusView.onContentResize = { [weak self] in
            guard let self, !self.isPopoverOpen else { return }
            let targetWidth = self.statusView?.intrinsicContentSize.width ?? NSStatusItem.variableLength
            self.statusItem?.length = NSStatusItem.variableLength
            self.statusItem?.length = targetWidth
        }
        statusItem.view = statusView
        self.statusView = statusView

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
        guard let statusView else { return }

        if isLoading {
            statusView.text = "Fetching lyrics…"
        } else if lineText.isEmpty {
            statusView.text = ""
        } else {
            statusView.text = lineText
        }
    }

    private func togglePopover() {
        guard let statusView, let popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            isPopoverOpen = true
            statusItem?.length = statusView.frame.width

            popover.show(relativeTo: statusView.bounds, of: statusView, preferredEdge: .minY)
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
