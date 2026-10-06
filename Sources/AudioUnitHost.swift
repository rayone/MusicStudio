import Foundation
import AVFoundation
import CoreAudioKit
import AppKit

/// Discovers installed Audio Unit effects and matches a .component bundle path to a
/// loadable AVAudioUnitComponent. AVAudioEngine can host AU (not VST3), so this is the
/// real-time preview path.
@MainActor
public enum AudioUnitHost {
    /// All installed effect-type Audio Units (aufx) on this machine.
    public static func installedEffects() -> [AVAudioUnitComponent] {
        let mgr = AVAudioUnitComponentManager.shared()
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = 0
        desc.componentManufacturer = 0
        return mgr.components(matching: desc)
    }

    /// Resolve a user-picked .component bundle to an installed AU component.
    ///
    /// Reads the bundle's own `AudioComponents` (type/subtype/manufacturer) and queries
    /// for exactly that description. This finds plugins installed after the app launched,
    /// where a cached name/URL scan can miss them. Falls back to URL then name matching.
    public static func component(forPath path: String) -> AVAudioUnitComponent? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "component" else { return nil }
        let mgr = AVAudioUnitComponentManager.shared()

        for desc in descriptions(inBundle: url) {
            if let found = mgr.components(matching: desc).first { return found }
        }

        let effects = installedEffects()
        if let exact = effects.first(where: {
            $0.componentURL?.standardizedFileURL == url.standardizedFileURL
        }) { return exact }
        let bundleName = url.deletingPathExtension().lastPathComponent.lowercased()
        return effects.first(where: {
            $0.name.lowercased().contains(bundleName) || bundleName.contains($0.name.lowercased())
        })
    }

    /// The AudioComponentDescription to instantiate for a .component bundle. Uses the
    /// installed-component list when it knows the plugin, otherwise the bundle's own
    /// Info.plist, so plugins installed while the app is running still load.
    public static func description(forPath path: String) -> AudioComponentDescription? {
        if let comp = component(forPath: path) { return comp.audioComponentDescription }
        return descriptions(inBundle: URL(fileURLWithPath: path)).first
    }

    /// AudioComponentDescriptions declared in a .component bundle's Info.plist.
    static func descriptions(inBundle url: URL) -> [AudioComponentDescription] {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any],
              let comps = dict["AudioComponents"] as? [[String: Any]] else { return [] }
        return comps.compactMap { c in
            guard let type = fourCC(c["type"]), let sub = fourCC(c["subtype"]),
                  let mfr = fourCC(c["manufacturer"]) else { return nil }
            return AudioComponentDescription(componentType: type, componentSubType: sub,
                                             componentManufacturer: mfr,
                                             componentFlags: 0, componentFlagsMask: 0)
        }
    }

    /// Convert a 4-char code string like "aufx" to its OSType value.
    private static func fourCC(_ any: Any?) -> OSType? {
        guard let s = any as? String, s.utf8.count == 4 else { return nil }
        return s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    /// Human label for the engine mode a given plugin path can use.
    public static func isAudioUnit(path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "component"
    }

    /// The same plugin in the other format (AU <-> VST3), if installed alongside.
    /// Plugins usually ship both with identical bundle names in the standard folders.
    public static func sibling(of path: String, ext: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let folder = ext == "vst3" ? "VST3" : "Components"
        let roots = ["/Library/Audio/Plug-Ins",
                     NSHomeDirectory() + "/Library/Audio/Plug-Ins"]
        for root in roots {
            let candidate = "\(root)/\(folder)/\(name).\(ext)"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Presents an Audio Unit's native Cocoa editor in a floating NSWindow, falling back to
/// a message when the plugin ships no view.
@MainActor
public final class AudioUnitWindowController {
    private var window: NSWindow?

    public init() {}

    /// Show the plugin's own interface. Reuses the open window for the same plugin; when the
    /// plugin has no editor, only alerts if the user explicitly asked (`alertIfNoEditor`).
    public func show(for audioUnit: AVAudioUnit, title: String, alertIfNoEditor: Bool) {
        if let win = window, win.isVisible, win.title == title {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let au = audioUnit.auAudioUnit
        au.requestViewController { [weak self] viewController in
            Task { @MainActor in
                guard let self else { return }
                guard let vc = viewController else {
                    if alertIfNoEditor { self.showFallback(title: title) }
                    return
                }
                self.present(viewController: vc, title: title)
            }
        }
    }

    private func present(viewController vc: NSViewController, title: String) {
        // Many AU editors report no preferred size; use the view's own frame/fitting size.
        var size = vc.preferredContentSize
        if size.width < 50 || size.height < 50 { size = vc.view.frame.size }
        if size.width < 50 || size.height < 50 { size = vc.view.fittingSize }
        if size.width < 50 || size.height < 50 { size = NSSize(width: 640, height: 420) }
        let win = window ?? NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = title
        win.contentViewController = vc
        win.setContentSize(size)
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        self.window = win
    }

    private func showFallback(title: String) {
        let alert = NSAlert()
        alert.messageText = "\(title) has no custom editor"
        alert.informativeText = "This plugin doesn't provide its own window. Use the parameter controls in the inspector to adjust it."
        alert.alertStyle = .informational
        alert.runModal()
    }

    public func close() {
        window?.close()
        window = nil
    }
}
