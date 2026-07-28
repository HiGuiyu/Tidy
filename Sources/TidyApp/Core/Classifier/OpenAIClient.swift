import Foundation

/// OpenAI 兼容客户端(§10.1):chat/completions + json_schema strict。
/// 请求经第三方网关转发;模型名区分大小写(网关的 502 坑)。
final class OpenAIClient {
    let config: EnvConfig
    private let session: URLSession

    init?(config: EnvConfig) {
        guard config.isComplete else { return nil }
        self.config = config
        let sc = URLSessionConfiguration.ephemeral
        sc.timeoutIntervalForRequest = 20
        session = URLSession(configuration: sc)
    }

    private func url(_ path: String) -> URL? {
        guard let base = config.baseURL else { return nil }
        return URL(string: base.hasSuffix("/") ? base + path : base + "/" + path)
    }

    // MARK: - GET /models(启动自检用)

    func listModels() async throws -> [String] {
        guard let u = url("models") else { throw AIError.badConfig }
        var req = URLRequest(url: u)
        req.setValue("Bearer \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        struct ModelList: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        return try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id)
    }

    // MARK: - 分类(structured outputs,strict:true)

    struct AICandidate: Decodable {
        let path: String
        let confidence: Double
        let reason: String
    }

    struct ClassifyContext {
        var fileName: String
        var fileSize: Int64
        var contentSnippet: String?      // 重档才带内容
        var destinations: [String]
        var memoryRules: [String]
        var recentDecisions: [String]
        var activeProjectPath: String?
    }

    func classify(_ ctx: ClassifyContext, heavy: Bool = false) async throws -> [AICandidate] {
        guard let u = url("chat/completions") else { throw AIError.badConfig }
        let model = (heavy ? config.effectiveHeavyModel : config.model) ?? ""

        var userLines: [String] = []
        userLines.append("待归档文件:\(ctx.fileName)(\(ByteCountFormatter.string(fromByteCount: ctx.fileSize, countStyle: .file)))")
        if let snippet = ctx.contentSnippet, !snippet.isEmpty {
            userLines.append("文件内容摘录:\n\(snippet.prefix(2000))")
        }
        if let active = ctx.activeProjectPath {
            userLines.append("用户当前正聚焦于项目:\(active)(若相关,应优先考虑)")
        }
        if !ctx.memoryRules.isEmpty {
            userLines.append("已知归档规则(按可信度排序):\n" + ctx.memoryRules.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !ctx.recentDecisions.isEmpty {
            userLines.append("最近的归档决定:\n" + ctx.recentDecisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        userLines.append("可选归档位置(path 必须从下面这个列表里逐字选取):\n" + ctx.destinations.joined(separator: "\n"))

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "candidates": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string"],
                            "confidence": ["type": "number"],
                            "reason": ["type": "string"],
                        ],
                        "required": ["path", "confidence", "reason"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["candidates"],
            "additionalProperties": false,
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content":
                    "你是 macOS 文件归档助手,基于 PARA 方法(1-Projects 有终点的项目 / 2-Areas 持续维护的领域 / 3-Resources 参考资料 / 4-Archive 已完结)。" +
                    "根据文件名、内容与用户的历史规则,从给定位置列表中选出最合适的至多 3 个归档位置,按置信度降序。" +
                    "confidence 取 0~1;reason 用一句简短中文说明判断依据。path 必须逐字来自列表,不得虚构。"],
                ["role": "user", "content": userLines.joined(separator: "\n\n")],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "archive_candidates", "strict": true, "schema": schema],
            ],
        ]

        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
            }
            let choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw AIError.emptyResponse
        }
        struct Result: Decodable { let candidates: [AICandidate] }
        // strict 模式已验证可用;解析失败仅作兜底,不重试(§10.1 实现决策)
        return try JSONDecoder().decode(Result.self, from: jsonData).candidates
    }

    // MARK: - 通用 structured output 请求

    private struct ChatEnvelope: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg
        }
        let choices: [Choice]
    }

    private func structured<T: Decodable>(_ type: T.Type, system: String, user: String,
                                          schemaName: String, schema: [String: Any]) async throws -> T {
        guard let u = url("chat/completions") else { throw AIError.badConfig }
        let body: [String: Any] = [
            "model": config.model ?? "",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": schemaName, "strict": true, "schema": schema],
            ],
        ]
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let content = try JSONDecoder().decode(ChatEnvelope.self, from: data).choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw AIError.emptyResponse
        }
        return try JSONDecoder().decode(T.self, from: jsonData)
    }

    // MARK: - GTD 理清草稿(§4.4:AI 出草稿,用户只做确认)

    struct ClarifyDraft: Codable {
        let isActionable: Bool
        let nextAction: String
        let expectedOutcome: String  // 任务 = 行动 + 期望结果
        let list: String             // action | waiting | someday
        let waitingFor: String       // 等待清单:等谁/等什么;否则空串
        let projectPath: String      // 空串 = 不关联
        let important: Bool
        let urgent: Bool
        let remindDate: String       // "yyyy-MM-dd HH:mm" 或空串
        let twoMinutes: Bool         // 2 分钟内能解决?
        let reason: String
    }

    func clarify(text: String, projectPaths: [String], activeProjectPath: String?) async throws -> ClarifyDraft {
        var lines = ["用户刚捕获的内容:\n\(text.prefix(1000))",
                     "现在时间:\(Self.nowString())"]
        if let active = activeProjectPath {
            lines.append("捕获时用户正聚焦于项目:\(active)(若相关,应优先关联)")
        }
        lines.append(projectPaths.isEmpty
            ? "当前没有任何项目,projectPath 返回空字符串。"
            : "现有项目列表(projectPath 必须逐字来自列表,或返回空字符串表示不关联):\n" + projectPaths.joined(separator: "\n"))

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "isActionable": ["type": "boolean"],
                "nextAction": ["type": "string"],
                "expectedOutcome": ["type": "string"],
                "list": ["type": "string", "enum": ["action", "waiting", "someday"]],
                "waitingFor": ["type": "string"],
                "projectPath": ["type": "string"],
                "important": ["type": "boolean"],
                "urgent": ["type": "boolean"],
                "remindDate": ["type": "string"],
                "twoMinutes": ["type": "boolean"],
                "reason": ["type": "string"],
            ],
            "required": ["isActionable", "nextAction", "expectedOutcome", "list", "waitingFor",
                         "projectPath", "important", "urgent", "remindDate", "twoMinutes", "reason"],
            "additionalProperties": false,
        ]
        return try await structured(ClarifyDraft.self, system:
            "你是 GTD 理清助手,区分「想法」与「任务」。任务 = 具体行动 + 期望结果。" +
            "isActionable:是否可执行。可执行时给出具体到单个动作的 nextAction(如「发邮件给张三要接入文档」,不要写宽泛目标)" +
            "与 expectedOutcome(做完后的可见结果)。" +
            "list 路由:action=自己下一步就能做;waiting=已委派或等外部条件(此时 waitingFor 写等谁/等什么);" +
            "someday=现在不做、将来也许(纯想法/孵化)。" +
            "important=对长期目标有影响;urgent=有时间压力。" +
            "文本里提到具体时间(如「周五下午3点」)则换算为 remindDate(格式 yyyy-MM-dd HH:mm,基于现在时间推算),没提到则空串。" +
            "twoMinutes:这件事 2 分钟内能否解决(GTD 两分钟规则,能解决就该立即做)。" +
            "全部中文字段用简体中文,不可执行时 nextAction/expectedOutcome 返回空串。",
            user: lines.joined(separator: "\n\n"),
            schemaName: "clarify_draft", schema: schema)
    }

    // MARK: - 自然计划法拆解(目的→期望结果→头脑风暴→组织计划)

    struct PlanDraft: Decodable {
        struct Step: Decodable {
            let action: String
            let timeHint: String   // 建议时间,如 "2026-07-29" 或 "本周内" 或空串
            let order: Int         // 逻辑顺序,1 起
        }
        let purpose: String        // 1 明确目的:为什么做
        let outcome: String        // 2 期望结果:做成什么样
        let brainstorm: [String]   // 3 头脑风暴:相关考虑点
        let steps: [Step]          // 4 组织计划:按逻辑排序的可执行步骤
    }

    func plan(goal: String, projectName: String, existingActions: [String]) async throws -> PlanDraft {
        var lines = ["项目:\(projectName)", "要拆解的任务/目标:\n\(goal.prefix(800))",
                     "现在时间:\(Self.nowString())"]
        if !existingActions.isEmpty {
            lines.append("该项目已有的行动(不要重复):\n" + existingActions.prefix(8).map { "- \($0)" }.joined(separator: "\n"))
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "purpose": ["type": "string"],
                "outcome": ["type": "string"],
                "brainstorm": ["type": "array", "items": ["type": "string"]],
                "steps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "action": ["type": "string"],
                            "timeHint": ["type": "string"],
                            "order": ["type": "integer"],
                        ],
                        "required": ["action", "timeHint", "order"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["purpose", "outcome", "brainstorm", "steps"],
            "additionalProperties": false,
        ]
        return try await structured(PlanDraft.self, system:
            "你是 GTD 自然计划法助手,把任务拆解为可执行计划,分四步输出:" +
            "purpose(一句话:为什么要做这件事);outcome(期望结果:做完后可验证的样子);" +
            "brainstorm(3-6 条要考虑的点:风险/依赖/资源);" +
            "steps(3-8 步,每步是具体到单个动作的下一步行动,按逻辑先后排序,order 从 1 起;" +
            "有天然时间点的步骤在 timeHint 给建议日期 yyyy-MM-dd,否则空串)。全部用简体中文。",
            user: lines.joined(separator: "\n\n"),
            schemaName: "plan_draft", schema: schema)
    }

    private static func nowString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: Date())
    }

    enum AIError: LocalizedError {
        case badConfig
        case http(Int, String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .badConfig: return ".env 配置不完整"
            case .http(let code, let body): return "网关返回 HTTP \(code):\(body)"
            case .emptyResponse: return "模型返回为空"
            }
        }
    }
}
