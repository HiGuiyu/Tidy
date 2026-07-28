import AppKit

/// 读取 Finder 当前选中的文件(⌥⌘A 入口)。首次使用会触发系统「自动化」授权弹窗。
enum FinderSelection {
    enum Outcome {
        case files([URL])
        case permissionDenied   // 用户在系统设置里拒绝了自动化权限
        case scriptError(String)
    }

    static func fetch() -> Outcome {
        var error: NSDictionary?
        let urls = run(&error)
        if let error {
            let code = (error["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if code == -1743 || code == -600 {   // errAEEventNotPermitted / Finder 未运行
                return .permissionDenied
            }
            return .scriptError("\(error["NSAppleScriptErrorMessage"] as? String ?? "\(code)")")
        }
        return .files(urls)
    }

    static func selectedFiles() -> [URL] {
        var error: NSDictionary?
        return run(&error)
    }

    private static func run(_ error: inout NSDictionary?) -> [URL] {
        let source = """
        tell application "Finder"
            set theSel to selection
            set thePaths to {}
            repeat with anItem in theSel
                try
                    set end of thePaths to POSIX path of (anItem as alias)
                end try
            end repeat
            return thePaths
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [] }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            NSLog("TidyApp: 读取 Finder 选中失败 \(error)")
            return []
        }
        var urls: [URL] = []
        if descriptor.numberOfItems > 0 {
            for i in 1...descriptor.numberOfItems {
                if let path = descriptor.atIndex(i)?.stringValue {
                    urls.append(URL(fileURLWithPath: path))
                }
            }
        } else if let single = descriptor.stringValue, !single.isEmpty {
            urls.append(URL(fileURLWithPath: single))
        }
        return urls
    }
}
