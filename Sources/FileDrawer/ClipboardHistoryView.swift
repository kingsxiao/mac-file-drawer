import AppKit
import SwiftUI

// MARK: - 剪贴板历史面板：抽屉内的第二视图（头部按钮 / ⌘⇧V / 菜单栏进入）
//
// 列表视觉与条目行同一套语言（瓷片 + 标题 + 元信息 + 悬停操作）。
// 主操作 = 点击「收进抽屉」（调研里用户要的「一键把复制的文字 / 图片导入」）；
// 悬停与右键提供 拷贝 / 置顶 / 排除来源应用 / 删除；顶部内联搜索 + 清空。

struct ClipboardHistoryView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var history: ClipboardHistoryStore
    @ObservedObject private var settings = AppSettings.shared
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var clearConfirmVisible = false
    /// 图像条目的解码缓存（视图私有；图像 Data → NSImage 只解一次）
    @State private var imageCache: [UUID: NSImage] = [:]

    private var displayed: [ClipboardEntry] {
        history.displayedEntries(matching: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            historyHeader
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)
                .opacity(history.entries.isEmpty ? 0 : 1)

            if !settings.clipboardHistoryEnabled {
                disabledBanner
            } else if displayed.isEmpty {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            } else {
                entryList(displayed)
            }
        }
        // 轻提示（收进抽屉反馈等）由 ContentView 的全局 toast 浮层统一展示
    }

    // MARK: 头部：返回 + 标题 + 计数 + 搜索 + 清空

    private var historyHeader: some View {
        HStack(spacing: 7) {
            HoverCircleButton(
                systemImage: "chevron.left",
                tip: L10n.t("返回抽屉（Esc）"),
                size: 25
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    InteractionModel.shared.showClipboardHistory = false
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("剪贴板历史"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(footnote)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            searchField

            if !history.entries.isEmpty {
                HoverCircleButton(
                    systemImage: "trash",
                    tip: L10n.t("清空历史（保留置顶）"),
                    size: 25,
                    tint: DrawerTheme.danger.opacity(0.9),
                    activeTint: DrawerTheme.danger
                ) {
                    clearConfirmVisible = true
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .alert(L10n.t("清空剪贴板历史？"), isPresented: $clearConfirmVisible) {
            Button(L10n.t("清空"), role: .destructive) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    history.clear()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(L10n.t("置顶条目会保留；正在监控的剪贴板不受影响。"))
        }
    }

    /// 注脚：置顶 n / 共 m，或空历史的占位
    private var footnote: String {
        let pinned = history.entries.filter(\.pinned).count
        if pinned > 0 {
            return L10n.tf("%d/%d", pinned, history.entries.count)
        }
        return "\(history.entries.count)"
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(L10n.t("搜索历史"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($searchFocused)
                .lineLimit(1)
            if !searchText.isEmpty {
                HoverCircleButton(systemImage: "xmark.circle.fill", tip: L10n.t("清除搜索"), size: 16) {
                    searchText = ""
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8)
        )
        .frame(width: 118)
    }

    // MARK: 列表

    private func entryList(_ entries: [ClipboardEntry]) -> some View {
        ScrollView {
            LazyVStack(spacing: settings.compactRows ? 5 : 7) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    ClipboardHistoryRow(
                        entry: entry,
                        tileSize: settings.compactRows ? 32 : 42,
                        compact: settings.compactRows,
                        image: imageCache[entry.id],
                        onDecodeImage: { image in imageCache[entry.id] = image }
                    ) {
                        adopt(entry)
                    } onCopy: {
                        history.copyBack(entry)
                    } onTogglePin: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            history.togglePin(id: entry.id)
                        }
                    } onDelete: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            history.removeEntry(id: entry.id)
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .scale(scale: 0.94))
                    ))
                    .id(entry.id)
                }
            }
            .padding(.top, 7)
            // toast 悬浮期间列表底部让位（与条目列表同一惯例，最后一行不被轻提示盖住）
            .padding(.bottom, store.notice != nil || store.undoSnapshot != nil ? 64 : 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: 空态 / 关闭横幅

    private var disabledBanner: some View {
        VStack(spacing: 10) {
            Image(systemName: "clipboard")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary.opacity(0.75))
            Text(L10n.t("剪贴板历史已关闭"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
            Button(L10n.t("在设置中开启")) {
                SettingsWindowManager.shared.show()
            }
            .controlSize(.small)
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                Circle()
                    .strokeBorder(
                        Color.primary.opacity(0.14),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 6])
                    )
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .accessibilityHidden(true)
            }
            .frame(width: 62, height: 62)

            VStack(spacing: 5) {
                Text(searchText.isEmpty ? L10n.t("还没有记录") : L10n.t("没有匹配的历史"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                Text(searchText.isEmpty
                     ? L10n.t("在任意应用里复制文字、链接、图像或文件\n就会出现在这里，点击收进抽屉")
                     : L10n.t("换个关键词试试"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3.5)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    // MARK: 操作

    /// 收进抽屉（当前分组）：按载荷物化 / 入列，给可见反馈
    private func adopt(_ entry: ClipboardEntry) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            let result = history.adopt(entry, into: store)
            if result.added > 0 {
                store.postNotice(L10n.tf("已收进「%@」", ClipboardCapture.title(of: entry.payload)))
            } else if result.skippedDuplicates > 0 {
                store.postNotice(L10n.t("抽屉里已有该条目"))
            } else {
                store.postNotice(L10n.t("内容已失效，未能收进抽屉"))
            }
        }
    }
}

// MARK: - 历史条目行

private struct ClipboardHistoryRow: View {
    let entry: ClipboardEntry
    var tileSize: CGFloat
    var compact: Bool
    /// 父视图解码好的图像（image 载荷）
    let image: NSImage?
    /// 图像条目首次出现时回调父级缓存解码结果
    let onDecodeImage: (NSImage?) -> Void

    let onAdopt: () -> Void
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    /// 文件瓷片共用的空缩略图缓存：历史行不产生真实缩略图（类型瓷片足够）
    private static let emptyThumbs = ThumbCache()

    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var radius: CGFloat { compact ? 11 : 13 }

    /// 文件载荷是否全部失效（磁盘上已不存在）
    private var filesAllMissing: Bool {
        if case .files(let paths) = entry.payload {
            return !paths.contains { FileManager.default.fileExists(atPath: $0) }
        }
        return false
    }

    var body: some View {
        HStack(spacing: compact ? 9 : 12) {
            tile
                .overlay(alignment: .topLeading) {
                    if entry.pinned {
                        let k = tileSize / 42
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5 * k, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3.5 * k)
                            .background(Circle().fill(DrawerTheme.accentGradient))
                            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.6))
                            .offset(x: -3.5 * k, y: -3.5 * k)
                            .help(L10n.t("已置顶 · 免于容量淘汰"))
                    }
                }

            VStack(alignment: .leading, spacing: compact ? 2 : 3.5) {
                Text(ClipboardCapture.title(of: entry.payload))
                    .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(filesAllMissing ? AnyShapeStyle(DrawerTheme.danger.opacity(0.85)) : AnyShapeStyle(.primary))
                Text(metaLine)
                    .font(.system(size: compact ? 10 : 11.5))
                    .foregroundStyle(filesAllMissing ? AnyShapeStyle(DrawerTheme.danger.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                HoverCircleButton(
                    systemImage: "tray.and.arrow.down",
                    tip: L10n.t("收进抽屉"),
                    size: 21
                ) { onAdopt() }
                HoverCircleButton(
                    systemImage: "doc.on.doc",
                    tip: L10n.t("拷贝"),
                    size: 21
                ) { onCopy() }
                HoverCircleButton(
                    systemImage: "xmark",
                    tip: L10n.t("删除"),
                    size: 21,
                    tint: DrawerTheme.danger.opacity(0.9),
                    activeTint: DrawerTheme.danger
                ) { onDelete() }
            }
            .opacity(hovered ? 1 : 0)
            .accessibilityHidden(!hovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 6 : 10.5)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(colorScheme == .dark ? 0.13 : 0.32), location: 0),
                            .init(color: Color.white.opacity(0.03), location: 0.55),
                            .init(color: Color.white.opacity(0), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        )
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { hovered = hovering }
        }
        .onTapGesture { onAdopt() }
        .contextMenu { rowContextMenu }
        .onAppear(perform: decodeImageIfNeeded)
        .help(L10n.t("点击收进抽屉 · 右键查看更多操作"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        // onTapGesture 不产生 AXPress：显式注册默认激活动作，辅助技术可触发「收进抽屉」
        .accessibilityAction { onAdopt() }
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button(L10n.t("收进抽屉")) { onAdopt() }
        Button(L10n.t("拷贝")) { onCopy() }
        Button(entry.pinned ? L10n.t("取消置顶") : L10n.t("置顶")) { onTogglePin() }
        if let bundleID = entry.sourceBundleID, let appName = entry.sourceAppName {
            Button(L10n.tf("不再记录来自「%@」的复制", appName)) {
                var excluded = AppSettings.shared.clipboardExcludedApps
                if !excluded.contains(bundleID) {
                    excluded.append(bundleID)
                    AppSettings.shared.clipboardExcludedApps = excluded
                }
            }
        }
        Divider()
        Button(L10n.t("删除"), role: .destructive) { onDelete() }
    }

    private var accessibilityDescription: String {
        var parts = [ClipboardCapture.title(of: entry.payload)]
        if entry.pinned { parts.append(L10n.t("已置顶")) }
        if filesAllMissing { parts.append(L10n.t("文件已不存在")) }
        parts.append(metaLine)
        return parts.joined(separator: "，")
    }

    /// 元信息行：相对时间 · 来源应用 ·（文件）数量或失效提示
    private var metaLine: String {
        var parts = [ShelfItem.relativeAdded(entry.capturedAt)]
        if let app = entry.sourceAppName { parts.append(app) }
        switch entry.payload {
        case .files(let paths):
            if paths.count > 1 { parts.append(L10n.tf("%d 个文件", paths.count)) }
            if filesAllMissing { parts.append(L10n.t("文件已不存在")) }
        case .image(let data, _):
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
        case .link(let url):
            parts.append(String(url.prefix(90)))
        case .text(let text):
            let preview = text.replacingOccurrences(of: "\n", with: " ")
            parts.append(String(preview.prefix(80)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 瓷片

    /// 与 FileTile 同一视觉语言的类型瓷片；图像载荷用解码缩略图
    @ViewBuilder
    private var tile: some View {
        switch entry.payload {
        case .files(let paths):
            if let first = paths.first {
                // 借用文件瓷片：类型符号 / 扩展名角标 / 渐变底全部复用
                FileTile(
                    item: ShelfItem(url: URL(fileURLWithPath: first)),
                    thumbs: Self.emptyThumbs,
                    size: tileSize
                )
            } else {
                symbolTile(symbol: "doc.fill", hex: 0x8E8E93)
            }
        case .image:
            if let image {
                imageTile(image)
            } else {
                symbolTile(symbol: "photo.fill", hex: 0x2FA252)
            }
        case .link:
            symbolTile(symbol: "link", hex: 0x3D9BE8)
        case .text:
            symbolTile(symbol: "doc.plaintext", hex: 0x8E8E93)
        }
    }

    private func imageTile(_ image: NSImage) -> some View {
        let radius = tileSize * 0.27
        return Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: tileSize, height: tileSize)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.42 : 0.55), lineWidth: 0.8)
            )
    }

    /// 链接 / 文本 / 兜底的符号瓷片：与 FileTile.glyphTile 同构（渐变底 + 柔光 + 符号 + 高光描边）
    private func symbolTile(symbol: String, hex: UInt32) -> some View {
        let style = FileIconStyle(symbolName: symbol, hex: hex)
        let radius = tileSize * 0.27
        let dark = colorScheme == .dark
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(style.tileFill)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.26), Color.white.opacity(0)],
                        center: UnitPoint(x: 0.24, y: 0.10),
                        startRadius: 0,
                        endRadius: tileSize * 1.15
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: tileSize * 0.4, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(style.symbolGradient(dark: dark))
                .shadow(color: style.color.opacity(dark ? 0.45 : 0.35), radius: tileSize * 0.05, y: tileSize * 0.04)
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(dark ? 0.42 : 0.55), location: 0),
                            .init(color: Color.white.opacity(0.05), location: 0.62),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: max(0.5, tileSize * 0.022)
                )
        )
        .shadow(color: style.color.opacity(dark ? 0.34 : 0.28), radius: tileSize * 0.12, y: tileSize * 0.07)
    }

    private func decodeImageIfNeeded() {
        guard case .image(let data, _) = entry.payload, image == nil else { return }
        // 只在主线程解小图：历史图像被 8MB 上限拦过，直接解不至于卡顿
        if let decoded = NSImage(data: data) {
            onDecodeImage(decoded)
        }
    }
}
