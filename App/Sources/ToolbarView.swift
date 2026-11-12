import AppKit
import ShareXCore

@MainActor
final class ToolbarView: NSVisualEffectView, NSPopoverDelegate {
    private unowned let editor: EditorView
    private let tools: [(Tool, String, String)] = [
        (.select, "cursorarrow", "Select"), (.crop, "crop", "Crop"),
        (.shape(.rectangle), "rectangle", "Rectangle"), (.shape(.ellipse), "circle", "Ellipse"),
        (.shape(.line), "line.diagonal", "Line"), (.shape(.arrow), "arrow.up.right", "Arrow"),
        (.shape(.highlighter), "highlighter", "Highlighter"), (.shape(.blur), "drop", "Blur"),
        (.shape(.pixelate), "squareshape.split.3x3", "Pixelate"), (.shape(.spotlight), "light.max", "Spotlight"),
        (.shape(.smartErase), "eraser", "Smart Eraser"),
        (.shape(.pen), "scribble", "Pen"), (.shape(.text), "textformat", "Text"),
        (.shape(.step), "1.circle", "Step marker"),
    ]

    private let selections = [("Region", "viewfinder", "Tab"), ("Freehand", "lasso", ""),
                              ("Window", "macwindow", ""), ("Monitor", "display", ""),
                              ("Full Desktop", "rectangle.on.rectangle", "")]
    private var toolButtons: [NSButton] = []
    private var selectionButtons: [NSButton] = []
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let redoButton = NSButton(title: "Redo", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete selected", target: nil, action: nil)
    private let styleButton = NSButton(title: "Style", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let outputLabel = NSTextField(labelWithString: "")
    private let popover = NSPopover()
    private let width = TrackingSlider(value: 4, minValue: 1, maxValue: 40, target: nil, action: nil)
    private let opacity = TrackingSlider(value: 1, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let strength = TrackingSlider(value: 12, minValue: 2, maxValue: 90, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "Width")
    private let widthValue = NSTextField(labelWithString: "")
    private let opacityValue = NSTextField(labelWithString: "")
    private let strengthValue = NSTextField(labelWithString: "")
    private let preview = StylePreviewView(frame: .zero)
    private let fill = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
    private var colorButtons: [ColorSwatch] = []
    private static let colorNames = ["Red", "Yellow", "Green", "Blue", "Black", "White"]
    private var preferredSize = NSSize.zero
    override var fittingSize: NSSize { preferredSize }
    override var isFlipped: Bool { true }

    private var groups: [[NSButton]] {
        [selectionButtons, toolButtons, [styleButton], [undoButton, redoButton, deleteButton], [doneButton, cancelButton]]
    }

    init(editor: EditorView) {
        self.editor = editor
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 8
        for (index, entry) in selections.enumerated() {
            let button = NSButton(title: entry.0, target: self, action: #selector(selectionChanged(_:)))
            configure(button, symbol: entry.1, shortcut: entry.2, selectable: index != 4)
            button.tag = index; selectionButtons.append(button)
        }
        for (index, entry) in tools.enumerated() {
            let shortcut: String
            switch entry.0 { case .select: shortcut = "V"; case .crop: shortcut = "C"; case .shape(let kind): shortcut = String(kind.key).uppercased() }
            let button = NSButton(title: entry.2, target: self, action: #selector(toolChanged(_:)))
            configure(button, symbol: entry.1, shortcut: shortcut, selectable: true)
            button.tag = index; toolButtons.append(button)
        }
        for (button, action, symbol, shortcut) in [
            (styleButton, #selector(openStyle), "slider.horizontal.3", ""),
            (undoButton, #selector(undo), "arrow.uturn.backward", "⌘Z"),
            (redoButton, #selector(redo), "arrow.uturn.forward", "⇧⌘Z"),
            (deleteButton, #selector(deleteSel), "trash", "Delete"),
            (doneButton, #selector(done), "checkmark", "Return"),
            (cancelButton, #selector(cancel), "xmark", "Esc")
        ] {
            button.target = self; button.action = action
            configure(button, symbol: symbol, shortcut: shortcut)
        }
        for button in [styleButton, doneButton, cancelButton] { button.imagePosition = .imageLeading }
        cancelButton.toolTip = "Cancel capture (Esc)"
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("capture.toolbar.status")
        addSubview(statusLabel)
        outputLabel.font = .systemFont(ofSize: 11); outputLabel.textColor = .secondaryLabelColor
        outputLabel.lineBreakMode = .byTruncatingMiddle
        outputLabel.setAccessibilityIdentifier("capture.toolbar.output")
        addSubview(outputLabel)
        buildStyle()
        sync()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }
    private static func embed(_ view: NSView, in container: NSView, padding: NSEdgeInsets) {
        view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding.right),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: padding.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding.bottom),
        ])
    }
    private func configure(_ button: NSButton, symbol: String, shortcut: String, selectable: Bool = false) {
        button.bezelStyle = .regularSquare
        button.setButtonType(selectable ? .pushOnPushOff : .momentaryPushIn)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        button.imagePosition = .imageOnly
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.toolTip = shortcut.isEmpty ? button.title : "\(button.title) (\(shortcut))"
        button.setAccessibilityLabel(button.title)
        button.setAccessibilityHelp(button.toolTip)
        addSubview(button)
    }
    private func buildStyle() {
        let colors = NSStackView(); colors.spacing = 10
        for (index, color) in RGBA.palette.enumerated() {
            let button = ColorSwatch(name: Self.colorNames[index], color: color, target: self, action: #selector(colorPicked(_:)))
            button.tag = index; colors.addArrangedSubview(button); colorButtons.append(button)
        }
        let controls = NSStackView(); controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 10
        controls.addArrangedSubview(colors)
        controls.addArrangedSubview(preview)
        for (label, slider, value, name) in [
            (widthLabel, width, widthValue, "Width / size"),
            (NSTextField(labelWithString: "Opacity"), opacity, opacityValue, "Opacity"),
            (NSTextField(labelWithString: "Strength"), strength, strengthValue, "Effect strength")
        ] {
            slider.target = self; slider.action = #selector(sliderChanged(_:)); slider.isContinuous = true
            slider.beginTracking = { [weak self] in
                guard let self else { return }
                if !popover.isShown { editor.session.activate(editor) }
                editor.session.beginStyleGesture()
            }
            slider.endTracking = { [weak self] in self?.editor.session.endStyleGesture() }
            slider.widthAnchor.constraint(equalToConstant: 166).isActive = true; slider.setAccessibilityLabel(name)
            label.widthAnchor.constraint(equalToConstant: 76).isActive = true
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 46).isActive = true
            value.setAccessibilityIdentifier("capture.style.\(slider === width ? "width" : slider === opacity ? "opacity" : "strength")")
            let row = NSStackView(views: [label, slider, value]); row.spacing = 8
            controls.addArrangedSubview(row)
        }
        fill.target = self; fill.action = #selector(fillChanged); controls.addArrangedSubview(fill)
        let reset = NSButton(title: "Reset tool style", target: self, action: #selector(resetStyle))
        reset.bezelStyle = .rounded; controls.addArrangedSubview(reset)
        let contents = NSView()
        Self.embed(controls, in: contents, padding: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        contents.setFrameSize(contents.fittingSize)
        let controller = NSViewController(); controller.view = contents
        popover.contentViewController = controller; popover.behavior = .transient; popover.delegate = self
    }
    func fit(maxWidth: CGFloat) {
        let limit = max(1, maxWidth), padding: CGFloat = 8, height: CGFloat = 30, gap: CGFloat = 3
        var x = padding, y = padding, used: CGFloat = 0
        for group in groups {
            let visible = group.filter { !$0.isHidden }
            if !visible.isEmpty, x > padding { x += 6 }
            for button in visible {
                let width = button.imagePosition == .imageOnly ? height : max(60, button.intrinsicContentSize.width + 8)
                if x > padding, x + width + padding > limit { x = padding; y += height + gap }
                button.frame = CGRect(x: x, y: y, width: min(width, max(1, limit - padding * 2)), height: height)
                x = button.frame.maxX + gap; used = max(used, button.frame.maxX + padding)
            }
        }
        let width = min(limit, max(min(360, limit), used))
        statusLabel.frame = CGRect(x: padding, y: y + height + 5, width: max(1, width - padding * 2), height: 16)
        outputLabel.frame = statusLabel.frame.offsetBy(dx: 0, dy: 17)
        preferredSize = NSSize(width: width, height: outputLabel.frame.maxY + padding)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    func popoverDidClose(_ notification: Notification) { editor.session.endStyleGesture(); editor.session.restoreResponder() }
    func closePopover() { editor.session.endStyleGesture(); popover.close() }
    func sync() {
        let modes: [SelectionMode] = [.rectangle, .lasso, .pickWindow, .pickMonitor]
        for (index, button) in selectionButtons.enumerated() {
            button.isHidden = !editor.session.canChooseSelection
            button.isEnabled = index != 2 || editor.session.canPickWindow
            button.state = index < modes.count && editor.phase == .selecting(modes[index]) ? .on : .off
        }
        for (index, button) in toolButtons.enumerated() {
            button.isHidden = tools[index].0 == .crop && editor.phase != .editing
            button.state = (editor.phase == .annotating || editor.phase == .editing) && tools[index].0 == editor.tool ? .on : .off
        }
        undoButton.isEnabled = editor.doc.history.canUndo; redoButton.isEnabled = editor.doc.history.canRedo
        deleteButton.isEnabled = editor.doc.selectedID != nil
        doneButton.isEnabled = editor.session.canFinish
        doneButton.isHidden = editor.session.canChooseSelection
        doneButton.toolTip = "\(editor.session.outputAction) screenshot (Return)"
        doneButton.setAccessibilityHelp(doneButton.toolTip)
        outputLabel.stringValue = editor.session.outputSummary; outputLabel.toolTip = outputLabel.stringValue
        let active = (selectionButtons + toolButtons).first { !$0.isHidden && $0.state == .on }?.title ?? "Capture"
        let hint: String
        switch editor.phase {
        case .selecting(.pickWindow): hint = "Click a window · Esc: Cancel"
        case .selecting(.pickMonitor): hint = "Click a monitor · Esc: Cancel"
        case .selecting: hint = "Drag and release to \(editor.session.outputAction.lowercased()) · Esc: Cancel"
        case .annotating: hint = "Tab: Region · Esc: Cancel"
        case .editing, .ended: hint = "Return: \(editor.session.outputAction) · Esc: Cancel"
        }
        let kind = editor.styleTarget
        let style = kind.map { editor.doc.selected?.style ?? editor.doc.style(for: $0) }
        let colorName = style.flatMap { RGBA.palette.firstIndex(of: $0.color) }.map { Self.colorNames[$0] } ?? "Custom color"
        let editing = editor.phase == .annotating || editor.phase == .editing
        let styleHint = kind.map { $0.isEffect || !editing
            ? "" : " · \(colorName) · \(Int(((style?.opacity ?? 1) * 100).rounded()))%" } ?? ""
        statusLabel.stringValue = editor.session.status ?? (editing && editor.tool == .shape(.smartErase)
            ? "Smart Eraser · Drag over a small object on a plain or smooth background"
            : "\(active)\(styleHint) · \(hint)")
        statusLabel.toolTip = statusLabel.stringValue
        styleButton.isEnabled = kind != nil && kind != .smartErase
        if kind == .smartErase, popover.isShown { popover.close() }
        if let kind, let style {
            let font = kind == .text || kind == .step
            width.minValue = font ? 8 : 1; width.maxValue = font ? 96 : 40; width.doubleValue = font ? style.fontSize : style.width
            width.isEnabled = [.rectangle, .ellipse, .line, .arrow, .pen, .text, .step].contains(kind)
            widthLabel.stringValue = font ? "Text size" : "Width"
            widthValue.stringValue = width.isEnabled ? "\(Int(width.doubleValue.rounded())) pt" : "—"
            opacity.doubleValue = style.opacity; opacity.isEnabled = !kind.isEffect
            opacityValue.stringValue = opacity.isEnabled ? "\(Int((style.opacity * 100).rounded()))%" : "—"
            strength.minValue = kind == .blur || kind == .pixelate ? EffectMath.minStrength : 2
            strength.doubleValue = style.strength; strength.isEnabled = [.blur, .pixelate, .spotlight].contains(kind)
            strengthValue.stringValue = strength.isEnabled ? "\(Int(style.strength.rounded()))" : "—"
            fill.state = style.filled ? .on : .off; fill.isEnabled = [.rectangle, .ellipse, .text].contains(kind)
            for button in colorButtons {
                button.isEnabled = !kind.isEffect; button.state = button.color == style.color ? .on : .off
                button.setAccessibilityValue(button.state == .on ? "Selected" : "Not selected"); button.needsDisplay = true
            }
            if kind != .smartErase { preview.show(kind: kind, style: style) }
            styleButton.toolTip = kind == .smartErase ? "Drag over a small object on a plain or smooth background"
                : kind.isEffect ? "Adjust effect strength" : "Style · \(colorName) · \(opacityValue.stringValue) opacity"
            styleButton.setAccessibilityHelp(styleButton.toolTip)
        }
    }
    @objc private func selectionChanged(_ item: NSButton) {
        editor.session.activate(editor)
        if item.tag == 4 { editor.session.selectDesktop() }
        else { editor.session.chooseSelection([.rectangle, .lasso, .pickWindow, .pickMonitor][item.tag]) }
    }
    @objc private func toolChanged(_ item: NSButton) { editor.setTool(tools[item.tag].0) }
    @objc private func openStyle() {
        editor.session.activate(editor); editor.session.commitText()
        popover.show(relativeTo: styleButton.bounds, of: styleButton, preferredEdge: .maxY)
    }
    private func changeStyle(_ change: (inout ShapeStyle) -> Void) {
        if !popover.isShown { editor.session.activate(editor) }
        editor.session.changeStyle(change, restoreFocus: !popover.isShown)
    }
    @objc private func colorPicked(_ button: NSButton) { changeStyle { $0.color = RGBA.palette[button.tag] } }
    @objc private func fillChanged() { let on = fill.state == .on; changeStyle { $0.filled = on } }
    @objc private func resetStyle() {
        guard let kind = editor.styleTarget else { return }
        changeStyle { $0 = .defaults(for: kind) }
    }
    @objc private func sliderChanged(_ slider: NSSlider) {
        let value = slider.doubleValue, font = editor.styleTarget == .text || editor.styleTarget == .step
        switch slider {
        case width: changeStyle { if font { $0.fontSize = value } else { $0.width = value } }
        case opacity: changeStyle { $0.opacity = value }
        default: changeStyle { $0.strength = value }
        }
        #if SHAREX_E2E
        e2eStyleChanged?(slider)
        #endif
    }
    @objc private func undo() { editor.undo() }
    @objc private func redo() { editor.redo() }
    @objc private func deleteSel() { editor.deleteSelection() }
    @objc private func done() { editor.finish() }
    @objc private func cancel() { editor.cancel() }
    #if SHAREX_E2E
    var e2eDone: NSButton { doneButton }
    var e2eCancel: NSButton { cancelButton }
    var e2eButtons: [NSButton] { groups.flatMap { $0 }.filter { !$0.isHidden } }
    func e2eButton(_ title: String) -> NSButton? { e2eButtons.first { $0.title == title } }
    var e2eStyle: NSButton { styleButton }
    var e2eStyleContents: NSView { popover.contentViewController!.view }
    var e2ePopoverShown: Bool { popover.isShown }
    var e2ePreview: NSView { preview }
    var e2eOutput: String { outputLabel.stringValue }
    var e2eStyleChanged: ((NSSlider) -> Void)?
    #endif
}
