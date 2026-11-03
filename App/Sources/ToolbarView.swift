import AppKit
import ShareXCore

/// The floating annotation toolbar: tools, colour, width/size, opacity, fill, strength, undo/redo, done/cancel.
@MainActor
final class ToolbarView: NSVisualEffectView {
    private unowned let editor: EditorView
    private let tools: [(Tool, String, String)] = [
        (.select, "cursorarrow", "Select (V)"), (.crop, "crop", "Crop (C)"),
        (.shape(.rectangle), "rectangle", "Rectangle (R)"), (.shape(.ellipse), "circle", "Ellipse (E)"),
        (.shape(.line), "line.diagonal", "Line (L)"), (.shape(.arrow), "arrow.up.right", "Arrow (A)"),
        (.shape(.highlighter), "highlighter", "Highlighter (H)"), (.shape(.blur), "drop", "Blur (B)"),
        (.shape(.pixelate), "squareshape.split.3x3", "Pixelate (P)"), (.shape(.spotlight), "light.max", "Spotlight (S)"),
        (.shape(.pen), "scribble", "Freehand (F)"), (.shape(.text), "textformat", "Text (T)"),
        (.shape(.step), "1.circle", "Step marker (I)"),
    ]
    private let segmented = NSSegmentedControl()
    private let colorButtons: [NSButton]
    private let width = NSSlider(value: 4, minValue: 1, maxValue: 40, target: nil, action: nil)
    private let opacity = NSSlider(value: 1, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let strength = NSSlider(value: 12, minValue: 2, maxValue: 90, target: nil, action: nil)
    private let fill = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
    private let undoButton = NSButton(), redoButton = NSButton()
    /// Tools and style controls; one row when the screen is wide enough, two rows otherwise.
    private let stack = NSStackView()

    init(editor: EditorView) {
        self.editor = editor
        colorButtons = RGBA.palette.map { c in
            let b = NSButton(title: "", target: nil, action: nil)
            b.isBordered = false; b.wantsLayer = true
            b.layer?.backgroundColor = Imaging.cgColor(c); b.layer?.cornerRadius = 9
            b.layer?.borderColor = CGColor(gray: 0.5, alpha: 1); b.layer?.borderWidth = 1
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return b
        }
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 8

        segmented.segmentCount = tools.count
        segmented.trackingMode = .selectOne
        for (i, t) in tools.enumerated() {
            segmented.setImage(NSImage(systemSymbolName: t.1, accessibilityDescription: t.2), forSegment: i)
            segmented.setToolTip(t.2, forSegment: i)
            segmented.setWidth(28, forSegment: i)
        }
        segmented.target = self; segmented.action = #selector(toolChanged)
        for (i, b) in colorButtons.enumerated() { b.tag = i; b.target = self; b.action = #selector(colorPicked(_:)) }
        for s in [width, opacity, strength] { s.target = self; s.action = #selector(sliderChanged(_:)); s.isContinuous = false; s.widthAnchor.constraint(equalToConstant: 70).isActive = true }
        width.toolTip = "Width / size"; opacity.toolTip = "Opacity"; strength.toolTip = "Blur / pixel / dim strength"
        fill.target = self; fill.action = #selector(fillChanged)

        func icon(_ name: String, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: tip) ?? NSImage(), target: self, action: sel)
            b.bezelStyle = .texturedRounded; b.toolTip = tip
            return b
        }
        undoButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")
        undoButton.bezelStyle = .texturedRounded; undoButton.target = self; undoButton.action = #selector(undo); undoButton.toolTip = "Undo (⌘Z)"
        redoButton.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo")
        redoButton.bezelStyle = .texturedRounded; redoButton.target = self; redoButton.action = #selector(redo); redoButton.toolTip = "Redo (⇧⌘Z)"

        let styleRow = NSStackView(views: colorButtons + [width, opacity, strength, fill, undoButton, redoButton,
                                   icon("trash", "Delete selected (⌫)", #selector(deleteSel)),
                                   icon("checkmark", "Copy to clipboard (Enter)", #selector(done)),
                                   icon("xmark", "Cancel (Esc)", #selector(cancel))])
        styleRow.orientation = .horizontal; styleRow.spacing = 6
        for v in [segmented, styleRow] { stack.addArrangedSubview(v) }
        stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    /// About 1000 pt wide in one row; small screens get the tools above the style controls.
    func fit(maxWidth: CGFloat) {
        stack.orientation = .horizontal; stack.alignment = .centerY
        if fittingSize.width > maxWidth { stack.orientation = .vertical; stack.alignment = .leading }
    }

    // Clicks between controls must not fall through to the editor and start a shape under the toolbar.
    override func mouseDown(with e: NSEvent) {}
    override func mouseDragged(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {}
    override func rightMouseDown(with e: NSEvent) {}

    /// Reflects the editor's tool, the target style, and undo availability.
    func sync() {
        if let i = tools.firstIndex(where: { $0.0 == editor.tool }) { segmented.selectedSegment = i }
        let target = editor.styleTarget
        let style = target.map { k in editor.doc.selected.flatMap { $0.kind == k ? $0.style : nil } ?? editor.doc.style(for: k) }
        for c in [width, opacity, strength, fill] as [NSControl] { c.isEnabled = style != nil }
        if let s = style, let k = target {
            let usesFont = k == .text || k == .step
            width.minValue = usesFont ? 8 : 1; width.maxValue = usesFont ? 96 : 40
            width.doubleValue = usesFont ? s.fontSize : s.width
            opacity.doubleValue = s.opacity
            strength.doubleValue = s.strength
            strength.isEnabled = k.isEffect
            fill.state = s.filled ? .on : .off
            fill.isEnabled = [.rectangle, .ellipse, .text].contains(k)
        }
        undoButton.isEnabled = editor.doc.history.canUndo
        redoButton.isEnabled = editor.doc.history.canRedo
    }

    @objc private func toolChanged() { editor.setTool(tools[segmented.selectedSegment].0) }
    @objc private func colorPicked(_ b: NSButton) { editor.changeStyle { $0.color = RGBA.palette[b.tag] } }
    @objc private func fillChanged() { let on = fill.state == .on; editor.changeStyle { $0.filled = on } }
    @objc private func sliderChanged(_ s: NSSlider) {
        let v = s.doubleValue
        let usesFont = editor.styleTarget == .text || editor.styleTarget == .step
        switch s {
        case width: editor.changeStyle { if usesFont { $0.fontSize = v } else { $0.width = v } }
        case opacity: editor.changeStyle { $0.opacity = v }
        default: editor.changeStyle { $0.strength = v }
        }
        sync()
    }
    @objc private func undo() { editor.undo() }
    @objc private func redo() { editor.redo() }
    @objc private func deleteSel() { editor.deleteSelection() }
    @objc private func done() { editor.finish() }
    @objc private func cancel() { editor.cancel() }
}
