import AppKit
@preconcurrency import ScreenCaptureKit
import ShareXAgent

@MainActor
final class CaptureTargets {
    private struct Identity: Equatable {
        let kind: TargetKind
        let nativeID: UInt32
        let owner: String
        let width: Double
        let height: Double
        let scale: Double
        let displayFrame: CGRect?
    }
    private struct Entry { let target: CaptureTarget; let identity: Identity }
    private var entries: [String: Entry] = [:]
    private let maximumTargets = 2048
    #if FRAME_GAP_PROBE
    weak var probeOperations: FrameGapOperationLog?
    #endif

    struct Resolved {
        let target: CaptureTarget
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let scale: Double
    }

    func list() async throws -> [CaptureTarget] {
        let content = try await content()
        let candidates = current(content)
        var next: [String: Entry] = [:]
        for candidate in candidates.prefix(maximumTargets) {
            let old = entries.first { $0.value.identity == candidate.identity }
            let token = old?.key ?? UUID().uuidString
            let value = CaptureTarget(token: token, kind: candidate.identity.kind, name: candidate.name,
                application: candidate.application, widthPoints: candidate.identity.width,
                heightPoints: candidate.identity.height, pixelScale: candidate.identity.scale)
            next[token] = Entry(target: value, identity: candidate.identity)
        }
        entries = next
        return next.values.map(\.target).sorted {
            if $0.kind != $1.kind { return $0.kind == .display }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func resolve(_ selection: CaptureSelection, recording: Bool = false) async throws -> Resolved {
        guard let entry = entries[selection.target] else {
            throw AgentFailure(.targetNotFound, "The target token expired. List the targets again and select a current target.")
        }
        let content = try await content()
        guard let candidate = current(content, matching: entry.identity).first else {
            throw AgentFailure(.targetNotFound, "The selected target is no longer available.")
        }
        guard candidate.identity == entry.identity else {
            throw AgentFailure(.targetChanged, "The target identity, size, or scale changed. List the targets again and select it.")
        }
        let filter: SCContentFilter
        switch entry.identity.kind {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == entry.identity.nativeID }) else {
                throw AgentFailure(.targetNotFound, "The selected display disconnected.")
            }
            let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            #if FRAME_GAP_PROBE
            probeOperations?.record("target.resolve.filter", "begin")
            #endif
            filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            #if FRAME_GAP_PROBE
            probeOperations?.record("target.resolve.filter", "end")
            #endif
        case .window:
            guard selection.region == nil else { throw AgentFailure(.invalidRequest, "Regions require a display target.") }
            guard let window = content.windows.first(where: { $0.windowID == entry.identity.nativeID }) else {
                throw AgentFailure(.targetNotFound, "The selected window closed.")
            }
            #if FRAME_GAP_PROBE
            probeOperations?.record("target.resolve.filter", "begin")
            #endif
            filter = SCContentFilter(desktopIndependentWindow: window)
            #if FRAME_GAP_PROBE
            probeOperations?.record("target.resolve.filter", "end")
            #endif
        }
        let config = SCStreamConfiguration()
        config.showsCursor = selection.includeCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false
        var size = CGSize(width: entry.identity.width, height: entry.identity.height)
        if let region = selection.region {
            try CaptureGeometry.validate(region: region, target: entry.target)
            config.sourceRect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
            size = config.sourceRect.size
        }
        guard let pixels = Imaging.pixelDimensions(size: size, scale: entry.identity.scale) else {
            throw AgentFailure(.captureFailed, "The target exceeds the image allocation limit.")
        }
        if recording {
            let output = try CaptureGeometry.recordingSize(widthPixels: pixels.width, heightPixels: pixels.height)
            config.width = output.width
            config.height = output.height
            #if FRAME_GAP_PROBE
            config.queueDepth = ProcessInfo.processInfo.environment["SHAREX_FRAME_GAP_DEEPER_QUEUE"] == "1" ? 5 : 3
            config.pixelFormat = ProcessInfo.processInfo.environment["SHAREX_FRAME_GAP_NV12"] == "1"
                ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
            #else
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA
            #endif
        } else { config.width = pixels.width; config.height = pixels.height }
        return Resolved(target: entry.target, filter: filter, configuration: config, scale: entry.identity.scale)
    }

    private struct Candidate { let identity: Identity; let name: String; let application: String? }

    private func current(_ content: SCShareableContent, matching identity: Identity? = nil) -> [Candidate] {
        var values: [Candidate] = content.displays.compactMap { display in
            if let identity, identity.kind != .display || identity.nativeID != display.displayID { return nil }
            guard let screen = NSScreen.screens.first(where: { ScreenCapture.displayID(of: $0) == display.displayID }) else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(display.displayID)?.takeRetainedValue()
            let owner = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? "display-\(display.displayID)"
            return Candidate(identity: Identity(kind: .display, nativeID: display.displayID, owner: owner,
                width: Double(display.width), height: Double(display.height), scale: Double(screen.backingScaleFactor),
                displayFrame: display.frame), name: screen.localizedName, application: nil)
        }
        values += content.windows.compactMap { window in
            if let identity, identity.kind != .window || identity.nativeID != window.windowID { return nil }
            guard window.isOnScreen, window.windowLayer == 0, window.frame.width > 1, window.frame.height > 1,
                  let app = window.owningApplication, app.processID != ProcessInfo.processInfo.processIdentifier,
                  let running = NSRunningApplication(processIdentifier: app.processID) else { return nil }
            let owner = "\(app.processID):\(app.bundleIdentifier):\(running.launchDate?.timeIntervalSince1970 ?? 0)"
            #if FRAME_GAP_PROBE
            probeOperations?.record("target.current.filter", "begin")
            #endif
            let filter = SCContentFilter(desktopIndependentWindow: window)
            #if FRAME_GAP_PROBE
            probeOperations?.record("target.current.filter", "end")
            #endif
            return Candidate(identity: Identity(kind: .window, nativeID: window.windowID, owner: owner,
                width: window.frame.width, height: window.frame.height, scale: Double(filter.pointPixelScale), displayFrame: nil),
                name: window.title?.isEmpty == false ? String(window.title!.prefix(512)) : app.applicationName,
                application: app.applicationName)
        }
        return values
    }

    private func content() async throws -> SCShareableContent {
        #if FRAME_GAP_PROBE
        let probe = probeOperations
        probe?.record("target.preflight", "begin")
        #endif
        #if FRAME_GAP_PROBE
        let granted = FrameGapHistory.permission("target")
        #else
        let granted = CGPreflightScreenCaptureAccess()
        #endif
        #if FRAME_GAP_PROBE
        probe?.record("target.preflight", "end")
        #endif
        guard granted else { throw AgentFailure(.permissionDenied, "Grant ShareX Screen Recording permission in System Settings, then restart ShareX if required.") }
        do {
            #if FRAME_GAP_PROBE
            probe?.record("target.content", "begin")
            defer { probe?.record("target.content", "end") }
            #endif
            let box = try await AgentCaptureDeadline.run {
                ContentBox(content: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
            }
            return box.content
        }
        catch { throw AgentFailure(.captureFailed, "Cannot read capture targets: \(error.localizedDescription)") }
    }

    private struct ContentBox: @unchecked Sendable { let content: SCShareableContent }
}
