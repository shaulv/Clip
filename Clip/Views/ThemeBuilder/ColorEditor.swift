import SwiftUI
import AppKit

/// The one colour picker (user, 04/09: "all color picker interactions ...
/// exactly like Figma's color picker but with our styles"): a saturation /
/// brightness square with a ring handle, a hue bar, an alpha bar over a
/// checkerboard, the eyedropper (`NSColorSampler`), a format menu (HEX, RGB,
/// HSL, HSB) with numeric fields and an alpha %, and a swatch section (the
/// live theme's colours, or the colours picked recently). Every change
/// applies live to `hex` (`#RRGGBB`, or `#RRGGBBAA` while alpha < 100).
///
/// One editor for every place a colour is chosen - the theme builder's
/// swatch popover, the Colors tab's "Add a color", a colour item's own detail
/// - so a person learns it once. Drawn with the theme handed in, never a
/// second design system.
struct ColorEditor: View {
    @Binding var hex: String
    var title: String
    var theme: AppTheme
    /// The header's X. Nil hides it (the owner draws its own way out).
    var onClose: (() -> Void)? = nil

    @State private var hue: Double = 0            // 0...360
    @State private var saturation: Double = 0     // 0...1
    @State private var brightness: Double = 0     // 0...1
    @State private var alpha: Double = 1          // 0...1
    @State private var format: ColorFormat = .hex
    @State private var fields: [String] = ["", "", ""]
    @State private var hexField = ""
    @State private var alphaField = "100"
    @State private var swatchSource: SwatchSource = .theme
    @State private var recents: [String] = ColorEditor.loadRecents()
    /// Set while this editor is writing `hex` itself, so the `onChange(of:
    /// hex)` sync-back does not fight the very edit that caused it.
    @State private var isSelfUpdating = false

    enum ColorFormat: String, CaseIterable, Identifiable {
        case hex = "HEX", rgb = "RGB", hsl = "HSL", hsb = "HSB"
        var id: String { rawValue }
    }
    enum SwatchSource: String, CaseIterable, Identifiable {
        case theme = "Theme colors", recent = "Recent"
        var id: String { rawValue }
    }

    static let width: CGFloat = 280
    private static let inset: CGFloat = 16
    private static let squareSide: CGFloat = width - inset * 2
    private static let barHeight: CGFloat = 14
    private static let handle: CGFloat = 14
    private static let recentsKey = "recentPickerColors"

    private var t: AppTheme { theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(t.border)
            VStack(alignment: .leading, spacing: Spacing.related) {
                square
                HStack(alignment: .center, spacing: Spacing.related) {
                    eyedropper
                    VStack(spacing: Spacing.tight) {
                        hueBar
                        alphaBar
                    }
                }
                formatRow
            }
            .padding(Self.inset)
            Divider().overlay(t.border)
            swatches
                .padding(Self.inset)
        }
        .frame(width: Self.width)
        .background(t.panelBackground)
        // M19 inspect tag: every theme token this picker paints with.
        .themeTokens(["panelBackground", "border", "surfaceBackground", "textPrimary",
                      "textSecondary", "textTertiary", "accent", "accentSecondary",
                      "cardBackground", "cardHoverBackground", "selectedBackground",
                      "destructive", "success", "warning"])
        .onAppear(perform: syncFromHex)
        .onChange(of: hex) { _, _ in
            guard !isSelfUpdating else { return }
            syncFromHex()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(title)
                .font(Typography.subheading)
                .foregroundStyle(t.textPrimary)
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(Typography.caption.weight(.bold))
                        .foregroundStyle(t.textSecondary)
                        .iconButtonChrome(t, variant: .dismiss)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, Spacing.related)
    }

    // MARK: - Square (saturation across, brightness up)

    private var square: some View {
        let side = Self.squareSide
        let pureHue = Color(hue: hue / 360, saturation: 1, brightness: 1)
        let shape = RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(pureHue)
            LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .clipShape(shape)
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                .clipShape(shape)
            ringHandle(fill: currentColorOpaque)
                .offset(x: saturation * side - Self.handle / 2,
                        y: (1 - brightness) * side - Self.handle / 2)
        }
        .frame(width: side, height: side)
        .overlay(shape.strokeBorder(t.border, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            saturation = min(max(value.location.x / side, 0), 1)
            brightness = 1 - min(max(value.location.y / side, 0), 1)
            commit()
        })
    }

    // MARK: - Bars

    private var hueBar: some View {
        let spectrum = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) }
        return bar(fill: AnyShapeStyle(LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing)),
                   fraction: hue / 360,
                   handleFill: Color(hue: hue / 360, saturation: 1, brightness: 1),
                   checkerboard: false) { fraction in
            hue = fraction * 360
            commit()
        }
    }

    private var alphaBar: some View {
        bar(fill: AnyShapeStyle(LinearGradient(colors: [currentColorOpaque.opacity(0), currentColorOpaque],
                                               startPoint: .leading, endPoint: .trailing)),
            fraction: alpha,
            handleFill: currentColor,
            checkerboard: true) { fraction in
            alpha = fraction
            commit()
        }
    }

    private func bar(fill: AnyShapeStyle, fraction: Double, handleFill: Color, checkerboard: Bool,
                     onDrag: @escaping (Double) -> Void) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                if checkerboard {
                    CheckerboardBackground(tile: 5).clipShape(Capsule())
                }
                Capsule().fill(fill)
                Capsule().strokeBorder(t.border, lineWidth: 1)
                ringHandle(fill: handleFill)
                    .offset(x: fraction * (width - Self.handle))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let usable = max(width - Self.handle, 1)
                onDrag(min(max((value.location.x - Self.handle / 2) / usable, 0), 1))
            })
        }
        .frame(height: Self.barHeight)
    }

    /// The Figma handle: a white ring around the current colour, with a soft
    /// shadow so it reads on any hue.
    private func ringHandle(fill: Color) -> some View {
        ZStack {
            Circle().fill(.white)
            Circle().fill(fill).padding(2.5)
        }
        .frame(width: Self.handle, height: Self.handle)
        .elevation(Shadows.tooltip)
    }

    private var eyedropper: some View {
        Button(action: pickWithEyedropper) {
            Image(systemName: "eyedropper")
                .font(Typography.subheading)
                .foregroundStyle(t.textSecondary)
                .frame(width: 30, height: 30)
                .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                    .strokeBorder(t.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Pick a color from anywhere on screen")
    }

    // MARK: - Format row

    private var formatRow: some View {
        HStack(spacing: Spacing.tight) {
            dropdown(format.rawValue, fixed: true) {
                ForEach(ColorFormat.allCases) { f in
                    Button(f.rawValue) { format = f; refreshFields() }
                }
            }
            if format == .hex {
                pill { TextField("", text: $hexField).onSubmit(applyHexField) }
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(0..<3, id: \.self) { i in
                    pill { TextField("", text: $fields[i]).onSubmit(applyFields) }
                }
            }
            pill {
                HStack(spacing: 2) {
                    TextField("", text: $alphaField).onSubmit(applyAlphaField)
                    Text("%").foregroundStyle(t.textTertiary)
                }
            }
            .frame(width: 58)
        }
    }

    /// A borderless Menu drawn as one of the picker's surface pills.
    private func dropdown<Items: View>(_ label: String, fixed: Bool, @ViewBuilder items: () -> Items) -> some View {
        Menu(content: items) {
            HStack(spacing: 4) {
                Text(label)
                if !fixed { Spacer() }
                Image(systemName: "chevron.down").font(Typography.micro)
            }
            .font(Typography.body.weight(.medium))
            .foregroundStyle(t.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: fixed ? nil : .infinity)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: fixed, vertical: true)
        .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
            .strokeBorder(t.border, lineWidth: 1))
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .font(Typography.bodyMono)
            .foregroundStyle(t.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                .strokeBorder(t.border, lineWidth: 1))
    }

    // MARK: - Swatches

    private var swatches: some View {
        VStack(alignment: .leading, spacing: Spacing.related) {
            dropdown(swatchSource.rawValue, fixed: false) {
                ForEach(SwatchSource.allCases) { s in
                    Button(s.rawValue) { swatchSource = s }
                }
            }
            let items = swatchSource == .theme ? themeSwatches : recents
            if items.isEmpty {
                Text("Nothing picked yet.")
                    .font(Typography.label).foregroundStyle(t.textTertiary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 9), spacing: 6) {
                    ForEach(items, id: \.self) { value in
                        Button {
                            isSelfUpdating = true
                            hex = value
                            syncFromHex()
                            DispatchQueue.main.async { isSelfUpdating = false }
                        } label: {
                            ZStack {
                                CheckerboardBackground(tile: 4)
                                Color(nsColor: NSColor(hex: value) ?? .clear)
                            }
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                                .strokeBorder(t.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(value.uppercased())
                    }
                }
            }
        }
    }

    /// The live theme's own colours, so a token can borrow from a sibling.
    private var themeSwatches: [String] {
        let colors: [Color] = [t.accent, t.accentSecondary, t.panelBackground, t.cardBackground,
                               t.cardHoverBackground, t.selectedBackground, t.surfaceBackground,
                               t.textPrimary, t.textSecondary, t.textTertiary, t.border,
                               t.destructive, t.success, t.warning]
        var seen: [String] = []
        for c in colors {
            let h = c.hexString
            if !seen.contains(h) { seen.append(h) }
        }
        return seen
    }

    // MARK: - Model

    private var currentColor: Color {
        Color(nsColor: NSColor(hue: hue / 360, saturation: saturation, brightness: brightness, alpha: alpha))
    }
    private var currentColorOpaque: Color {
        Color(nsColor: NSColor(hue: hue / 360, saturation: saturation, brightness: brightness, alpha: 1))
    }

    /// Writes the current HSB + alpha into `hex` and refreshes the fields.
    private func commit() {
        isSelfUpdating = true
        let color = NSColor(hue: hue / 360, saturation: saturation, brightness: brightness, alpha: alpha)
        hex = Color(nsColor: color).hexString
        refreshFields()
        DispatchQueue.main.async { isSelfUpdating = false }
    }

    private func syncFromHex() {
        guard let color = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return }
        hue = Double(color.hueComponent) * 360
        saturation = Double(color.saturationComponent)
        brightness = Double(color.brightnessComponent)
        alpha = Double(color.alphaComponent)
        refreshFields()
    }

    private func refreshFields() {
        guard let c = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return }
        hexField = String(hex.uppercased().prefix(7))
        alphaField = "\(Int((alpha * 100).rounded()))"
        switch format {
        case .hex:
            fields = ["", "", ""]
        case .rgb:
            fields = [c.redComponent, c.greenComponent, c.blueComponent].map { "\(Int(($0 * 255).rounded()))" }
        case .hsl:
            let (h, s, l) = hsl(of: c)
            fields = ["\(Int(h.rounded()))", "\(Int((s * 100).rounded()))", "\(Int((l * 100).rounded()))"]
        case .hsb:
            fields = ["\(Int(hue.rounded()))", "\(Int((saturation * 100).rounded()))", "\(Int((brightness * 100).rounded()))"]
        }
    }

    private func hsl(of c: NSColor) -> (Double, Double, Double) {
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        return (hue, s, l)
    }

    private func applyHexField() {
        var candidate = hexField.trimmingCharacters(in: .whitespaces)
        if !candidate.hasPrefix("#") { candidate = "#" + candidate }
        guard let color = NSColor(hex: candidate)?.usingColorSpace(.sRGB) else { refreshFields(); return }
        hue = Double(color.hueComponent) * 360
        saturation = Double(color.saturationComponent)
        brightness = Double(color.brightnessComponent)
        commit()
    }

    private func applyFields() {
        let values = fields.map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        switch format {
        case .hex:
            return
        case .rgb:
            let c = NSColor(srgbRed: min(max(values[0] / 255, 0), 1), green: min(max(values[1] / 255, 0), 1),
                            blue: min(max(values[2] / 255, 0), 1), alpha: 1)
            hue = Double(c.hueComponent) * 360; saturation = Double(c.saturationComponent); brightness = Double(c.brightnessComponent)
        case .hsl:
            let h = min(max(values[0], 0), 360), s = min(max(values[1] / 100, 0), 1), l = min(max(values[2] / 100, 0), 1)
            let v = l + s * min(l, 1 - l)              // HSL to HSB
            let sb = v == 0 ? 0 : 2 * (1 - l / v)
            hue = h; saturation = sb; brightness = v
        case .hsb:
            hue = min(max(values[0], 0), 360); saturation = min(max(values[1] / 100, 0), 1); brightness = min(max(values[2] / 100, 0), 1)
        }
        commit()
    }

    private func applyAlphaField() {
        let cleaned = alphaField.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let value = Double(cleaned) else { refreshFields(); return }
        alpha = min(max(value / 100, 0), 1)
        commit()
    }

    /// `NSColorSampler` reads a live pixel from anywhere on screen. Keeps the
    /// alpha already set here - a sampled screen pixel is always opaque.
    private func pickWithEyedropper() {
        NSColorSampler().show { picked in
            guard let picked, let sRGB = picked.usingColorSpace(.sRGB) else { return }
            hue = Double(sRGB.hueComponent) * 360
            saturation = Double(sRGB.saturationComponent)
            brightness = Double(sRGB.brightnessComponent)
            commit()
        }
    }

    // MARK: - Recents

    private static func loadRecents() -> [String] {
        AppPaths.defaults.stringArray(forKey: recentsKey) ?? []
    }

    /// Called by the owners when a colour is COMMITTED (a token's popover
    /// closed, a colour added, an item's editor closed), so Recent shows
    /// choices rather than every drag position.
    static func remember(_ hex: String) {
        guard NSColor(hex: hex) != nil else { return }
        var list = loadRecents().filter { $0.caseInsensitiveCompare(hex) != .orderedSame }
        list.insert(hex, at: 0)
        AppPaths.defaults.set(Array(list.prefix(18)), forKey: recentsKey)
    }
}
