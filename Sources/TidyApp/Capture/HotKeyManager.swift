import AppKit
import Carbon.HIToolbox

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
