import AppKit
import SwiftUI
import Quartz
import UniformTypeIdentifiers

// MARK: - 抽屉 UI 组件
// 从 ContentView.swift 机械拆分（零行为变化）：独立的子视图与复用组件。
// ContentView 保留根视图、头部、条目行、收起边条、拖放代理。

struct HoverCircleButton: View {
    let systemImage: String
    var tip: String = ""
    var size: CGFloat = 22
    var tint: Color = .secondary
    /// 悬停时的图标色（默认升到 primary）
    var activeTint: Color? = nil
    /// 悬停时的底色（默认中性灰圆底）
    var activeFill: Color? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(iconColor)
                .scaleEffect(hovered ? 1.1 : 1)
                .frame(width: size, height: size)
                .background(Circle().fill(fillColor))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) { hovered = hovering }
            // set() 无栈状态切换：视图在悬停中消失也不会卡住光标
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .help(tip)
        // 图标按钮必须有 VoiceOver 标签，否则读作「按钮」而无语义
        .accessibilityLabel(tip)
    }

    private var iconColor: Color {
        hovered ? (activeTint ?? .primary) : tint
    }

    private var fillColor: Color {
        hovered ? (activeFill ?? Color.primary.opacity(0.09)) : Color.clear
    }
}

/// 按压缩放反馈
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

// MARK: - 条目行


struct SearchBarView: View {
    @ObservedObject var interaction: InteractionModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focused.wrappedValue ? DrawerTheme.accent : .secondary)
                .scaleEffect(focused.wrappedValue ? 1.08 : 1)

            ZStack(alignment: .leading) {
                if interaction.searchText.isEmpty {
                    Text(L10n.t("搜索名称或 kind:图片"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $interaction.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .accessibilityLabel(L10n.t("搜索名称或 kind:图片"))
            }

            if !interaction.searchText.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { interaction.searchText = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(PressScaleStyle(scale: 0.8))
                .transition(.scale.combined(with: .opacity))
            }

            HoverCircleButton(systemImage: "xmark", tip: L10n.t("关闭搜索"), size: 18) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    interaction.clearSearchAndHideIfNeeded()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(focused.wrappedValue ? 0.07 : 0.05))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            focused.wrappedValue ? DrawerTheme.accent.opacity(0.55) : Color.primary.opacity(0.07),
                            lineWidth: 1
                        )
                )
        )
        // 聚焦时品牌色外发光，视线自然落到输入区
        .shadow(
            color: focused.wrappedValue ? DrawerTheme.accent.opacity(0.28) : .clear,
            radius: 6
        )
        .animation(.easeOut(duration: 0.18), value: focused.wrappedValue)
        .focused(focused)
        .animation(.easeOut(duration: 0.15), value: interaction.searchText.isEmpty)
    }
}

// MARK: - 无结果

struct NoResultsView: View {
    let query: String
    let clearAction: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(DrawerTheme.accent.opacity(0.55))
                .symbolEffect(.bounce, options: .nonRepeating, value: query)
            Text(L10n.tf("没有匹配「%@」的条目", query))
                .font(.system(size: 12, weight: .medium))

            Button(action: clearAction) {
                Text(L10n.t("清除搜索"))
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(DrawerTheme.accent.opacity(0.13)))
                    .foregroundStyle(DrawerTheme.accent)
            }
            .buttonStyle(PressScaleStyle(scale: 0.93))
            .help(L10n.t("清除搜索"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(DrawerMotion.smooth) { appeared = true }
        }
    }
}

// MARK: - 撤销 toast：移除 / 清空后短暂出现，可一键还原

struct UndoToastView: View {
    let summary: String
    let onUndo: () -> Void
    let onDismiss: () -> Void
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "trash")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text(summary)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)

            Button(action: onUndo) {
                Text(L10n.t("还原"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(DrawerTheme.accentGradient))
            }
            .buttonStyle(PressScaleStyle(scale: 0.92))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressScaleStyle(scale: 0.82))
            .help(L10n.t("关闭"))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .onAppear {
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                guard !Task.isCancelled else { return }
                onDismiss()
            }
        }
        .onDisappear { autoDismissTask?.cancel() }
    }
}

// MARK: - 轻提示 toast（重复跳过 / 拷贝反馈等），自动消失

struct NoticeToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DrawerTheme.accent)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

// MARK: - QuickLook 预览弹层

struct PreviewOverlayView: View {
    let item: ShelfItem
    let store: ShelfStore
    let interaction: InteractionModel

    var body: some View {
        ZStack {
            // 遮罩：毛玻璃把身后的列表推远，点击空白处关闭
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(Color.primary.opacity(0.05)))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { interaction.closePreview() }

            GeometryReader { geo in
                card(height: min(384, max(240, geo.size.height - 24)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.92).combined(with: .opacity),
                removal: .scale(scale: 0.95).combined(with: .opacity)
            )
        )
    }

    /// 卡片高度上限 384pt；小屏 / 低占屏比例时随抽屉可用高度收缩（下限 240）
    private func card(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.primary.opacity(0.08))
            QLPreviewRepresentable(url: item.url)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            footerHints
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.32), radius: 28, y: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
        )
        .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack(spacing: 7) {
            FileTile(item: item, store: store, size: 20)

            Text(item.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            HoverCircleButton(systemImage: "xmark", tip: "关闭预览（Esc）", size: 19) {
                interaction.closePreview()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private var footerHints: some View {
        HStack(spacing: 9) {
            hintChip(key: "Space", label: L10n.t("关闭"))
            hintChip(key: "↑ ↓", label: L10n.t("切换"))
            hintChip(key: "⏎", label: L10n.t("打开"))
            Spacer(minLength: 0)
            Text(item.metaLine)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private func hintChip(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

/// 原生 QuickLook 视图：视频可直接播放、PDF 可翻页、图片支持缩放
struct QLPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView
        if let created = QLPreviewView(frame: .zero, style: .normal) {
            view = created
        } else {
            view = QLPreviewView()
        }
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
            view.autostarts = true // 图片/文档直接展示；视频/音频开始预览即播放
        }
    }
}

// MARK: - 文件瓷片：有真实预览（图片/视频/PDF）时展示预览，否则用类型化瓷片
// （同系渐变底 + 品牌色符号 + 扩展名角标，逐格式适配见 FileIconStyle.swift）

struct FileTile: View {
    let item: ShelfItem
    let store: ShelfStore
    var size: CGFloat
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    /// 符号/角标用对比度保障色（深色模式自动提亮）
    private var effectiveSymbolColor: Color {
        item.kind.style.symbolColor(dark: colorScheme == .dark)
    }

    var body: some View {
        let radius = size * 0.27

        Group {
            if settings.showThumbnails, let thumb = store.thumbs[item.id] {
                thumbnailTile(thumb, radius: radius)
            } else {
                glyphTile(radius: radius)
            }
        }
        .frame(width: size, height: size)
    }

    private func thumbnailTile(_ image: NSImage, radius: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()

            if item.kind.variant == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.19, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.09)
                    .background(
                        Circle()
                            .fill(.black.opacity(0.55))
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    )
                    .padding(size * 0.08)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func glyphTile(radius: CGFloat) -> some View {
        let style = item.kind.style
        // 小尺寸（预览弹层头部 20pt）放不下角标，只在行内 38pt 瓷片上显示
        let badge = size >= 30 ? style.badge : nil
        let iconSize = size * (badge == nil ? 0.42 : 0.34)

        return ZStack {
            // 同系渐变底：左上亮右下暗；透明度让明暗模式共用一套色值
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: style.color.opacity(0.30), location: 0),
                            .init(color: style.color.opacity(0.13), location: 1),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            // 顶部微光，加一点玻璃质感
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.20), location: 0),
                            .init(color: Color.white.opacity(0), location: 0.55),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            VStack(spacing: size * 0.05) {
                Image(systemName: style.symbolName)
                    .font(.system(size: iconSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(effectiveSymbolColor)

                if let badge {
                    Text(badge)
                        .font(.system(size: max(6, size * 0.17), weight: .semibold, design: .monospaced))
                        .foregroundStyle(effectiveSymbolColor)
                        .padding(.horizontal, size * 0.055)
                        .padding(.vertical, size * 0.018)
                        .background(Capsule().fill(style.color.opacity(0.13)))
                        .overlay(Capsule().strokeBorder(effectiveSymbolColor.opacity(0.25), lineWidth: 0.5))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(style.color.opacity(0.22), lineWidth: 0.7)
        )
    }
}

// MARK: - 空态

struct EmptyStateView: View {
    var isTargeted: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: isTargeted)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 轻微呼吸浮动（3 秒一个周期）
            let drift = isTargeted ? 0 : sin(t / 3 * 2 * .pi) * 3
            // 虚线环缓慢旋转；拖入时加速并反向，像"迎向"文件
            let angle = isTargeted ? -t * 90 : t * 9

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(isTargeted
                              ? AnyShapeStyle(DrawerTheme.accent.opacity(0.08))
                              : AnyShapeStyle(Color.primary.opacity(0.05)))

                    Circle()
                        .strokeBorder(
                            isTargeted ? DrawerTheme.accent.opacity(0.75) : Color.primary.opacity(0.14),
                            style: StrokeStyle(lineWidth: isTargeted ? 1.8 : 1.2, lineCap: .round, dash: [3, 6])
                        )
                        .rotationEffect(.degrees(angle))

                    Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(isTargeted ? DrawerTheme.accent : Color.secondary.opacity(0.75))
                        .accessibilityHidden(true) // 装饰性；语义由文字承担
                }
                .frame(width: 62, height: 62)
                .scaleEffect(isTargeted ? 1.1 : 1)
                .offset(y: drift)

                VStack(spacing: 5) {
                    Text(isTargeted ? L10n.t("松开，放进抽屉") : L10n.t("把文件放进来"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isTargeted ? DrawerTheme.accent : Color.primary.opacity(0.85))

                    Text(isTargeted
                         ? L10n.t("支持一次拖入多个文件")
                         : L10n.t("从访达拖入文件、文件夹或链接\n也可以直接拖入一段文本 · ⌘V 粘贴"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3.5)
                }
            }
            .padding(.horizontal, 24)
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isTargeted)
        }
        .padding(.bottom, 28)
    }
}
