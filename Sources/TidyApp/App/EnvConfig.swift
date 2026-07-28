import Foundation

/// `~/.tidy/.env` 加载器(§10.1)。模型不硬编码,换模型只改 .env。
struct EnvConfig {
    var baseURL: String?
    var apiKey: String?
    var model: String?
    var modelHeavy: String?
    var paraRoot: String?    // 可选:自定义 PARA 根目录

    /// 三个 AI 变量全空 = 用户没配过 AI,纯本地模式(不是错误)
    var isUnconfigured: Bool {
        (baseURL ?? "").isEmpty && (apiKey ?? "").isEmpty && (model ?? "").isEmpty
    }

    static var tidyDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tidy")
    }
    static var envFile: URL { tidyDir.appendingPathComponent(".env") }

    var isComplete: Bool {
        guard let b = baseURL, let k = apiKey, let m = model else { return false }
        return !b.isEmpty && !k.isEmpty && !m.isEmpty
    }

    /// 重档模型未设置时回落到主模型
    var effectiveHeavyModel: String? { modelHeavy?.isEmpty == false ? modelHeavy : model }

    static func load() -> EnvConfig {
        var cfg = EnvConfig()
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else { return cfg }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // 去掉行尾注释与引号
            if let hash = value.firstIndex(of: "#"), !value.hasPrefix("\"") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "OPENAI_BASE_URL": cfg.baseURL = value
            case "OPENAI_API_KEY": cfg.apiKey = value
            case "OPENAI_MODEL": cfg.model = value
            case "OPENAI_MODEL_HEAVY": cfg.modelHeavy = value
            case "PARA_ROOT": cfg.paraRoot = value
            default: break
            }
        }
        return cfg
    }

    /// 生成配置模板(不覆盖已有文件),供「AI 设置」菜单打开编辑
    static func ensureTemplate() {
        guard !FileManager.default.fileExists(atPath: envFile.path) else { return }
        let template = """
        # Tidy 配置文件(保存后在菜单栏点「自检」重新加载)

        # ―― AI(OpenAI 兼容接口,留空则纯本地模式)――
        OPENAI_BASE_URL=https://api.openai.com/v1
        OPENAI_API_KEY=
        OPENAI_MODEL=gpt-4o-mini
        # 可选:长文档/OCR 用的重档模型,留空回落到 OPENAI_MODEL
        OPENAI_MODEL_HEAVY=

        # ―― 可选:自定义 PARA 根目录(默认 ~/Documents/PARA)――
        # PARA_ROOT=~/Documents/PARA
        """
        try? FileManager.default.createDirectory(at: tidyDir, withIntermediateDirectories: true)
        try? template.write(to: envFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
    }
}
