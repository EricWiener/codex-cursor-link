// Codex Cursor Link
// Shows a tooltip when the real mouse rests on the Codex computer-use cursor overlay.
// The tooltip lists the Codex chat(s) driving computer use and opens them with codex://threads/<id>.

import AppKit
import SQLite3

// MARK: - Finding the chat that drives computer use

struct Candidate {
    let id: String
    let title: String
    let lastUse: Date
}

enum ThreadFinder {
    static let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    static let marker = Data("\"namespace\":\"mcp__cua_repl\"".utf8)
    static let timestampKey = Data("{\"timestamp\":\"".utf8)
    static let tailBytes = 16 * 1024 * 1024

    /// Chats with a computer-use call in the last 5 minutes, newest first.
    /// When none qualify, the most recent computer-use chat from the last 30 minutes.
    static func find() -> [Candidate] {
        var all: [Candidate] = []
        for row in recentThreads(withinMinutes: 30) {
            if let used = lastComputerUse(rolloutPath: row.path) {
                all.append(Candidate(id: row.id, title: row.title, lastUse: used))
            }
        }
        all.sort { $0.lastUse > $1.lastUse }
        let active = all.filter { Date().timeIntervalSince($0.lastUse) < 300 }
        if !active.isEmpty { return active }
        if let newest = all.first { return [newest] }
        // The cursor can stay parked after a run ends: fall back to the newest computer-use chat today.
        for row in recentThreads(withinMinutes: 24 * 60) {
            if let used = lastComputerUse(rolloutPath: row.path) {
                return [Candidate(id: row.id, title: row.title, lastUse: used)]
            }
        }
        return []
    }

    /// Newest state_N.sqlite, so a Codex schema bump does not break the lookup.
    static func stateDatabase() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: codexHome.path)) ?? []
        let best = files
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .max { (Int($0.dropFirst(6).dropLast(7)) ?? 0) < (Int($1.dropFirst(6).dropLast(7)) ?? 0) }
        return codexHome.appendingPathComponent(best ?? "state_5.sqlite").path
    }

    struct Row { let id: String; let path: String; let title: String }

    static func recentThreads(withinMinutes minutes: Int) -> [Row] {
        let dbPath = stateDatabase()
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        let sql = """
            select id, rollout_path,
                   coalesce(nullif(name, ''), nullif(agent_nickname, ''), nullif(preview, ''), title)
            from threads
            where archived = 0 and updated_at_ms > ?
            order by updated_at_ms desc limit 50
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let since = Int64(Date().timeIntervalSince1970 * 1000) - Int64(minutes) * 60_000
        sqlite3_bind_int64(stmt, 1, since)
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String {
                guard let c = sqlite3_column_text(stmt, i) else { return "" }
                return String(cString: c)
            }
            var title = col(2).trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.replacingOccurrences(of: "\n", with: " ")
            if title.count > 80 { title = String(title.prefix(79)) + "…" }
            if title.isEmpty { title = "Untitled chat" }
            rows.append(Row(id: col(0), path: col(1), title: title))
        }
        return rows
    }

    /// Timestamp of the last computer-use tool call in a rollout file, read from its tail.
    static func lastComputerUse(rolloutPath: String) -> Date? {
        guard let fh = FileHandle(forReadingAtPath: rolloutPath) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        fh.seek(toFileOffset: start)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        guard let hit = data.range(of: marker, options: .backwards) else { return nil }
        guard let ts = data.range(of: timestampKey, options: .backwards, in: data.startIndex..<hit.lowerBound) else { return nil }
        let begin = ts.upperBound
        let end = data.index(begin, offsetBy: min(40, data.distance(from: begin, to: data.endIndex)))
        guard let quote = data[begin..<end].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        let text = String(decoding: data[begin..<quote], as: UTF8.self)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - Finding the cursor overlay

enum Overlay {
    /// Screen rects (CoreGraphics, top-left origin) of visible Codex computer-use cursor windows.
    static func cursorRects() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var rects: [CGRect] = []
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard owner.contains("Computer Use") else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer > 0 else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            guard rect.width >= 40, rect.width <= 300, abs(rect.width - rect.height) <= 8 else { continue }
            rects.append(rect)
        }
        return rects
    }
}

// MARK: - Tooltip UI

final class RowView: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, detail: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open chat") ?? NSImage())
        arrow.contentTintColor = .controlAccentColor
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [text, arrow])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        toolTip = "Open this chat in Codex"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

final class TooltipPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(candidates: [Candidate], near anchor: CGRect, open: @escaping (String?) -> Void) {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        // A mask image (not a layer corner radius) is what clips behind-window vibrancy and the window shadow.
        effect.maskImage = TooltipPanel.roundedMask(radius: 10)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        if candidates.isEmpty {
            let row = RowView(title: "No active Codex chat found", detail: "Open Codex")
            row.onClick = { open(nil) }
            stack.addArrangedSubview(row)
        } else {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .short
            for c in candidates {
                let ago = rel.localizedString(for: c.lastUse, relativeTo: Date())
                let row = RowView(title: c.title, detail: "Codex computer use, last action \(ago)")
                row.onClick = { open(c.id) }
                stack.addArrangedSubview(row)
            }
        }
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -5),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -5),
        ])
        contentView = effect
        effect.layoutSubtreeIfNeeded()
        let size = effect.fittingSize

        // Convert the overlay rect from CoreGraphics (top-left origin) to Cocoa (bottom-left origin).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaAnchor = NSRect(x: anchor.minX, y: primaryHeight - anchor.maxY, width: anchor.width, height: anchor.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(cocoaAnchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? cocoaAnchor
        // Sit just below and right of the cursor arrow, like a system tooltip.
        // The arrow tip is at the overlay's center; flip above or left near screen edges.
        let tip = NSPoint(x: cocoaAnchor.midX, y: cocoaAnchor.midY)
        var x = tip.x - 6
        if x + size.width > visible.maxX - 8 { x = tip.x + 6 - size.width }
        var y = tip.y - 20 - size.height
        if y < visible.minY + 8 { y = tip.y + 14 }
        x = max(x, visible.minX + 8)
        y = min(y, visible.maxY - size.height - 8)
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        invalidateShadow()
        orderFrontRegardless()
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Hover loop

final class Controller: NSObject {
    let panel = TooltipPanel()
    var hoverStart: Date?
    var lastHot = Date.distantPast
    var lastMouse = NSPoint.zero
    var lastMouseMove = Date.distantPast
    var loading = false
    let hitRadius: CGFloat = 30
    let hoverDelay: TimeInterval = 0.25
    let hideGrace: TimeInterval = 0.7

    func start() {
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
    }

    func tick() {
        let now = Date()
        let mouse = NSEvent.mouseLocation
        if mouse != lastMouse { lastMouse = mouse; lastMouseMove = now }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)

        let rects = Overlay.cursorRects()
        let hit = rects.first { hypot(cg.x - $0.midX, cg.y - $0.midY) <= hitRadius }
        let overPanel = panel.isVisible && panel.frame.insetBy(dx: -12, dy: -12).contains(mouse)

        if hit != nil || overPanel { lastHot = now }

        if panel.isVisible {
            if now.timeIntervalSince(lastHot) > hideGrace { panel.orderOut(nil) }
            return
        }

        guard let rect = hit else { hoverStart = nil; return }
        // Ignore the agent cursor sliding under a mouse the user is not moving.
        if hoverStart == nil {
            guard now.timeIntervalSince(lastMouseMove) < 1.5 else { return }
            hoverStart = now
        }
        guard let started = hoverStart, now.timeIntervalSince(started) >= hoverDelay, !loading else { return }
        loading = true
        let panel = self.panel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let candidates = ThreadFinder.find()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.hoverStart = nil
                self.lastHot = Date()
                panel.show(candidates: candidates, near: rect) { id in
                    let url = id.map { "codex://threads/\($0)" } ?? "codex://"
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    panel.orderOut(nil)
                }
            }
        }
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--list") {
    for c in ThreadFinder.find() { print(c.id, c.lastUse, c.title) }
    for r in Overlay.cursorRects() { print("cursor", r) }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
