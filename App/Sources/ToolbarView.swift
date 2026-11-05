import AppKit
import ShareXCore

@MainActor
final class ToolbarView: NSVisualEffectView, NSMenuDelegate, NSPopoverDelegate {
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

    private let toolMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let moreMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let styleButton = NSButton(title: "Style", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView(), row = NSStackView(), actions = NSStackView()
    private let popover = NSPopover()
    private let width = NSSlider(value: 4, minValue: 1, maxValue: 40, target: nil, action: nil)
    private let opacity = NSSlider(value: 1, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let strength = NSSlider(value: 12, minValue: 2, maxValue: 90, target: nil, action: nil)
    private let fill = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
    private var colorButtons: [NSButton] = []
    private var compact = false
    private var trackingMenu = false

    init(editor: EditorView) {
        self.editor = editor
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 8
        for (button, action) in [(styleButton, #selector(openStyle)), (doneButton, #selector(done)), (cancelButton, #selector(cancel))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        doneButton.setAccessibilityLabel("Done"); cancelButton.setAccessibilityLabel("Cancel")
        toolMenu.setAccessibilityLabel("Tool"); moreMenu.setAccessibilityLabel("More")
        toolMenu.menu?.delegate = self; moreMenu.menu?.delegate = self
        for view in [toolMenu, styleButton, moreMenu] { row.addArrangedSubview(view) }
        for view in [doneButton, cancelButton] { actions.addArrangedSubview(view) }
        row.addArrangedSubview(actions)
        row.orientation = .horizontal; row.spacing = 4; actions.spacing = 4
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.addArrangedSubview(row); stack.addArrangedSubview(statusLabel)
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .labelColor
        statusLabel.preferredMaxLayoutWidth = 300
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        buildStyle()
        sync()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }
    private func item(_ title: String, action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.tag = tag; return item
    }
    private func buildStyle() {
        let colors = NSStackView()
        for (index, color) in RGBA.palette.enumerated() {
            let button = NSButton(title: ["Red", "Yellow", "Green", "Blue", "Black", "White"][index], target: self, action: #selector(colorPicked(_:)))
            button.tag = index; button.bezelStyle = .rounded
            button.contentTintColor = NSColor(cgColor: Imaging.cgColor(color)); colors.addArrangedSubview(button); colorButtons.append(button)
        }
        let controls = NSStackView(); controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 10
        controls.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        controls.addArrangedSubview(colors)
        for (label, slider) in [("Width / size", width), ("Opacity", opacity), ("Effect strength", strength)] {
            slider.target = self; slider.action = #selector(sliderChanged(_:)); slider.isContinuous = false
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true; slider.setAccessibilityLabel(label)
            controls.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: label), slider]))
        }
        fill.target = self; fill.action = #selector(fillChanged); controls.addArrangedSubview(fill)
        let controller = NSViewController(); controller.view = controls
        popover.contentViewController = controller; popover.behavior = .transient; popover.delegate = self
    }
    func fit(maxWidth: CGFloat) {
        let narrow = maxWidth < 355
        if narrow != compact {
            let owner = compact ? stack : row
            owner.removeArrangedSubview(actions); actions.removeFromSuperview()
            if narrow { stack.insertArrangedSubview(actions, at: 1) } else { row.addArrangedSubview(actions) }
            compact = narrow
        }
        statusLabel.preferredMaxLayoutWidth = max(160, min(300, maxWidth - 20))
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    func menuWillOpen(_ menu: NSMenu) { trackingMenu = true; editor.session.activate(editor); editor.session.commitText() }
    func menuDidClose(_ menu: NSMenu) { trackingMenu = false; editor.session.restoreResponder() }
    func popoverDidClose(_ notification: Notification) { editor.session.restoreResponder() }
    func closePopover() { popover.close() }
    func sync() {
        if !trackingMenu {
        toolMenu.removeAllItems(); toolMenu.addItem(withTitle: "Tool")
        if case .selecting = editor.phase {
            for (index, title) in ["Region", "Freehand", "Window", "Monitor", "Full Desktop"].enumerated() {
                toolMenu.menu?.addItem(item(title, action: #selector(selectionChanged(_:)), tag: index))
            }
        } else {
            for (index, tool) in tools.enumerated() {
                let entry = item(tool.2, action: #selector(toolChanged(_:)), tag: index)
                entry.state = tool.0 == editor.tool ? .on : .off
                entry.image = NSImage(systemSymbolName: tool.1, accessibilityDescription: tool.2)
                toolMenu.menu?.addItem(entry)
            }
        }
        moreMenu.removeAllItems(); moreMenu.addItem(withTitle: "More")
        let undo = item("Undo", action: #selector(undo)), redo = item("Redo", action: #selector(redo)), delete = item("Delete selected", action: #selector(deleteSel))
        undo.isEnabled = editor.doc.history.canUndo; redo.isEnabled = editor.doc.history.canRedo; delete.isEnabled = editor.doc.selectedID != nil
        moreMenu.menu?.autoenablesItems = false
        for entry in [undo, redo, delete] { moreMenu.menu?.addItem(entry) }
        }
        doneButton.isEnabled = editor.session.canFinish
        statusLabel.stringValue = editor.session.status ?? ""
        statusLabel.isHidden = editor.session.status == nil
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
    @objc private func selectionChanged(_ item: NSMenuItem) {
        editor.session.activate(editor)
        if item.tag == 4 { editor.session.selectDesktop() }
        else { editor.session.chooseSelection([.rectangle, .lasso, .pickWindow, .pickMonitor][item.tag]) }
    }
    @objc private func toolChanged(_ item: NSMenuItem) { editor.setTool(tools[item.tag].0) }
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
    var e2eTools: NSPopUpButton { toolMenu }
    var e2eMore: NSPopUpButton { moreMenu }
    var e2eStyle: NSButton { styleButton }
    var e2eStyleContents: NSView { popover.contentViewController!.view }
    #endif
}
