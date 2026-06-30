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
    private var nowPlayingService: NowPlayingService?
    private var artworkService: ArtworkService?
    private var updateService: UpdateService?
    private let loginItemService = LoginItemService()
    private var isPopoverOpen = false
    private var cancellables = Set<AnyCancellable>()
    private static let twoLineModeKey = "twoLineMode"
    private var twoLineMode: Bool = UserDefaults.standard.bool(forKey: StatusBarController.twoLineModeKey) {
        didSet {
            guard twoLineMode != oldValue else { return }
            statusView?.twoLineMode = twoLineMode
            updateMenuBarTitle(
                isLoading: lyricsService?.isLoading ?? false,
                lineText: lyricsService?.currentLineText ?? "",
                nextLineText: lyricsService?.nextLineText ?? ""
            )
        }
    }

    func configure(
        nowPlayingService: NowPlayingService,
        lyricsService: LyricsService,
        artworkService: ArtworkService,
        updateService: UpdateService
    ) {
        self.lyricsService = lyricsService
        self.nowPlayingService = nowPlayingService
        self.artworkService = artworkService
        self.updateService = updateService

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let statusView = CrossfadeStatusView()
        statusView.icon = NSImage(
            systemSymbolName: "music.note.list",
            accessibilityDescription: "Lyripeek"
        )
        statusView.onClick = { [weak self] in
            self?.togglePopover()
        }
        statusView.onRightClick = { [weak self] event in
            self?.showContextMenu(from: event)
        }
        statusView.onContentResize = { [weak self] in
            guard let self, !self.isPopoverOpen else { return }
            let targetWidth = self.statusView?.intrinsicContentSize.width ?? NSStatusItem.variableLength
            self.statusItem?.length = NSStatusItem.variableLength
            self.statusItem?.length = targetWidth
        }
        statusItem.view = statusView
        statusView.twoLineMode = twoLineMode
        self.statusView = statusView

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 400)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                onOpenDebug: { [weak self] in
                    self?.openDebugWindow()
                },
                onQuit: { [weak self] in
                    self?.quit()
                }
            )
                .environmentObject(nowPlayingService)
                .environmentObject(lyricsService)
                .environmentObject(artworkService)
                .environmentObject(updateService)
        )

        self.statusItem = statusItem
        self.popover = popover

        lyricsService.$isLoading
            .combineLatest(lyricsService.$currentLineText, lyricsService.$nextLineText)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading, lineText, nextLineText in
                self?.updateMenuBarTitle(isLoading: isLoading, lineText: lineText, nextLineText: nextLineText)
            }
            .store(in: &cancellables)

        // Observe runtime changes to the twoLineMode UserDefaults flag so the
        // status view re-renders immediately when the toggle is flipped.
        // Prefer the broad didChangeNotification over per-key KVO since
        // UserDefaults has no dynamic KeyPath for arbitrary bool keys.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let value = UserDefaults.standard.bool(forKey: StatusBarController.twoLineModeKey)
                if self?.twoLineMode != value { self?.twoLineMode = value }
            }
            .store(in: &cancellables)
    }

    private func updateMenuBarTitle(isLoading: Bool, lineText: String, nextLineText: String) {
        guard let statusView else { return }

        if isLoading {
            statusView.text = "Fetching lyrics…"
        } else if lineText.isEmpty {
            statusView.text = ""
        } else if twoLineMode && !nextLineText.isEmpty {
            statusView.text = "\(lineText)\n\(nextLineText)"
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
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
                // Make the popover key (so it accepts input) but don't let
                // AppKit auto-focus the first focusable view (the offset
                // TextField). The user can still click into it.
                window.makeFirstResponder(nil)
            }
        }
    }

    private func openDebugWindow() {
        guard let nowPlayingService, let lyricsService, let updateService else { return }
        DebugWindowPresenter.present(
            nowPlayingService: nowPlayingService,
            lyricsService: lyricsService,
            updateService: updateService
        )
    }

    // MARK: - Context menu (right-click)

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(menuToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Lyripeek",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }()

    private func showContextMenu(from event: NSEvent) {
        guard let statusView else { return }
        let location = statusView.convert(event.locationInWindow, from: nil)
        if let launchAtLoginItem = contextMenu.item(withTitle: "Launch at Login") {
            launchAtLoginItem.state = loginItemService.isEnabled ? .on : .off
        }
        contextMenu.popUp(positioning: nil, at: location, in: statusView)
    }

    @objc private func menuToggleLaunchAtLogin() {
        loginItemService.setEnabled(!loginItemService.isEnabled)
        if let launchAtLoginItem = contextMenu.item(withTitle: "Launch at Login") {
            launchAtLoginItem.state = loginItemService.isEnabled ? .on : .off
        }
    }

    @objc private func menuQuit() {
        quit()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        isPopoverOpen = false
        statusItem?.length = NSStatusItem.variableLength

        if let lyricsService {
            updateMenuBarTitle(
                isLoading: lyricsService.isLoading,
                lineText: lyricsService.currentLineText,
                nextLineText: lyricsService.nextLineText
            )
        }
    }
}
