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
    private let popover = NSPopover()
    private let width = NSSlider(value: 4, minValue: 1, maxValue: 40, target: nil, action: nil)
    private let opacity = NSSlider(value: 1, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let strength = NSSlider(value: 12, minValue: 2, maxValue: 90, target: nil, action: nil)
    private let fill = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
    private var colorButtons: [NSButton] = []
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
        doneButton.toolTip = "Copy screenshot (Return)"
        cancelButton.toolTip = "Cancel capture (Esc)"
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("capture.toolbar.status")
        addSubview(statusLabel)
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
        let colors = NSStackView()
        for (index, color) in RGBA.palette.enumerated() {
            let button = NSButton(title: ["Red", "Yellow", "Green", "Blue", "Black", "White"][index], target: self, action: #selector(colorPicked(_:)))
            button.tag = index; button.bezelStyle = .rounded
            button.contentTintColor = NSColor(cgColor: Imaging.cgColor(color)); colors.addArrangedSubview(button); colorButtons.append(button)
        }
        let controls = NSStackView(); controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 10
        controls.addArrangedSubview(colors)
        for (label, slider) in [("Width / size", width), ("Opacity", opacity), ("Effect strength", strength)] {
            slider.target = self; slider.action = #selector(sliderChanged(_:)); slider.isContinuous = false
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true; slider.setAccessibilityLabel(label)
            controls.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: label), slider]))
        }
        fill.target = self; fill.action = #selector(fillChanged); controls.addArrangedSubview(fill)
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
        preferredSize = NSSize(width: width, height: statusLabel.frame.maxY + padding)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    func popoverDidClose(_ notification: Notification) { editor.session.restoreResponder() }
    func closePopover() { popover.close() }
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
        let active = (selectionButtons + toolButtons).first { !$0.isHidden && $0.state == .on }?.title ?? "Capture"
        let hint: String
        switch editor.phase {
        case .selecting(.pickWindow): hint = "Click a window · Esc: Cancel"
        case .selecting(.pickMonitor): hint = "Click a monitor · Esc: Cancel"
        case .selecting: hint = "Drag and release to copy · Esc: Cancel"
        case .annotating: hint = "Tab: Region · Esc: Cancel"
        case .editing, .ended: hint = "Return: Copy · Esc: Cancel"
        }
        statusLabel.stringValue = editor.session.status ?? "\(active) · \(hint)"
        statusLabel.toolTip = statusLabel.stringValue
        styleButton.isEnabled = editor.styleTarget != nil
        if let kind = editor.styleTarget {
            let style = editor.doc.selected?.style ?? editor.doc.style(for: kind)
            let font = kind == .text || kind == .step
            width.minValue = font ? 8 : 1; width.maxValue = font ? 96 : 40; width.doubleValue = font ? style.fontSize : style.width
            opacity.doubleValue = style.opacity
            strength.minValue = kind == .blur || kind == .pixelate ? EffectMath.minStrength : 2
            strength.doubleValue = style.strength; strength.isEnabled = kind.isEffect
            fill.state = style.filled ? .on : .off; fill.isEnabled = [.rectangle, .ellipse, .text].contains(kind)
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
    @objc private func colorPicked(_ button: NSButton) { editor.changeStyle { $0.color = RGBA.palette[button.tag] } }
    @objc private func fillChanged() { let on = fill.state == .on; editor.changeStyle { $0.filled = on } }
    @objc private func sliderChanged(_ slider: NSSlider) {
        let value = slider.doubleValue, font = editor.styleTarget == .text || editor.styleTarget == .step
        switch slider {
        case width: editor.changeStyle { if font { $0.fontSize = value } else { $0.width = value } }
        case opacity: editor.changeStyle { $0.opacity = value }
        default: editor.changeStyle { $0.strength = value }
        }
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
    #endif
}
