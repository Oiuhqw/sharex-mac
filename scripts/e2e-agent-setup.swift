import AppKit
import ApplicationServices
import Foundation

private enum GateError: Error {
    case failed(String)
    case blocked(String)
}

@MainActor
private final class AccessibilityDriver {
    let application: AXUIElement
    let deadline = Date().addingTimeInterval(12)

    init(pid: pid_t) throws {
        guard AXIsProcessTrusted() else {
            throw GateError.blocked("Grant Accessibility permission to this helper executable before evaluation.")
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw GateError.failed("The owned ShareX process is not running.")
        }
        application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        app.activate(options: [])
    }

    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.3)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    func text(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }

    func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return result as! AXUIElement
    }

    func actions(_ element: AXUIElement) -> [String] {
        guard Date() < deadline else { return [] }
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return names as? [String] ?? []
    }

    func tree() -> [AXUIElement] {
        var pending = [application]
        var visited: [AXUIElement] = []
        while !pending.isEmpty, visited.count < 1800, Date() < deadline {
            let current = pending.removeLast()
            guard !visited.contains(where: { CFEqual($0, current) }) else { continue }
            visited.append(current)
            for attribute in ["AXChildren", "AXWindows", "AXMenuBar", "AXExtrasMenuBar"] {
                if let children = value(current, attribute) as? [AXUIElement] {
                    pending.append(contentsOf: children)
                } else if let child = element(current, attribute) {
                    pending.append(child)
                }
            }
        }
        return visited
    }

    func record(_ element: AXUIElement, includeContent: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["role": text(element, "AXRole"), "identifier": text(element, "AXIdentifier"),
                                   "title": text(element, "AXTitle"), "description": text(element, "AXDescription"),
                                   "actions": actions(element)]
        for attribute in ["AXValue", "AXEnabled", "AXSelected"] {
            if let number = value(element, attribute) as? NSNumber { result[attribute] = number }
            else if let string = value(element, attribute) as? String { result[attribute] = string }
        }
        guard includeContent else { return result }
        var pending = [element]
        var labels: [String] = []
        var count = 0
        while !pending.isEmpty, count < 100, Date() < deadline {
            let child = pending.removeLast()
            count += 1
            for attribute in ["AXTitle", "AXDescription", "AXValue"] {
                let label = text(child, attribute)
                if !label.isEmpty, !labels.contains(label) { labels.append(label) }
            }
            pending.append(contentsOf: value(child, "AXChildren") as? [AXUIElement] ?? [])
        }
        result["content"] = labels.joined(separator: " ")
        return result
    }

    func snapshot() -> [[String: Any]] { tree().map { record($0) } }

    func find(identifier: String) throws -> AXUIElement {
        repeat {
            let matches = tree().filter { text($0, "AXIdentifier") == identifier }
            guard matches.count <= 1 else {
                throw GateError.failed("Expected one Accessibility element for \(identifier), found \(matches.count).")
            }
            if let match = matches.first { return match }
            RunLoop.current.run(until: min(Date().addingTimeInterval(0.1), deadline))
        } while Date() < deadline
        throw GateError.failed("Expected one Accessibility element for \(identifier), found 0 before the deadline.")
    }

    func ancestors(_ target: AXUIElement) -> [AXUIElement] {
        var result = [target]
        while result.count < 24, let parent = element(result.last!, "AXParent"),
              !result.contains(where: { CFEqual($0, parent) }), !CFEqual(parent, application) {
            result.append(parent)
        }
        return result
    }

    func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    func reveal(_ target: AXUIElement) {
        if actions(target).contains("AXScrollToVisible"),
           AXUIElementPerformAction(target, "AXScrollToVisible" as CFString) == .success { return }
        guard let scroll = ancestors(target).first(where: { text($0, "AXRole") == "AXScrollArea" }),
              let bar = element(scroll, "AXVerticalScrollBar") else { return }
        for offset in stride(from: 0.0, through: 1.0, by: 0.1) {
            if let bounds = frame(scroll), let targetFrame = frame(target),
               bounds.insetBy(dx: 0, dy: 4).contains(CGPoint(x: targetFrame.midX, y: targetFrame.midY)) { return }
            guard Date() < deadline else { return }
            _ = AXUIElementSetAttributeValue(bar, "AXValue" as CFString, NSNumber(value: offset))
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
    }

    func press(_ target: AXUIElement, select: Bool = false) throws {
        reveal(target)
        let path = ancestors(target)
        for candidate in path {
            if select {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(candidate, "AXSelected" as CFString, &settable) == .success,
                   settable.boolValue,
                   AXUIElementSetAttributeValue(candidate, "AXSelected" as CFString, kCFBooleanTrue) == .success { return }
                for (attribute, membersAttribute) in [("AXSelectedRows", "AXRows"), ("AXSelectedChildren", "AXChildren")] {
                    if AXUIElementIsAttributeSettable(candidate, attribute as CFString, &settable) == .success,
                       settable.boolValue, let members = value(candidate, membersAttribute) as? [AXUIElement],
                       let member = path.first(where: { node in members.contains(where: { CFEqual($0, node) }) }),
                       AXUIElementSetAttributeValue(candidate, attribute as CFString, [member] as CFArray) == .success { return }
                }
            }
            if actions(candidate).contains("AXPress") {
                guard (value(candidate, "AXEnabled") as? NSNumber)?.boolValue != false else {
                    throw GateError.failed("The requested Accessibility control is disabled.")
                }
                let status = AXUIElementPerformAction(candidate, "AXPress" as CFString)
                guard status == .success else { throw GateError.failed("AXPress failed with code \(status.rawValue).") }
                return
            }
        }
        throw GateError.failed("The requested control has no supported Accessibility action.")
    }

    func menu(_ title: String) throws {
        guard let extras = element(application, "AXExtrasMenuBar") else {
            throw GateError.failed("The owned app has no Accessibility status menu bar.")
        }
        let items = value(extras, "AXChildren") as? [AXUIElement] ?? []
        let candidates = items.filter {
            text($0, "AXRole") == "AXMenuBarItem" &&
            [text($0, "AXTitle"), text($0, "AXDescription")].contains(where: { $0 == "ShareX" || $0 == "ShareX agent recording" })
        }
        guard candidates.count == 1 else { throw GateError.failed("The owned app has no unique ShareX status menu item.") }
        let statusItem = candidates[0]
        guard (value(statusItem, "AXEnabled") as? NSNumber)?.boolValue == true,
              actions(statusItem).contains("AXPress") else {
            throw GateError.failed("The ShareX status menu item is not enabled for AXPress.")
        }
        let openingStatus = AXUIElementPerformAction(statusItem, "AXPress" as CFString)
        guard openingStatus == .success || openingStatus == .cannotComplete else {
            throw GateError.failed("Status menu AXPress failed with code \(openingStatus.rawValue).")
        }
        // NSMenu tracking can outlast the AX reply timeout, so require the opened menu before continuing.
        repeat {
            if (value(statusItem, "AXSelected") as? NSNumber)?.boolValue == true {
                let menus = (value(statusItem, "AXChildren") as? [AXUIElement] ?? []).filter {
                    text($0, "AXRole") == "AXMenu"
                }
                guard menus.count <= 1 else { throw GateError.failed("The ShareX status item exposed multiple menus.") }
                if let menu = menus.first {
                    let matches = (value(menu, "AXChildren") as? [AXUIElement] ?? []).filter {
                        text($0, "AXRole") == "AXMenuItem" && text($0, "AXTitle") == title
                    }
                    guard matches.count <= 1 else { throw GateError.failed("The ShareX status menu exposed multiple \(title) items.") }
                    if let match = matches.first { try press(match); return }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw GateError.failed("The selected ShareX status menu did not expose \(title). Opening AXPress returned \(openingStatus.rawValue).")
    }
}

@main
@MainActor
private enum Main {
    static func main() {
        var output: [String: Any] = [:]
        var code: Int32 = 0
        var driver: AccessibilityDriver?
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count.isMultiple(of: 2) else { throw GateError.failed("Arguments must be --name value pairs.") }
            var options: [String: String] = [:]
            for index in stride(from: 0, to: arguments.count, by: 2) { options[arguments[index]] = arguments[index + 1] }
            guard let action = options["--action"] else { throw GateError.failed("--action is required.") }
            if action == "preflight" {
                guard AXIsProcessTrusted() else { throw GateError.blocked("Accessibility permission is missing for this helper executable.") }
                output = ["accessibilityTrusted": true, "screenRecordingGranted": CGPreflightScreenCaptureAccess()]
            } else if action == "pasteboard" {
                output = ["text": NSPasteboard.general.string(forType: .string) ?? "", "changeCount": NSPasteboard.general.changeCount]
            } else if action == "screenshot" {
                guard CGPreflightScreenCaptureAccess() else { throw GateError.blocked("Screen Recording permission is missing for screenshot evidence.") }
                guard let path = options["--output"], !FileManager.default.fileExists(atPath: path) else {
                    throw GateError.failed("Screenshot requires a new --output file.")
                }
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", path]
                capture.standardOutput = FileHandle.standardError
                try capture.run()
                let end = Date().addingTimeInterval(5)
                while capture.isRunning, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                if capture.isRunning {
                    kill(capture.processIdentifier, SIGKILL)
                    throw GateError.failed("Screenshot evidence timed out.")
                }
                guard capture.terminationStatus == 0, FileManager.default.fileExists(atPath: path) else {
                    throw GateError.failed("screencapture did not save screenshot evidence.")
                }
                output = ["path": path]
            } else {
                guard let rawPID = options["--pid"], let pid = Int32(rawPID), pid > 0 else {
                    throw GateError.failed("A positive owned --pid is required.")
                }
                let ax = try AccessibilityDriver(pid: pid)
                driver = ax
                switch action {
                case "snapshot": break
                case "press", "select", "inspect":
                    guard let identifier = options["--identifier"] else { throw GateError.failed("--identifier is required.") }
                    let target = try ax.find(identifier: identifier)
                    output["element"] = ax.record(target, includeContent: true)
                    if action != "inspect" { try ax.press(target, select: action == "select") }
                case "menu":
                    guard let title = options["--title"] else { throw GateError.failed("--title is required.") }
                    try ax.menu(title)
                default: throw GateError.failed("Unknown action \(action).")
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            output["status"] = "passed"
        } catch GateError.blocked(let reason) {
            output = ["status": "blocked", "reason": reason]
            code = 3
        } catch {
            let reason: String
            if case GateError.failed(let message) = error { reason = message } else { reason = error.localizedDescription }
            output = ["status": "failed", "reason": reason]
            code = 1
        }
        if let driver { output["elements"] = driver.snapshot() }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
        exit(code)
    }
}
