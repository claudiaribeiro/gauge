// Native menu bar app showing Claude and Codex plan usage. Read-only, no network.
//
// Data sources:
//   Claude: ~/.claude/usage-cache.json, written by statusline.sh whenever Claude Code redraws its status line.
//   Codex:  ~/.codex/sessions/**/rollout-*.jsonl — Codex logs `rate_limits` in its token_count events.
//
// Dev helper: `Gauge --snapshot out.png [light|dark]` renders the panel (and out-menubar.png)
// with sample data and exits.

import SwiftUI
import ServiceManagement
import AppKit

// MARK: - Model

struct Limit: Identifiable {
    let id: String
    let usedPercent: Double
    let resetsAt: Double         // Unix seconds
    let duration: TimeInterval   // window length

    var title: String { duration <= 86400 ? "Session" : "Weekly" }
    var subtitle: String {
        let hours = Int((duration / 3600).rounded())
        return hours < 48 ? "\(hours)-hour window" : "\(hours / 24)-day window"
    }

    /// Builds a limit from values read off disk, rejecting anything out of range (corrupt or
    /// hand-edited files) so later Double→Int conversions in the UI can never trap.
    static func validated(id: String, usedPercent: Double, resetsAt: Double, duration: Double) -> Limit? {
        guard usedPercent.isFinite, (0...10_000).contains(usedPercent),
              let resetsAt = validEpoch(resetsAt),
              duration.isFinite, (60...(366 * 86400)).contains(duration) else { return nil }
        return Limit(id: id, usedPercent: usedPercent, resetsAt: resetsAt, duration: duration)
    }
}

/// A Unix timestamp between 2000 and 2100, or nil.
func validEpoch(_ value: Double?) -> Double? {
    guard let value, value.isFinite, (946_684_800...4_102_444_800).contains(value) else { return nil }
    return value
}

struct ProviderUsage {
    var model: String?
    var plan: String?
    var limits: [Limit]
    var updatedAt: Double?
}

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var symbol: String { self == .claude ? "sparkle" : "terminal" }
    var app: String { self == .claude ? "Claude Code" : "Codex" }
    var usageURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage"
                                    : "https://chatgpt.com/codex/settings/usage")!
    }
}

// MARK: - Readers

let home = FileManager.default.homeDirectoryForCurrentUser

enum ClaudeReader {
    private struct Window: Decodable { let used_percentage: Double; let resets_at: Double }
    private struct RateLimits: Decodable { let five_hour: Window?; let seven_day: Window? }
    private struct Cache: Decodable { let rate_limits: RateLimits?; let model: String?; let updated_at: Double? }

    static func read() -> ProviderUsage? {
        let url = home.appendingPathComponent(".claude/usage-cache.json")
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return nil }
        var limits: [Limit] = []
        if let w = cache.rate_limits?.five_hour,
           let limit = Limit.validated(id: "session", usedPercent: w.used_percentage, resetsAt: w.resets_at, duration: 5 * 3600) {
            limits.append(limit)
        }
        if let w = cache.rate_limits?.seven_day,
           let limit = Limit.validated(id: "weekly", usedPercent: w.used_percentage, resetsAt: w.resets_at, duration: 7 * 86400) {
            limits.append(limit)
        }
        return ProviderUsage(model: cache.model, plan: nil, limits: limits, updatedAt: validEpoch(cache.updated_at))
    }
}

enum CodexReader {
    /// The newest rate limit event found in one session log, and when it was logged.
    private struct Snapshot { let usage: ProviderUsage; let time: Double }
    private struct FileInfo { let url: URL; let modified: Date; let size: Int }

    /// Parsed results per log file, reused until the file's size or modification date changes.
    private static var parsed: [URL: (modified: Date, size: Int, snapshot: Snapshot?)] = [:]

    static func read() -> ProviderUsage? {
        let root = home.appendingPathComponent(".codex/sessions")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [FileInfo] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append(FileInfo(url: url,
                                  modified: values.contentModificationDate ?? .distantPast,
                                  size: values.fileSize ?? 0))
        }

        // Pick the snapshot with the newest *event* timestamp across all sessions. Resuming an old
        // conversation touches its file, so modification time alone can point at stale limits.
        // A file can't hold an event newer than its own modification time, so once files are older
        // than the best event found, the search can stop.
        var best: Snapshot?
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            if let best, file.modified.timeIntervalSince1970 < best.time { break }
            let snapshot: Snapshot?
            if let cached = parsed[file.url], cached.modified == file.modified, cached.size == file.size {
                snapshot = cached.snapshot
            } else {
                snapshot = parse(file.url, modified: file.modified)
                parsed[file.url] = (file.modified, file.size, snapshot)
            }
            if let snapshot, snapshot.time > (best?.time ?? -.infinity) { best = snapshot }
        }
        return best?.usage
    }

    /// Scans a session log backwards in 1 MB chunks, newest line first, until it has found the
    /// latest rate limit event and the model in use (or reaches the start of the file).
    private static func parse(_ url: URL, modified: Date) -> Snapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var rateLimits: [String: Any]?
        var timestamp: Date?
        var model: String?

        let chunk: UInt64 = 1 << 20
        var offset = (try? handle.seekToEnd()) ?? 0
        var carry = Data()   // start of a line that continues into the chunk read before this one

        scan: while offset > 0 {
            let start = offset > chunk ? offset - chunk : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(offset - start)) else { break }
            offset = start

            var lines = (data + carry).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // Unless we're at the start of the file, the first line may be cut off: finish it next round.
            carry = start > 0 && !lines.isEmpty ? Data(lines.removeFirst()) : Data()

            for raw in lines.reversed() where !raw.isEmpty {
                let line = String(decoding: raw, as: UTF8.self)
                if rateLimits == nil, line.contains("\"rate_limits\""),
                   let obj = json(line),
                   let payload = obj["payload"] as? [String: Any],
                   let rl = payload["rate_limits"] as? [String: Any],
                   (rl["limit_id"] as? String ?? "codex") == "codex",
                   // Either window may be missing on its own; accept an event with at least one.
                   rl["primary"] is [String: Any] || rl["secondary"] is [String: Any] {
                    rateLimits = rl
                    timestamp = (obj["timestamp"] as? String).flatMap(parseISO)
                }
                if model == nil, line.contains("\"turn_context\""),
                   let payload = json(line)?["payload"] as? [String: Any] {
                    model = payload["model"] as? String
                }
                if rateLimits != nil && model != nil { break scan }
            }
        }
        guard let rl = rateLimits else { return nil }

        let time = validEpoch(timestamp?.timeIntervalSince1970) ?? modified.timeIntervalSince1970
        var limits: [Limit] = []
        for (key, id) in [("primary", "session"), ("secondary", "weekly")] {
            guard let w = rl[key] as? [String: Any],
                  let used = number(w["used_percent"]),
                  let minutes = number(w["window_minutes"]) else { continue }
            // Newer Codex logs `resets_at`; older ones only `resets_in_seconds` relative to the event.
            let reset = number(w["resets_at"]) ?? number(w["resets_in_seconds"]).map { time + $0 }
            guard let reset,
                  let limit = Limit.validated(id: id, usedPercent: used, resetsAt: reset, duration: minutes * 60)
            else { continue }
            limits.append(limit)
        }
        guard !limits.isEmpty else { return nil }
        let usage = ProviderUsage(model: model,
                                  plan: (rl["plan_type"] as? String)?.capitalized,
                                  limits: limits,
                                  updatedAt: time)
        return Snapshot(usage: usage, time: time)
    }

    private static func json(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published var usage: [Provider: ProviderUsage] = [:]
    @Published var now = Date()

    private var timer: Timer?
    private var isSample = false

    init(sample: [Provider: ProviderUsage]? = nil) {
        if let sample { usage = sample; isSample = true; return }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        now = Date()
        if isSample { return }
        usage[.claude] = ClaudeReader.read()
        usage[.codex] = CodexReader.read()
    }

    /// Percent used, treating a window whose reset time has passed as back to 0.
    func used(_ limit: Limit) -> Int {
        limit.resetsAt <= now.timeIntervalSince1970 ? 0 : Int(limit.usedPercent.rounded())
    }

    /// How far through the window we are (0...1) — where usage would sit at an even pace.
    func elapsed(_ limit: Limit) -> Double? {
        let remaining = limit.resetsAt - now.timeIntervalSince1970
        guard remaining > 0 else { return nil }
        return min(max(1 - remaining / limit.duration, 0), 1)
    }

    /// The highest usage across a provider's windows — the limit you'll hit first.
    func tightest(_ provider: Provider) -> Int? {
        usage[provider]?.limits.map(used).max()
    }

    func minutesSinceUpdate(_ provider: Provider) -> Int? {
        usage[provider]?.updatedAt.map { Int(now.timeIntervalSince1970 - $0) / 60 }
    }

    var providersWithData: [Provider] {
        Provider.allCases.filter { !(usage[$0]?.limits.isEmpty ?? true) }
    }
}

// MARK: - Formatting

func countdown(to epoch: Double, from now: Date) -> String {
    let s = Int(epoch - now.timeIntervalSince1970)
    if s <= 0 { return "now" }
    if s < 3600 { return "\(max(s / 60, 1))m" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86400)d \((s % 86400) / 3600)h"
}

func clock(_ epoch: Double, from now: Date) -> String {
    let date = Date(timeIntervalSince1970: epoch)
    if Calendar.current.isDate(date, inSameDayAs: now) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

func ago(minutes m: Int) -> String {
    if m < 1 { return "Updated just now" }
    if m < 60 { return "Updated \(m)m ago" }
    if m < 1440 { return "Updated \(m / 60)h ago" }
    return "Updated \(m / 1440)d ago"
}

// MARK: - Palette
//
// Each provider gets its own hue so the two sections are told apart at a glance ("fill" for bars and
// icons, "ink" a deeper/lighter variant readable as small text). Status colours (amber, red) only appear
// when something needs attention. Neutrals are macOS system colours, matching native menu bar panels.

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct Palette {
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }
    private func pick(_ light: UInt32, _ dark: UInt32) -> Color { Color(hex: self.dark ? dark : light) }
    private func system(_ c: NSColor) -> Color { Color(nsColor: c) }

    func fill(_ p: Provider) -> Color {
        p == .claude ? pick(0xC96442, 0xE0896A)   // clay
                     : pick(0x23918B, 0x4CC2BA)   // teal
    }
    func ink(_ p: Provider) -> Color {
        p == .claude ? pick(0xA34A2C, 0xEFA48A)
                     : pick(0x17706B, 0x74D6CF)
    }

    var text: Color { system(.labelColor) }
    var muted: Color { system(.secondaryLabelColor) }
    var faint: Color { system(.tertiaryLabelColor) }
    var track: Color { system(.quaternaryLabelColor) }   // empty part of a bar
    var marker: Color { system(.secondaryLabelColor) }   // pace tick
    var divider: Color { system(.separatorColor) }

    var warning: Color { pick(0x9A6410, 0xF0B44C) }   // amber: ≥70% used, above pace, stale data
    var critical: Color { pick(0xCC2F38, 0xFF6B6B) }  // red: ≥90% used
    var fresh: Color { pick(0x3A9A62, 0x5CC48C) }     // data is current

    /// Colour for a usage percentage as text: neutral until it needs attention.
    func status(_ pct: Int) -> Color? {
        pct >= 90 ? critical : pct >= 70 ? warning : nil
    }
    /// Bar colour: the provider's own hue until it's nearly full.
    func bar(_ pct: Int, _ p: Provider) -> Color {
        pct >= 90 ? critical : fill(p)
    }
}

/// The frosted "menu" material native menus and menu bar panels sit on.
struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Snapshots can't draw AppKit views, so they get a flat stand-in background.
var renderingSnapshot = false

// MARK: - Menu bar label

enum MenuBarMode: String, CaseIterable, Identifiable {
    case both, highest, claude, codex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: "Both"
        case .highest: "Highest"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

struct MenuBarItem {
    let symbol: String?    // provider glyph, or nil to draw a usage ring instead
    let fraction: Double
    let text: String
}

/// Draws the whole label into one template image — reliable in the menu bar, and follows its colour.
func menuBarImage(_ items: [MenuBarItem]) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let icon: CGFloat = 15, gap: CGFloat = 3, spacing: CGFloat = 9, height: CGFloat = 18

    let widths = items.map { ($0.text as NSString).size(withAttributes: attrs).width }
    let total = widths.map { icon + gap + $0 }.reduce(0, +)
        + spacing * CGFloat(max(items.count - 1, 0))

    let image = NSImage(size: NSSize(width: ceil(max(total, 1)), height: height), flipped: false) { _ in
        var x: CGFloat = 0
        for (item, width) in zip(items, widths) {
            let iconRect = NSRect(x: x, y: (height - icon) / 2, width: icon, height: icon)
            if let name = item.symbol,
               let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
                let s = glyph.size
                glyph.draw(in: NSRect(x: iconRect.midX - s.width / 2, y: iconRect.midY - s.height / 2,
                                      width: s.width, height: s.height))
            } else {
                drawRing(in: iconRect, fraction: item.fraction)
            }
            x += icon + gap
            let textHeight = (item.text as NSString).size(withAttributes: attrs).height
            (item.text as NSString).draw(at: NSPoint(x: x, y: (height - textHeight) / 2), withAttributes: attrs)
            x += width + spacing
        }
        return true
    }
    image.isTemplate = true
    return image
}

/// A small ring that fills clockwise with usage.
func drawRing(in rect: NSRect, fraction: Double) {
    let line: CGFloat = 2
    let circle = rect.insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)

    let track = NSBezierPath(ovalIn: circle)
    track.lineWidth = line
    NSColor.black.withAlphaComponent(0.3).setStroke()
    track.stroke()

    let f = min(max(fraction, 0), 1)
    guard f > 0 else { return }
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                  startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
    arc.lineWidth = line
    arc.lineCapStyle = .round
    NSColor.black.setStroke()
    arc.stroke()
}

@MainActor
func menuBarItems(store: UsageStore, mode: MenuBarMode) -> [MenuBarItem] {
    func ring(_ p: Provider) -> MenuBarItem {
        let pct = store.tightest(p)
        return MenuBarItem(symbol: nil, fraction: Double(pct ?? 0) / 100, text: pct.map { "\($0)%" } ?? "–")
    }
    let available = store.providersWithData
    switch mode {
    case .claude: return [ring(.claude)]
    case .codex: return [ring(.codex)]
    case .highest:
        let top = available.max { (store.tightest($0) ?? 0) < (store.tightest($1) ?? 0) } ?? .claude
        return [ring(top)]
    case .both:
        // With two numbers side by side, label each with its provider glyph instead of a ring.
        let shown = available.isEmpty ? [Provider.claude] : available
        if shown.count == 1 { return [ring(shown[0])] }
        return shown.map { p in
            let pct = store.tightest(p)
            return MenuBarItem(symbol: p.symbol, fraction: 0, text: pct.map { "\($0)%" } ?? "–")
        }
    }
}

// MARK: - Views

struct UsageBar: View {
    let fraction: Double
    let pace: Double?
    let tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                Capsule()
                    .fill(tint)
                    // Usage can exceed 100%; the text shows the real number, the bar stops at full.
                    .frame(width: fraction > 0 ? max(geo.size.width * min(fraction, 1), 6) : 0)
                if let pace {
                    // Where usage would be at an even pace through the window.
                    Capsule()
                        .fill(palette.marker)
                        .frame(width: 2, height: 12)
                        .offset(x: geo.size.width * pace - 1)
                }
            }
        }
        .frame(height: 6)
        .padding(.vertical, 3)
    }
}

struct LimitRow: View {
    let limit: Limit
    let provider: Provider
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pct = store.used(limit)
        let pace = store.elapsed(limit)
        let palette = Palette(scheme: scheme)

        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(limit.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
                    Text(limit.subtitle).font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Spacer()
                (Text("\(pct)").font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(palette.status(pct) ?? palette.text)
                 + Text("%").font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(palette.status(pct) ?? palette.muted))
                    .monospacedDigit()
            }

            UsageBar(fraction: Double(pct) / 100, pace: pace, tint: palette.bar(pct, provider))

            HStack(spacing: 4) {
                if limit.resetsAt > store.now.timeIntervalSince1970 {
                    Text("Resets \(clock(limit.resetsAt, from: store.now))")
                    Text("·").foregroundStyle(palette.faint)
                    Text("in \(countdown(to: limit.resetsAt, from: store.now))")
                } else {
                    Text("Reset — fresh window")
                }
                Spacer()
                if let pace, Double(pct) > pace * 100 + 10 {
                    Label("Above pace", systemImage: "arrow.up.right")
                        .foregroundStyle(palette.warning)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.muted)
            .monospacedDigit()
        }
    }
}

struct ProviderSection: View {
    let provider: Provider
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let usage = store.usage[provider]
        let palette = Palette(scheme: scheme)

        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.fill(provider))
                    .frame(width: 16)
                Text(provider.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                if let plan = usage?.plan {
                    Text(plan).font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Spacer()
                if let model = usage?.model {
                    Text(model)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.ink(provider))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(palette.fill(provider).opacity(scheme == .dark ? 0.22 : 0.16), in: Capsule())
                }
            }

            if let limits = usage?.limits, !limits.isEmpty {
                ForEach(limits) { LimitRow(limit: $0, provider: provider, store: store) }
            } else {
                Text("No data yet. Send a message in \(provider.app) and it'll show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Freshness + link to the provider's own usage page
            HStack(spacing: 5) {
                if let m = store.minutesSinceUpdate(provider) {
                    let stale = m >= 30
                    Circle().fill(stale ? palette.warning : palette.fresh).frame(width: 6, height: 6)
                    Text(stale ? "\(ago(minutes: m)) · open \(provider.app) to refresh" : ago(minutes: m))
                        .lineLimit(1)
                }
                Spacer()
                if renderingSnapshot {
                    Image(systemName: "arrow.up.forward.app")
                } else {
                    Button {
                        NSWorkspace.shared.open(provider.usageURL)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(provider.name) usage page")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.muted)
        }
    }
}

struct UsageView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("menuBarMode") private var mode: MenuBarMode = .both
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let divider = Rectangle().fill(palette.divider).frame(height: 1)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Provider.allCases.enumerated()), id: \.element) { index, provider in
                if index > 0 { divider.padding(.vertical, 14) }
                ProviderSection(provider: provider, store: store)
            }

            divider.padding(.vertical, 12)

            if renderingSnapshot { footerStandIn(palette) } else { footer(palette) }
        }
        .padding(16)
        .frame(width: 320)
        .background {
            if renderingSnapshot { Color(nsColor: .windowBackgroundColor) } else { MenuMaterial() }
        }
        .onAppear { store.reload() }
    }

    /// Snapshots can't draw AppKit controls (switch, pop-up menu), so they get look-alike shapes.
    private func footerStandIn(_ palette: Palette) -> some View {
        HStack(spacing: 10) {
            Text("Open at login")
            Capsule().fill(palette.track).frame(width: 26, height: 15)
                .overlay(alignment: .leading) { Circle().fill(.white).padding(1.5).shadow(radius: 0.5) }
            Spacer()
            Text("Menu bar")
            HStack(spacing: 4) {
                Text(mode.label).foregroundStyle(palette.text)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(palette.track, in: RoundedRectangle(cornerRadius: 4))
            Image(systemName: "power")
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.muted)
    }

    private func footer(_ palette: Palette) -> some View {
            HStack(spacing: 10) {
                Toggle("Open at login", isOn: Binding(
                    get: { opensAtLogin },
                    set: { on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        opensAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                .toggleStyle(.switch)

                Spacer()

                Picker("Menu bar", selection: $mode) {
                    ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("What the menu bar shows")

                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Quit")
            }
            .controlSize(.mini)
            .font(.system(size: 11))
            .foregroundStyle(palette.muted)
    }
}

// MARK: - App

@main
struct GaugeApp: App {
    @StateObject private var store = UsageStore()
    @AppStorage("menuBarMode") private var mode: MenuBarMode = .both

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            let dark = args.dropFirst(i + 2).first == "dark"
            DispatchQueue.main.async { Self.snapshot(to: path, dark: dark) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsageView(store: store)
        } label: {
            Image(nsImage: menuBarImage(menuBarItems(store: store, mode: mode)))
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    static func snapshot(to path: String, dark: Bool) {
        renderingSnapshot = true
        let now = Date().timeIntervalSince1970
        let store = UsageStore(sample: [
            .claude: ProviderUsage(model: "Opus 5.5", plan: nil, limits: [
                Limit(id: "session", usedPercent: 34, resetsAt: now + 100 * 60, duration: 5 * 3600),
                Limit(id: "weekly", usedPercent: 82, resetsAt: now + 2 * 86400 + 3 * 3600, duration: 7 * 86400),
            ], updatedAt: now - 120),
            .codex: ProviderUsage(model: "gpt-6-astra", plan: "Plus", limits: [
                Limit(id: "session", usedPercent: 37, resetsAt: now + 4 * 3600, duration: 5 * 3600),
                Limit(id: "weekly", usedPercent: 1, resetsAt: now + 6 * 86400, duration: 7 * 86400),
            ], updatedAt: now - 50 * 60),
        ])

        func png(_ image: NSImage?, _ out: String) {
            if let tiff = image?.tiffRepresentation,
               let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: out))
            }
        }

        let view = UsageView(store: store)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        png(renderer.nsImage, path)

        // Menu bar label in each mode, stacked, on a light strip.
        let labels = VStack(alignment: .leading, spacing: 6) {
            ForEach(MenuBarMode.allCases) { m in
                HStack {
                    Text(m.label).font(.caption).frame(width: 60, alignment: .leading)
                    Image(nsImage: menuBarImage(menuBarItems(store: store, mode: m)))
                }
            }
        }
        .padding(8)
        .background(Color.white)
        let labelRenderer = ImageRenderer(content: labels)
        labelRenderer.scale = 3
        png(labelRenderer.nsImage, path.replacingOccurrences(of: ".png", with: "-menubar.png"))
        exit(0)
    }
}
