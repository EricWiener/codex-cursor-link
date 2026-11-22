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
    /// Bundle ids of the apps this chat controlled, most recent first.
    let apps: [String]
}

enum ThreadFinder {
    static let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    static let callMarker = Data("\"namespace\":\"mcp__cua_repl\"".utf8)
    static let appMarker = Data("\"codex/toolSurface\":{\"app\":{\"appId\":\"".utf8)
    static let timestampKey = Data("{\"timestamp\":\"".utf8)
    static let tailBytes = 16 * 1024 * 1024

    /// Chats for the cursor sitting on `app` (a bundle id), newest first.
    /// Chats active in the last 30 minutes whose latest computer-use app is `app` win. Otherwise every
    /// chat with a computer-use call in the last 5 minutes, then the newest one today.
    static func find(app: String?) -> [Candidate] {
        var all: [Candidate] = []
        for row in recentThreads(withinMinutes: 24 * 60) {
            if let c = computerUse(row: row) { all.append(c) }
        }
        all.sort { $0.lastUse > $1.lastUse }
        if let app {
            let current = all.filter { $0.apps.first == app && Date().timeIntervalSince($0.lastUse) < 1800 }
            if !current.isEmpty { return current }
        }
        let active = all.filter { Date().timeIntervalSince($0.lastUse) < 300 }
        if !active.isEmpty { return active }
        return Array(all.prefix(1))
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

    /// The last computer-use call in a chat's log and the apps it controlled, read from the log's tail.
    static func computerUse(row: Row) -> Candidate? {
        guard let fh = FileHandle(forReadingAtPath: row.path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        fh.seek(toFileOffset: start)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        guard let hit = data.range(of: callMarker, options: .backwards) else { return nil }
        guard let ts = data.range(of: timestampKey, options: .backwards, in: data.startIndex..<hit.lowerBound),
              let text = quoted(data, from: ts.upperBound, max: 40) else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return nil }

        var apps: [String] = []
        var upper = data.endIndex
        while apps.count < 5, let r = data.range(of: appMarker, options: .backwards, in: data.startIndex..<upper) {
            if let app = quoted(data, from: r.upperBound, max: 200), !apps.contains(app) { apps.append(app) }
            upper = r.lowerBound
        }
        return Candidate(id: row.id, title: row.title, lastUse: date, apps: apps)
    }

    /// Text from `begin` up to the next double quote.
    static func quoted(_ data: Data, from begin: Data.Index, max: Int) -> String? {
        let end = data.index(begin, offsetBy: min(max, data.distance(from: begin, to: data.endIndex)))
        guard let quote = data[begin..<end].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: data[begin..<quote], as: UTF8.self)
    }
}

// MARK: - Finding the cursor overlay

struct CursorHit {
    /// Cursor window rect (CoreGraphics, top-left origin).
    let rect: CGRect
    /// Bundle id of the app window the cursor sits on, which is the app the agent is controlling.
    let app: String?
}

enum Overlay {
    static let serviceBundle = "com.openai.sky.CUAService"

    /// The Codex cursor under `point` (CoreGraphics coordinates), if it is visible there.
    /// Codex draws a floating cursor above everything, and a background cursor at normal window
    /// level just above the window it controls, which other windows can cover.
    static func cursor(at point: CGPoint, radius: CGFloat) -> CursorHit? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return cursor(at: point, radius: radius, in: list)
    }

    /// `list` is front-to-back, as CGWindowListCopyWindowInfo returns it.
    static func cursor(at point: CGPoint, radius: CGFloat, in list: [[String: Any]]) -> CursorHit? {
        let me = getpid()
        var coveredAt = false   // a normal window above has covered `point`

        for (i, w) in list.enumerated() {
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if pid == me { continue }
            guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            let isService = (w[kCGWindowOwnerName as String] as? String ?? "").contains("Computer Use")
                || bundleID(w) == serviceBundle

            if isService && alpha >= 0.05 && isCursorShaped(rect) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                guard hypot(point.x - center.x, point.y - center.y) <= radius else { continue }
                if layer <= 0 && coveredAt { continue }
                return CursorHit(rect: rect, app: appBelow(center, in: list, after: i))
            }
            // Only real windows at normal level can hide a background cursor.
            if layer == 0 && alpha >= 0.05 && !isService && rect.width > 40 && rect.height > 40 && rect.contains(point) {
                coveredAt = true
            }
        }
        return nil
    }

    static func bundleID(_ w: [String: Any]) -> String? {
        if let fake = w["testBundle"] as? String { return fake }
        let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    static func isCursorShaped(_ rect: CGRect) -> Bool {
        rect.width >= 40 && rect.width <= 300 && abs(rect.width - rect.height) <= 8
    }

    /// Bundle id of the first normal app window under `point`, below index `after` in the window list.
    static func appBelow(_ point: CGPoint, in list: [[String: Any]], after: Int) -> String? {
        for w in list[(after + 1)...] {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b),
                  rect.width > 40, rect.height > 40, rect.contains(point) else { continue }
            guard let bundle = bundleID(w), bundle != serviceBundle else { continue }
            return bundle
        }
        return nil
    }

    /// All visible cursor windows, for --list.
    static func allCursors() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowOwnerName as String] as? String ?? "").contains("Computer Use"),
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), isCursorShaped(rect) else { return nil }
            return rect
        }
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
    var shownRect: CGRect?
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

        let hit = Overlay.cursor(at: cg, radius: hitRadius)
        let overPanel = panel.isVisible && panel.frame.insetBy(dx: -12, dy: -12).contains(mouse)

        // Moving onto a different cursor while a tooltip is open replaces it.
        if panel.isVisible, let hit, let shown = shownRect,
           hypot(hit.rect.midX - shown.midX, hit.rect.midY - shown.midY) > 80 {
            panel.orderOut(nil)
        }

        if hit != nil || overPanel { lastHot = now }

        if panel.isVisible {
            if now.timeIntervalSince(lastHot) > hideGrace { panel.orderOut(nil) }
            return
        }

        guard let hit else { hoverStart = nil; return }
        // Ignore the agent cursor sliding under a mouse the user is not moving.
        if hoverStart == nil {
            guard now.timeIntervalSince(lastMouseMove) < 1.5 else { return }
            hoverStart = now
        }
        guard let started = hoverStart, now.timeIntervalSince(started) >= hoverDelay, !loading else { return }
        loading = true
        let panel = self.panel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let candidates = ThreadFinder.find(app: hit.app)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.hoverStart = nil
                self.lastHot = Date()
                self.shownRect = hit.rect
                panel.show(candidates: candidates, near: hit.rect) { id in
                    let url = id.map { "codex://threads/\($0)" } ?? "codex://"
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    panel.orderOut(nil)
                }
            }
        }
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--self-test") {
    func win(_ owner: String, _ bundle: String, _ r: CGRect, layer: Int = 0) -> [String: Any] {
        [kCGWindowOwnerName as String: owner, "testBundle": bundle, kCGWindowOwnerPID as String: Int32(1),
         kCGWindowLayer as String: layer, kCGWindowAlpha as String: 1.0,
         kCGWindowBounds as String: r.dictionaryRepresentation]
    }
    let cursorRect = CGRect(x: 300, y: 300, width: 126, height: 126)
    let center = CGPoint(x: 363, y: 363)
    let svc = "ChatGPT Computer Use", sb = Overlay.serviceBundle
    let midi = win("Audio MIDI Setup", "com.apple.audio.AudioMIDISetup", CGRect(x: 200, y: 200, width: 800, height: 700))
    let chrome = win("Google Chrome", "com.google.Chrome", CGRect(x: 0, y: 0, width: 1200, height: 800))
    var failed = 0
    func check(_ name: String, _ got: CursorHit?, app: String?, hit: Bool) {
        let ok = (got != nil) == hit && (!hit || got?.app == app)
        if !ok { failed += 1 }
        print(ok ? "PASS" : "FAIL", name, got.map { "hit app=\($0.app ?? "nil")" } ?? "no hit")
    }
    check("floating cursor over Chrome",
          Overlay.cursor(at: center, radius: 30, in: [win(svc, sb, cursorRect, layer: 102), chrome]), app: "com.google.Chrome", hit: true)
    check("background cursor on top of its app",
          Overlay.cursor(at: center, radius: 30, in: [win(svc, sb, cursorRect), midi, chrome]), app: "com.apple.audio.AudioMIDISetup", hit: true)
    check("background cursor hidden behind Chrome",
          Overlay.cursor(at: center, radius: 30, in: [chrome, win(svc, sb, cursorRect), midi]), app: nil, hit: false)
    check("mouse 50pt away from cursor",
          Overlay.cursor(at: CGPoint(x: 413, y: 363), radius: 30, in: [win(svc, sb, cursorRect), midi]), app: nil, hit: false)
    check("two cursors, picks the one under the mouse",
          Overlay.cursor(at: CGPoint(x: 763, y: 363), radius: 30,
                         in: [win(svc, sb, cursorRect, layer: 102), win(svc, sb, cursorRect.offsetBy(dx: 400, dy: 0)), midi, chrome]),
          app: "com.apple.audio.AudioMIDISetup", hit: true)
    exit(failed == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--list") {
    for r in Overlay.allCursors() {
        let center = CGPoint(x: r.midX, y: r.midY)
        let hit = Overlay.cursor(at: center, radius: 1)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let index = list.firstIndex { w in
            (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } == r
        } ?? 0
        let app = Overlay.appBelow(center, in: list, after: index)
        print("cursor", r, "on", app ?? "-", hit == nil ? "(covered by another window)" : "(visible)")
        for c in ThreadFinder.find(app: app) { print("   ", c.id, c.lastUse, c.title, c.apps) }
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
