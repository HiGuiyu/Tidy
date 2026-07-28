import Foundation

/// 启动自检(§11.4):任一失败给出明确报错而非静默降级
enum SelfCheck {
    struct Result {
        let name: String
        let ok: Bool
        let detail: String
    }

    static func run(env: EnvConfig) async -> [Result] {
        var results: [Result] = []

        // 1. .env:没配过 AI = 本地模式,是正常状态不是错误;配了一半才算错
        if env.isUnconfigured {
            results.append(Result(name: "AI 配置", ok: true,
                                  detail: "未配置——本地模式运行(分类靠规则+记忆;菜单「AI 设置」可开启)"))
        } else if !env.isComplete {
            results.append(Result(name: "AI 配置", ok: false,
                                  detail: "OPENAI_BASE_URL / OPENAI_API_KEY / OPENAI_MODEL 填了一部分,请补全或全部留空"))
        } else {
            results.append(Result(name: "AI 配置", ok: true, detail: "模型:\(env.model ?? "")"))
        }

        // 2+3. 网关连通 + 模型名区分大小写在列(§10.1 的 502 坑)
        if env.isComplete, let client = OpenAIClient(config: env) {
            do {
                let models = try await client.listModels()
                results.append(Result(name: "网关连通", ok: true, detail: "\(models.count) 个模型可用"))
                if let m = env.model, models.contains(m) {
                    results.append(Result(name: "模型名校验", ok: true, detail: m))
                } else {
                    let hint = models.first { $0.lowercased() == env.model?.lowercased() }
                        .map { ",是否想写 \($0)?(该网关对大小写敏感,错误时返回 502)" } ?? ""
                    results.append(Result(name: "模型名校验", ok: false,
                                          detail: "\(env.model ?? "?") 不在网关模型列表中\(hint)"))
                }
            } catch {
                results.append(Result(name: "网关连通", ok: false, detail: error.localizedDescription))
            }
        }

        // 4. PARA 根目录存在且可写
        let para = ParaTree.root
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: para.path, isDirectory: &isDir)
        if exists && isDir.boolValue && FileManager.default.isWritableFile(atPath: para.path) {
            results.append(Result(name: "PARA 目录", ok: true, detail: para.path))
        } else {
            results.append(Result(name: "PARA 目录", ok: false, detail: "\(para.path) 不存在或不可写"))
        }

        return results
    }

    static func summaryLine(_ results: [Result]) -> String {
        let failed = results.filter { !$0.ok }
        return failed.isEmpty ? "自检:全部通过 ✓" : "自检:\(failed.count) 项异常 ⚠️"
    }

    static func detailText(_ results: [Result]) -> String {
        results.map { "\($0.ok ? "✅" : "❌") \($0.name):\($0.detail)" }.joined(separator: "\n")
    }
}
