// Browser Picker -- the menu under the mouse cursor.
//
// A borderless non-activating NSPanel drawn to look like a menu, not an
// NSMenu. An NSMenu only shows while its app is active, and macOS 14+ grants
// activation only cooperatively: when the default browser is launched cold by
// a click in another app, Browser Picker is never made active, and
// NSMenu.popUp blocked with nothing on screen. A
// non-activating panel can still become the key window, so it gets the
// keyboard without the app being active -- the way Spotlight-style launchers
// work -- and the app that had focus keeps it when the panel closes.
//
// Keys: Up/Down (or Ctrl-P/N), Return/Enter/Space take the highlighted item,
// 1-9 take that item, a letter jumps to the next item starting with it,
// Escape cancels. A click outside the panel, or switching apps, cancels too.

import AppKit

@MainActor
enum Picker {
    /// Set by main.swift from the config before choose() runs, since the
    /// contract's signature carries no config: "cursor" or "center".
    static var position = "cursor"

    /// Shows the menu at the cursor; returns nil when cancelled.
    static func choose(for url: URL, targets: [Target], preselect: Target?) -> Target? {
        guard !targets.isEmpty else { return nil }

        // Private entries after the profiles, behind a separator; the order
        // within each group is Discovery's (the config's include order).
        let regular = targets.filter { $0.kind != .privateWindow }
        let privates = targets.filter { $0.kind == .privateWindow }
        let host = hostOf(url)
        var rows: [MenuView.Row] = [.header(host.isEmpty ? url.absoluteString : host), .separator]
        for target in regular { rows.append(.item(target)) }
        if !regular.isEmpty && !privates.isEmpty { rows.append(.separator) }
        for target in privates { rows.append(.item(target)) }

        let view = MenuView(rows: rows)
        view.highlighted = rows.firstIndex { if case .item(let t) = $0 { t == preselect } else { false } }
            ?? rows.firstIndex { if case .item = $0 { true } else { false } }

        let panel = PickerPanel(view: view)
        panel.setFrameOrigin(origin(for: panel, view: view))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)

        // Clicks in other apps never reach us as events; a global monitor
        // sees them without any permission (mouse only, no keys).
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            MainActor.assumeIsolated { view.finish(nil) }
        }
        // queue: nil runs it right away on the posting (main) thread; .main
        // would wait behind whatever main-queue block called choose().
        let resign = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: nil) { _ in
            MainActor.assumeIsolated { view.finish(nil) }
        }

        // A modal loop of our own: runModal(for:) would activate the app.
        while !view.done {
            guard let event = NSApp.nextEvent(matching: .any, until: .distantFuture,
                                              inMode: .default, dequeue: true) else { continue }
            NSApp.sendEvent(event)
        }

        if let monitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(resign)
        panel.orderOut(nil)
        return view.chosen
    }

    /// The highlighted row under the cursor, so Return takes it where the
    /// mouse already is; kept on the screen the cursor is on.
    static func origin(for panel: NSPanel, view: MenuView) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let size = panel.frame.size
        let rowMid = view.highlighted.map { view.rowRect($0).midY } ?? size.height - MenuView.padding
        var anchor = mouse
        if position == "center", let screen { anchor = NSPoint(x: screen.frame.midX, y: screen.frame.midY) }
        // View coordinates are flipped: row y counts down from the top.
        var origin = NSPoint(x: anchor.x - (position == "center" ? size.width / 2 : 28),
                             y: anchor.y - size.height + rowMid)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return origin
    }

    static func icon(for app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

/// Becomes key without activating the app (see the top of the file).
private final class PickerPanel: NSPanel {
    init(view: MenuView) {
        super.init(contentRect: NSRect(origin: .zero, size: view.frame.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // The menu material, with a menu's rounded corners.
        let effect = NSVisualEffectView(frame: view.frame)
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.addSubview(view)
        contentView = effect
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws the rows the way NSMenu does and handles keys and the mouse.
@MainActor
final class MenuView: NSView {
    enum Row {
        case header(String)
        case separator
        case item(Target)
    }

    static let padding: CGFloat = 5
    static let rowHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 11
    static let font = NSFont.menuFont(ofSize: 0)

    let rows: [Row]
    private let icons: [Int: NSImage]
    private let keys: [Int: String]
    private var tops: [CGFloat] = []
    var highlighted: Int? { didSet { needsDisplay = true } }
    private(set) var done = false
    private(set) var chosen: Target?
    private var mouseDownInside = false

    init(rows: [Row]) {
        self.rows = rows
        var icons: [Int: NSImage] = [:], keys: [Int: String] = [:]
        var number = 0
        for (i, row) in rows.enumerated() {
            guard case .item(let t) = row else { continue }
            icons[i] = Picker.icon(for: t.appURL)
            number += 1
            if number <= 9 { keys[i] = String(number) }
        }
        self.icons = icons
        self.keys = keys

        var y = Self.padding
        var widest: CGFloat = 0
        for row in rows {
            tops.append(y)
            switch row {
            case .separator: y += Self.separatorHeight
            case .header(let s): y += Self.rowHeight; widest = max(widest, Self.width(of: s))
            case .item(let t): y += Self.rowHeight; widest = max(widest, Self.width(of: t.title))
            }
        }
        // icon column + title + key column, like NSMenu's own layout.
        let width = min(max(widest + 20 + 24 + 44, 220), 520)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: y + Self.padding))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                              .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    static func width(of s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func rowRect(_ i: Int) -> NSRect {
        let h = { if case .separator = rows[i] { Self.separatorHeight } else { Self.rowHeight } }()
        return NSRect(x: 0, y: tops[i], width: bounds.width, height: h)
    }

    func finish(_ target: Target?) {
        guard !done else { return }
        chosen = target
        done = true
        // Wake the modal loop, which may be waiting in nextEvent.
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    private func target(at i: Int?) -> Target? {
        guard let i, case .item(let t) = rows[i] else { return nil }
        return t
    }

    private var items: [Int] {
        rows.indices.filter { if case .item = rows[$0] { true } else { false } }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        for i in rows.indices {
            let r = rowRect(i)
            switch rows[i] {
            case .separator:
                NSColor.separatorColor.setFill()
                NSRect(x: 10, y: r.midY - 0.5, width: r.width - 20, height: 1).fill()
            case .header(let s):
                draw(s, in: r, x: 14, color: .secondaryLabelColor)
            case .item(let t):
                let on = i == highlighted
                if on {
                    NSColor.selectedContentBackgroundColor.setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
                }
                let text: NSColor = on ? .selectedMenuItemTextColor : .labelColor
                icons[i]?.draw(in: NSRect(x: 14, y: r.midY - 8, width: 16, height: 16),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                draw(t.title, in: r, x: 38, color: text)
                if let k = keys[i] {
                    draw(k, in: r, x: r.width - 14 - Self.width(of: k),
                         color: on ? .selectedMenuItemTextColor : .tertiaryLabelColor)
                }
            }
        }
    }

    private func draw(_ s: String, in r: NSRect, x: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let h = (s as NSString).size(withAttributes: attrs).height
        let maxWidth = r.width - x - 34
        let text = NSRect(x: x, y: r.midY - h / 2, width: max(maxWidth, 10), height: h)
        (s as NSString).draw(with: text, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: attrs)
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        let ctrl = event.modifierFlags.contains(.control)
        switch event.keyCode {
        case 53: finish(nil)                                   // Escape
        case 36, 76, 49: finish(target(at: highlighted))       // Return, Enter, Space
        case 126: move(-1)                                     // Up
        case 125: move(1)                                      // Down
        case 115: highlighted = items.first                    // Home
        case 119: highlighted = items.last                     // End
        default:
            if ctrl && chars == "p" { move(-1); return }
            if ctrl && chars == "n" { move(1); return }
            if let n = Int(chars), let i = keys.first(where: { $0.value == String(n) })?.key {
                finish(target(at: i))
            } else if let c = chars.lowercased().first, c.isLetter {
                jump(to: c)
            } else {
                NSSound.beep()
            }
        }
    }

    private func move(_ step: Int) {
        let list = items
        guard !list.isEmpty else { return }
        guard let cur = highlighted, let pos = list.firstIndex(of: cur) else {
            highlighted = step > 0 ? list.first : list.last
            return
        }
        // Wraps around, as NSMenu does.
        highlighted = list[(pos + step + list.count) % list.count]
    }

    /// Type select: the next item whose title starts with the letter.
    private func jump(to c: Character) {
        let list = items
        let start = highlighted.flatMap { list.firstIndex(of: $0) } ?? -1
        for k in 1...list.count {
            let i = list[(start + k + list.count) % list.count]
            if target(at: i)?.title.lowercased().first == c { highlighted = i; return }
        }
    }

    // MARK: mouse

    private func row(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return rows.indices.first { rowRect($0).contains(p) && target(at: $0) != nil }
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = row(at: event) { highlighted = i }
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseDown(with event: NSEvent) {
        mouseDownInside = true
        mouseMoved(with: event)
    }

    // Menus take an item on release; a release whose press happened before
    // the panel opened (the click on the link) must not pick anything.
    override func mouseUp(with event: NSEvent) {
        guard mouseDownInside, let i = row(at: event) else { return }
        finish(target(at: i))
    }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
}
