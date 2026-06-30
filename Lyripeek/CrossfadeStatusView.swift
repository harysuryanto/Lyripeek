//
//  CrossfadeStatusView.swift
//  Lyripeek
//

import AppKit

final class CrossfadeStatusView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onContentResize: (() -> Void)?

    var icon: NSImage? {
        get { iconViewA.image }
        set {
            iconViewA.image = newValue
            iconViewB.image = newValue
        }
    }

    var text: String {
        get { activeField.stringValue }
        set {
            guard newValue != activeField.stringValue else { return }
            guard let incoming = inactiveField else { return }
            if twoLineMode, let newlineIndex = newValue.firstIndex(of: "\n") {
                let currentLine = String(newValue[..<newlineIndex])
                let nextLine = String(newValue[newlineIndex...].dropFirst())
                let font = twoLineFont
                let attrStr = NSMutableAttributedString(string: currentLine + "\n" + nextLine)
                attrStr.addAttributes([.font: font], range: NSRange(location: 0, length: attrStr.length))
                let nextStart = newValue.distance(from: newValue.startIndex, to: newlineIndex) + 1
                attrStr.addAttributes(
                    [.foregroundColor: NSColor.labelColor.withAlphaComponent(0.5)],
                    range: NSRange(location: nextStart, length: nextLine.count)
                )
                incoming.attributedStringValue = attrStr
            } else {
                incoming.stringValue = newValue
            }
            incoming.sizeToFit()
            transition(to: incoming)
        }
    }

    /// When enabled, the status view can show up to two lines of lyric text
    /// (current line on top, next line below). The caller passes a single
    /// string containing both lines joined by a newline.
    var twoLineMode: Bool = false {
        didSet {
            guard twoLineMode != oldValue else { return }
            applyTwoLineMode()
        }
    }

    private var twoLineFont: NSFont { NSFont.menuBarFont(ofSize: 9) }
    private var singleLineFont: NSFont { NSFont.menuBarFont(ofSize: 0) }

    private var animationEnabled: Bool {
        UserDefaults.standard.bool(forKey: "animateMenuBar")
    }

    private let iconSize: CGFloat = 18
    private let iconTextSpacing: CGFloat = 4
    private let horizontalPadding: CGFloat = 3
    private let iconViewA = NSImageView()
    private let iconViewB = NSImageView()
    private let textFieldA = NSTextField(labelWithString: "")
    private let textFieldB = NSTextField(labelWithString: "")

    private var activeField: NSTextField!
    private var inactiveField: NSTextField!
    private var activeIconView: NSImageView!
    private var inactiveIconView: NSImageView!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconViewA.imageScaling = .scaleProportionallyDown
        iconViewB.imageScaling = .scaleProportionallyDown
        addSubview(iconViewA)
        addSubview(iconViewB)

        for field in [textFieldA, textFieldB] {
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = false
            field.isSelectable = false
            field.font = singleLineFont
            field.alignment = .right
            field.lineBreakMode = .byClipping
            field.maximumNumberOfLines = 1
            addSubview(field)
        }

        activeField = textFieldA
        inactiveField = textFieldB
        activeIconView = iconViewA
        inactiveIconView = iconViewB
        textFieldB.isHidden = true
        textFieldB.alphaValue = 0
        iconViewB.isHidden = true
        iconViewB.alphaValue = 0
        textFieldA.alphaValue = 1
        iconViewA.alphaValue = 1

        applyTwoLineMode()
    }

    private func applyTwoLineMode() {
        let font = twoLineMode ? twoLineFont : singleLineFont
        let maxLines = twoLineMode ? 2 : 1
        for field in [textFieldA, textFieldB] {
            field.font = font
            field.maximumNumberOfLines = maxLines
        }
        textFieldA.sizeToFit()
        textFieldB.sizeToFit()
        needsLayout = true
        invalidateIntrinsicContentSize()
        onContentResize?()
    }

    override func layout() {
        super.layout()

        let barHeight = bounds.height
        let textRightX = bounds.width - horizontalPadding

        let fitSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: barHeight)
        var textSizeA = textFieldA.sizeThatFits(fitSize)
        var textSizeB = textFieldB.sizeThatFits(fitSize)
        textSizeA.height = min(textSizeA.height, barHeight)
        textSizeB.height = min(textSizeB.height, barHeight)
        let yA = max(0, (barHeight - textSizeA.height) / 2)
        let yB = max(0, (barHeight - textSizeB.height) / 2)

        textFieldA.frame = NSRect(x: textRightX - textSizeA.width, y: yA, width: textSizeA.width, height: textSizeA.height)
        textFieldB.frame = NSRect(x: textRightX - textSizeB.width, y: yB, width: textSizeB.width, height: textSizeB.height)

        let iconY = (bounds.height - iconSize) / 2
        iconViewA.frame = NSRect(
            x: textFieldA.frame.minX - iconTextSpacing - iconSize,
            y: iconY,
            width: iconSize,
            height: iconSize
        )
        iconViewB.frame = NSRect(
            x: textFieldB.frame.minX - iconTextSpacing - iconSize,
            y: iconY,
            width: iconSize,
            height: iconSize
        )
    }

    override var intrinsicContentSize: NSSize {
        let barHeight = NSStatusBar.system.thickness
        let textWidth = activeField.attributedStringValue.size().width

        if activeField.stringValue.isEmpty {
            let w = horizontalPadding * 2 + iconSize
            return NSSize(width: w, height: barHeight)
        }

        let w = horizontalPadding + iconSize + iconTextSpacing + textWidth + horizontalPadding
        return NSSize(width: w, height: barHeight)
    }

    // MARK: - Transition

    private func transition(to newField: NSTextField) {
        if animationEnabled {
            newField.alphaValue = 0
            newField.isHidden = false
            needsLayout = true
            performCrossfade(to: newField)
        } else {
            performInstantTransition(to: newField)
        }
    }

    private func performCrossfade(to newField: NSTextField) {
        let oldField = activeField!
        let oldIcon = activeIconView!
        let newIcon = inactiveIconView!

        newIcon.isHidden = false
        needsLayout = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            oldField.animator().alphaValue = 0
            newField.animator().alphaValue = 1
            oldIcon.animator().alphaValue = 0
            newIcon.animator().alphaValue = 1
        } completionHandler: {
            oldField.isHidden = true
            oldIcon.isHidden = true
            self.activeField = newField
            self.inactiveField = oldField
            self.activeIconView = newIcon
            self.inactiveIconView = oldIcon
            self.invalidateIntrinsicContentSize()
            self.onContentResize?()
        }
    }

    private func performInstantTransition(to newField: NSTextField) {
        let oldField = activeField!
        let oldIcon = activeIconView!
        let newIcon = inactiveIconView!
        oldField.isHidden = true
        oldField.alphaValue = 0
        oldIcon.isHidden = true
        oldIcon.alphaValue = 0
        newField.isHidden = false
        newField.alphaValue = 1
        newIcon.isHidden = false
        newIcon.alphaValue = 1
        activeField = newField
        inactiveField = oldField
        activeIconView = newIcon
        inactiveIconView = oldIcon
        needsLayout = true
        invalidateIntrinsicContentSize()
        onContentResize?()
    }

    // MARK: - Click

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onClick?()
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        onRightClick?(event)
    }
}
