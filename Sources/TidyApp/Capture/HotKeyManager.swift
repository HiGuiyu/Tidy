import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 双击 ⌘ 唤出捕获:零记忆成本的第一入口。
/// 全局监听需要辅助功能权限;App 自身激活时走本地监听(无需权限)。
@MainActor
final class DoubleTapCommand {
    static let shared = DoubleTapCommand()

    var onDoubleTap: (() -> Void)?

    private var monitors: [Any] = []
    private var lastCmdPress: TimeInterval = 0
    private var cmdWasDown = false
    private var dirty = false     // 两次按下之间出现过其他按键/组合键 → 不算双击

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    func start() {
        stop()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown],
                                                     handler: { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown],
                                                    handler: { [weak self] e in
            self?.handle(e)
            return e
        }) { monitors.append(l) }
    }

    private func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown {
            dirty = true          // ⌘C 之类的组合键不触发
            return
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdDown = flags.contains(.command)
        let onlyCmd = flags.subtracting(.command).isEmpty
        if cmdDown && !cmdWasDown {
            let now = ProcessInfo.processInfo.systemUptime
            if onlyCmd, !dirty, now - lastCmdPress < 0.38 {
                lastCmdPress = 0
                onDoubleTap?()
            } else {
                lastCmdPress = now
            }
            dirty = !onlyCmd
        }
        cmdWasDown = cmdDown
    }
}

/// 全局快捷键(§10.2)。用 Carbon RegisterEventHotKey,无需 Accessibility 权限。
final class HotKeyManager {
    static let shared = HotKeyManager()

    enum Action: UInt32, CaseIterable {
        case archive = 1   // ⌥⌘A
        case capture = 2   // ⌥⌘N
        case workbench = 3 // ⌥⌘P
        case undo = 4      // ⌥⌘Z
        case clarify = 5   // ⌥⌘I(Inbox 理清)
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?

    func registerAll(archive: @escaping () -> Void,
                     capture: @escaping () -> Void,
                     workbench: @escaping () -> Void,
                     undo: @escaping () -> Void,
                     clarify: @escaping () -> Void) {
        handlers[Action.archive.rawValue] = archive
        handlers[Action.capture.rawValue] = capture
        handlers[Action.workbench.rawValue] = workbench
        handlers[Action.undo.rawValue] = undo
        handlers[Action.clarify.rawValue] = clarify

        installHandlerIfNeeded()

        let mods = UInt32(optionKey | cmdKey)
        register(action: .archive, keyCode: UInt32(kVK_ANSI_A), modifiers: mods)
        register(action: .capture, keyCode: UInt32(kVK_ANSI_N), modifiers: mods)
        register(action: .workbench, keyCode: UInt32(kVK_ANSI_P), modifiers: mods)
        register(action: .undo, keyCode: UInt32(kVK_ANSI_Z), modifiers: mods)
        register(action: .clarify, keyCode: UInt32(kVK_ANSI_I), modifiers: mods)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.handlers[hkID.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func register(action: Action, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x54494459) /* 'TIDY' */, id: action.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRefs.append(ref) }
        else { NSLog("TidyApp: 快捷键注册失败 action=\(action) status=\(status)") }
    }
}
