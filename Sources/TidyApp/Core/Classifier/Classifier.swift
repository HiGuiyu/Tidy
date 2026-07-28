import Foundation

/// 归档候选(面板行的来源)
struct Candidate: Identifiable {
    var id: String { relativePath }
    var relativePath: String
    var confidence: Double     // 0~1
    var reason: String
    var fromCloud: Bool = false
    var memoryIds: [Int64] = []   // 支撑该候选的记忆,用于 hit/miss 反馈
}

/// 分类引擎(§4.5.7 二维调档):
/// 本地层(文件名规则 + FTS5 记忆检索 + 活跃项目上下文)先出结果,云端按复杂度兜底。
final class Classifier {
    static let shared = Classifier()

    private let memory = MemoryStore.shared

    // MARK: - 本地层:同步、毫秒级,保证面板即开即用(原则 3:下限锁死)

    func localCandidates(fileName: String, destinations: [Destination], activeProjectPath: String?) -> [Candidate] {
        let nameLower = fileName.lowercased()
        let nameTokens = tokenSet(of: fileName)
        let memories = memory.search(fileName, kinds: ["semantic", "episodic"], limit: 10)

        var scores: [String: (score: Double, reasons: [String], memIds: [Int64])] = [:]

        func bump(_ path: String, _ delta: Double, _ reason: String, memId: Int64? = nil) {
            var entry = scores[path] ?? (0, [], [])
            entry.score += delta
            if !reason.isEmpty, !entry.reasons.contains(reason) { entry.reasons.append(reason) }
            if let m = memId { entry.memIds.append(m) }
            scores[path] = entry
        }

        for dest in destinations {
            guard dest.relativePath.contains("/") else { continue }  // 顶层目录不主动推荐
            // 1. 目录名与文件名的词面重合
            let leafTokens = tokenSet(of: dest.leafName)
            let overlap = nameTokens.intersection(leafTokens)
            if !overlap.isEmpty {
                let strength = min(0.55, Double(overlap.map(\.count).reduce(0, +)) * 0.12)
                bump(dest.relativePath, strength, "文件名与「\(dest.leafName)」相关")
            } else if dest.leafName.count >= 2, nameLower.contains(dest.leafName.lowercased()) {
                bump(dest.relativePath, 0.5, "文件名包含「\(dest.leafName)」")
            }
        }

        // 2. 记忆规则 / 历史归档提到的路径
        for m in memories {
            guard let dest = destinations.first(where: { m.content.contains($0.relativePath) || ( $0.relativePath.contains("/") && m.content.contains($0.leafName) ) }) else { continue }
            let weight = (m.kind == "semantic" ? 0.45 : 0.3) * m.confidence
            let label = m.kind == "semantic" ? "规则:\(m.content.prefix(24))" : "此前有类似文件归到这里"
            bump(dest.relativePath, weight, label, memId: m.id)
        }

        // 3. 聚焦中的项目加权(显式上下文信号,§4.2)
        if let active = activeProjectPath, destinations.contains(where: { $0.relativePath == active }) {
            bump(active, 0.3, "正在聚焦此项目")
        }

        let ranked = scores.sorted { $0.value.score > $1.value.score }.prefix(3)
        return ranked.compactMap { path, entry in
            guard entry.score > 0.08 else { return nil }
            return Candidate(relativePath: path,
                             confidence: min(0.95, entry.score),
                             reason: entry.reasons.prefix(2).joined(separator:";"),
                             fromCloud: false,
                             memoryIds: entry.memIds)
        }
    }

    /// 二维调档(§4.5.7):文件名清晰且命中规则 → 纯本地;否则云端轻档;长文档留重档(P2)
    func shouldCallCloud(localTop: Candidate?, cold: Bool) -> Bool {
        if cold { return true }                      // 冷启动期尽量借助云端
        guard let top = localTop else { return true }
        return top.confidence < 0.72
    }

    // MARK: - 云端层:异步 refine,结果到达时若面板仍开着则合并展示

    func cloudCandidates(fileURL: URL, destinations: [Destination], activeProjectPath: String?,
                         client: OpenAIClient) async throws -> [Candidate] {
        let name = fileURL.lastPathComponent
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        // 小文本文件带一段内容(轻档);OCR/长文档摘要属重档,P2 再做
        var snippet: String? = nil
        let textExts = ["txt", "md", "csv", "log", "json", "swift", "py", "html"]
        if textExts.contains(fileURL.pathExtension.lowercased()), size < 512_000,
           let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            snippet = String(text.prefix(1500))
        }
        let rules = memory.search(name, kinds: ["semantic", "procedural"], limit: 6).map(\.content)
        let ctx = OpenAIClient.ClassifyContext(
            fileName: name, fileSize: size, contentSnippet: snippet,
            destinations: destinations.map(\.relativePath),
            memoryRules: rules,
            recentDecisions: memory.recentDecisions(),
            activeProjectPath: activeProjectPath)
        let ai = try await client.classify(ctx)
        let valid = Set(destinations.map(\.relativePath))
        // 宽容映射:实测网关模型偶尔不逐字复制路径(如返回 "Areas/财务"),按后缀/包含关系归位
        func resolve(_ path: String) -> String? {
            if valid.contains(path) { return path }
            let p = path.trimmingCharacters(in: .whitespaces)
            return destinations.first {
                $0.relativePath.hasSuffix(p) || p.hasSuffix($0.relativePath) || $0.relativePath.contains(p)
            }?.relativePath
        }
        var seen = Set<String>()
        var mapped: [Candidate] = []
        for a in ai {
            guard let path = resolve(a.path), !seen.contains(path) else { continue }
            seen.insert(path)
            mapped.append(Candidate(relativePath: path, confidence: min(0.99, max(0, a.confidence)),
                                    reason: a.reason, fromCloud: true))
            if mapped.count == 3 { break }
        }
        return mapped
    }

    /// 合并本地与云端候选:云端结果优先,但保留本地强规则命中
    func merge(local: [Candidate], cloud: [Candidate]) -> [Candidate] {
        var result = cloud
        for l in local where !result.contains(where: { $0.relativePath == l.relativePath }) {
            result.append(l)
        }
        return Array(result.sorted { $0.confidence > $1.confidence }.prefix(3))
    }

    // MARK: - 工具

    private func tokenSet(of text: String) -> Set<String> {
        Set(CJKTokenizer.segment(text).split(separator: " ").map(String.init).filter { $0.count >= 2 })
    }
}
