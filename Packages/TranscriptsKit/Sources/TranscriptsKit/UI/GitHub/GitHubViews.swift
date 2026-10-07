import AppKit
import SwiftUI

// MARK: - GitHub's mark

/// GitHub's mark from its Octicons (MIT licensed), unchanged, as GitHub's logo guidelines ask for integrations.
/// Drawn as a template image, so it takes the colour of the text around it.
struct GitHubMark: View {
    var size: CGFloat = 14

    static let image: NSImage? = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M6.766 11.328c-2.063-.25-3.516-1.734-3.516-3.656 0-.781.281-1.625.75-2.188-.203-.515-.172-1.609.063-2.062.625-.078 1.468.25 1.968.703.594-.187 1.219-.281 1.985-.281.765 0 1.39.094 1.953.265.484-.437 1.344-.765 1.969-.687.218.422.25 1.515.046 2.047.5.593.766 1.39.766 2.203 0 1.922-1.453 3.375-3.547 3.64.531.344.89 1.094.89 1.954v1.625c0 .468.391.734.86.547C13.781 14.359 16 11.53 16 8.03 16 3.61 12.406 0 7.984 0 3.563 0 0 3.61 0 8.031a7.88 7.88 0 0 0 5.172 7.422c.422.156.828-.125.828-.547v-1.25c-.219.094-.5.156-.75.156-1.031 0-1.64-.562-2.078-1.609-.172-.422-.36-.672-.719-.719-.187-.015-.25-.093-.25-.187 0-.188.313-.328.625-.328.453 0 .844.281 1.25.86.313.452.64.655 1.031.655s.641-.14 1-.5c.266-.265.47-.5.657-.656"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8))
        image?.isTemplate = true
        return image
    }()

    /// The mark at a size for a toolbar or tab icon.
    static func image(size: CGFloat) -> NSImage? {
        guard let image = image?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Status

/// How a status is drawn: the circle that fills up as work progresses. Same drawing as in Issues for GitHub.
struct StatusGlyph: Equatable {
    var category: StatusCategory
    /// 0...1, how much of the circle is filled for in-progress statuses.
    var progress: Double
    var color: Color

    static let none = StatusGlyph(category: .backlog, progress: 0, color: Theme.textTertiary)

    /// Glyphs for all statuses of one project. Later "started" columns fill the circle further.
    static func map(for options: [GitHubStatusOption]) -> [String: StatusGlyph] {
        var result: [String: StatusGlyph] = [:]
        var startedIndex = 0
        for option in options {
            let category = option.category
            var progress = 0.0
            if category == .started {
                startedIndex += 1
                progress = 1 - pow(0.5, Double(startedIndex))
            }
            var color = Theme.statusColor(option)
            // Without a colour chosen on GitHub, tell consecutive in-progress columns apart.
            if category == .started, Theme.optionColor(option.color) == nil, startedIndex > 1 {
                color = Theme.positive
            }
            result[option.id] = StatusGlyph(category: category, progress: progress, color: color)
        }
        return result
    }

    /// The glyph of a status by its name on a project, for issues whose option id isn't at hand.
    static func of(name: String?, in options: [GitHubStatusOption], closed: Bool) -> StatusGlyph {
        if let option = options.first(where: { $0.name == name }), let glyph = map(for: options)[option.id] { return glyph }
        if closed { return StatusGlyph(category: .completed, progress: 1, color: Theme.accent) }
        if let name { return StatusGlyph(category: StatusCategory.infer(from: name), progress: 0.5, color: Theme.statusColor(GitHubStatusOption(id: "", name: name, color: ""))) }
        return StatusGlyph(category: .unstarted, progress: 0, color: Theme.textBody)
    }
}

enum StatusPainter {
    static func draw(_ glyph: StatusGlyph, in frame: CGRect, context: GraphicsContext) {
        let rect = frame.insetBy(dx: 1.25, dy: 1.25)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let ring = Path(ellipseIn: rect)
        let s = frame.width / 14
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: frame.minX + x * s, y: frame.minY + y * s) }
        switch glyph.category {
        case .backlog:
            context.stroke(ring, with: .color(glyph.color), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2.3]))
        case .unstarted:
            context.stroke(ring, with: .color(glyph.color), lineWidth: 1.5)
        case .started:
            context.stroke(ring, with: .color(glyph.color), lineWidth: 1.5)
            var pie = Path()
            pie.move(to: center)
            pie.addArc(
                center: center, radius: rect.width / 2 - 2.5,
                startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * glyph.progress), clockwise: false
            )
            pie.closeSubpath()
            context.fill(pie, with: .color(glyph.color))
        case .completed:
            context.fill(Path(ellipseIn: rect.insetBy(dx: -0.75, dy: -0.75)), with: .color(glyph.color))
            var check = Path()
            check.move(to: point(4.4, 7.2))
            check.addLine(to: point(6.2, 9))
            check.addLine(to: point(9.6, 5.2))
            context.stroke(check, with: .color(Theme.onColor), style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round, lineJoin: .round))
        case .canceled:
            context.fill(Path(ellipseIn: rect.insetBy(dx: -0.75, dy: -0.75)), with: .color(glyph.color))
            var cross = Path()
            cross.move(to: point(4.8, 4.8))
            cross.addLine(to: point(9.2, 9.2))
            cross.move(to: point(9.2, 4.8))
            cross.addLine(to: point(4.8, 9.2))
            context.stroke(cross, with: .color(Theme.onColor), style: StrokeStyle(lineWidth: 1.5 * s, lineCap: .round))
        }
    }
}

struct StatusIcon: View {
    var glyph: StatusGlyph
    var size: CGFloat = 14

    var body: some View {
        Canvas { context, canvasSize in
            StatusPainter.draw(glyph, in: CGRect(origin: .zero, size: canvasSize), context: context)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - People, labels, projects

/// GitHub avatars, downloaded once and kept in memory.
@MainActor
final class GitHubAvatarCache {
    static let shared = GitHubAvatarCache()
    private let images = NSCache<NSString, NSImage>()
    private var loading: [String: Task<NSImage?, Never>] = [:]

    func cached(_ url: String) -> NSImage? {
        images.object(forKey: url as NSString)
    }

    func load(_ url: String) async -> NSImage? {
        if let image = cached(url) { return image }
        if let task = loading[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let parsed = URL(string: url + (url.contains("?") ? "&" : "?") + "s=72"),
                  let (data, _) = try? await URLSession.shared.data(from: parsed) else { return nil }
            return NSImage(data: data)
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { images.setObject(image, forKey: url as NSString) }
        return image
    }
}

/// A GitHub account's picture, or its initials on a colour until it has loaded.
struct GitHubAvatar: View {
    var user: GitHubUser
    var size: CGFloat = 18

    @State private var loaded: NSImage?

    var body: some View {
        let image = loaded ?? user.avatarUrl.flatMap { GitHubAvatarCache.shared.cached($0) }
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(Circle())
            } else {
                Circle().fill(Theme.color(for: user.name ?? user.login))
                Text(Avatar.initials(user.name ?? user.login))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x111214))
            }
        }
        .frame(width: size, height: size)
        .help(user.login)
        .accessibilityLabel(user.login)
        .task(id: user.avatarUrl) {
            guard let url = user.avatarUrl, GitHubAvatarCache.shared.cached(url) == nil else { return }
            loaded = await GitHubAvatarCache.shared.load(url)
        }
    }
}

struct GitHubAvatarStack: View {
    var users: [GitHubUser]
    var size: CGFloat = 18
    var ring: Color = Theme.popover

    var body: some View {
        HStack(spacing: -5) {
            ForEach(users.prefix(3)) { user in
                GitHubAvatar(user: user, size: size)
                    .overlay(Circle().stroke(ring, lineWidth: 1.5))
            }
        }
    }
}

struct LabelChip: View {
    var label: GitHubLabel

    var body: some View {
        Chip {
            Circle().fill(Theme.labelColor(label.color)).frame(width: 7, height: 7)
            Text(label.name).foregroundStyle(Theme.textBody)
        }
    }
}

/// The coloured square that stands for a project, as in Issues for GitHub.
struct ProjectSwatch: View {
    var title: String
    var size: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var color: Color {
        let palette: [Color] = [
            Color(light: 0xE07B2A, dark: 0xF2994A), Color(light: 0x2F86B5, dark: 0x5AB0D8), Color(light: 0x2F9B67, dark: 0x4CB782),
            Color(light: 0xC45FA6, dark: 0xD98BC4), Color(light: 0x5B63D3, dark: 0x8F96F2), Color(light: 0xD29A0A, dark: 0xF0B429),
        ]
        let hash = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

/// Where a target lives: the project's square and name, then the repository.
struct TargetLabel: View {
    var target: GitHubTarget
    var font: Font = .small
    /// Project and repository on two lines, for narrow columns.
    var stacked = false

    var body: some View {
        if stacked, let project = target.projectTitle {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ProjectSwatch(title: project)
                    Text(project).lineLimit(1)
                }
                Text(target.repo).lineLimit(1).truncationMode(.middle)
            }
            .font(font)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            if let project = target.projectTitle {
                ProjectSwatch(title: project)
                Text(project).lineLimit(1)
                Text("›").foregroundStyle(Theme.textTertiary)
            } else {
                Image(systemName: "book.closed").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            Text(target.repo).lineLimit(1)
        }
        .font(font)
    }
}

/// "Öffentlich": a repository anyone can read.
struct PublicBadge: View {
    var body: some View {
        Text("Öffentlich")
            .font(.tiny)
            .foregroundStyle(Theme.noticeText)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.noticeFill))
            .help("Öffentliches Repository: jeder kann die Issues lesen")
    }
}

/// A task's issue in the list: its status and number. Opens the issue on GitHub.
struct IssuePill: View {
    @Environment(AppModel.self) private var model
    var issue: LinkedIssue

    var body: some View {
        Button {
            model.openIssue(issue)
        } label: {
            HStack(spacing: 5) {
                StatusIcon(glyph: StatusGlyph.of(name: issue.status, in: model.githubProject(issue.projectId)?.statusOptions ?? [], closed: issue.isClosed), size: 12)
                Text("#\(issue.number)").monospacedDigit()
            }
            .font(.tiny)
            .foregroundStyle(Theme.textBody)
            .padding(.leading, 5)
            .padding(.trailing, 7)
            .frame(height: 20)
            .overlay(Capsule().stroke(Theme.chipBorder, lineWidth: 1))
            .contentShape(Capsule())
            .hoverFill(radius: 10, fill: Theme.hover)
        }
        .buttonStyle(PlainPressStyle())
        .help(help)
        .accessibilityLabel(Text("Issue \(issue.number) auf GitHub öffnen", comment: "accessibility: a task's GitHub issue, by number"))
        .accessibilityIdentifier("issue.pill.\(issue.number)")
    }

    private var help: String {
        var parts = [issue.reference]
        if let status = issue.status {
            parts.append(status)
        } else if issue.isClosed {
            parts.append(String(localized: "Geschlossen", comment: "a GitHub issue's state"))
        }
        if issue.linkedExisting { parts.append(String(localized: "verknüpft", comment: "tooltip: the task was linked to an issue that already existed")) }
        return parts.joined(separator: " · ") + "\n" + String(localized: "Auf GitHub öffnen")
    }
}

/// A small part of a row, such as a status circle, that opens its picker in a dropdown on top of the composer.
struct PartButton<Label: View, Picker: View>: View {
    var help: LocalizedStringKey
    var round = false
    @Binding var isOpen: Bool
    var identifier: String
    @ViewBuilder var label: Label
    @ViewBuilder var picker: (_ close: @escaping () -> Void) -> Picker

    @State private var hovering = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            label
                .padding(3)
                .background(RoundedRectangle(cornerRadius: round ? 12 : 5, style: .continuous).fill(hovering || isOpen ? Theme.partHover : .clear))
                .contentShape(Rectangle())
                .padding(-3)
        }
        .buttonStyle(PlainPressStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityIdentifier(identifier)
        .debugFrame(identifier)
        .dropdown(isPresented: $isOpen) { close in picker(close) }
    }
}
