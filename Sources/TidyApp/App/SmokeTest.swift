import Foundation

/// 无头冒烟测试:`TidyApp --smoke`
/// 覆盖 P0 里程碑的非 UI 部分:拼音模糊搜索、分词、记忆写入/FTS5 检索、归档→撤销回滚、埋点。
enum SmokeTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print("\(cond ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !cond { failures += 1 }
        }

        // 1. 拼音
        let k = Pinyin.keys(for: "客户A支付网关")
        check("拼音全拼", k.full.contains("kehu") && k.full.contains("wangguan"), k.full)
        check("拼音首字母", k.initials == "khazfwg", k.initials)

        // 2. 模糊匹配:khzf 应命中「客户A支付网关」
        let key = SearchKey("1-Projects/公司-客户A支付网关")
        check("首字母子序列匹配", FuzzyMatcher.score(query: "khzf", key: key) > 0)
        check("原文包含匹配", FuzzyMatcher.score(query: "支付", key: key) > 50)
        check("不相关不匹配", FuzzyMatcher.score(query: "qqqq", key: key) == 0)

        // 3. CJK 分词
        let seg = CJKTokenizer.segment("契约中心接口对齐_v3.pdf")
        check("CJK 二元分词", seg.contains("契约") && seg.contains("中心") && seg.contains("pdf"), seg)

        // 4. 记忆写入 + FTS5 检索
        let store = MemoryStore.shared
        store.ensureFiles()
        let marker = "SMOKE-\(Int(Date().timeIntervalSince1970))"
        store.recordEpisodic("\(marker) 归档 发票扫描件.pdf → 2-Areas/财务")
        let hits = store.search("发票扫描件", kinds: ["episodic"])
        check("FTS5 检索命中", hits.contains { $0.content.contains(marker) }, "命中 \(hits.count) 条")

        // 5. 本地分类:目录名与文件名词面重合应给出候选
        let dests = [
            Destination(relativePath: "2-Areas/财务", url: ParaTree.root.appendingPathComponent("2-Areas/财务"), searchKey: SearchKey("2-Areas/财务")),
            Destination(relativePath: "1-Projects/公司-客户A支付网关", url: ParaTree.root.appendingPathComponent("1-Projects/公司-客户A支付网关"), searchKey: SearchKey("1-Projects/公司-客户A支付网关")),
        ]
        let cands = Classifier.shared.localCandidates(fileName: "2026-07 财务发票.pdf", destinations: dests, activeProjectPath: nil)
        check("本地分类候选", cands.first?.relativePath == "2-Areas/财务", cands.map(\.relativePath).joined(separator: ","))

        // 6. 归档 → 撤销 全链路(P0 里程碑核心,§11.5)
        do {
            try ParaTree.shared.ensureRoot()
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-smoke-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let src = tmpDir.appendingPathComponent("smoke-测试文件.txt")
            try "smoke".write(to: src, atomically: true, encoding: .utf8)

            let inbox = Destination(relativePath: "0-Inbox", url: ParaTree.root.appendingPathComponent("0-Inbox"), searchKey: SearchKey("0-Inbox"))
            let results = try Archiver.shared.archive(files: [src], to: inbox, newBaseName: "smoke-renamed")
            let moved = results.first!
            check("归档移动+重命名", FileManager.default.fileExists(atPath: moved.to.path)
                  && !FileManager.default.fileExists(atPath: src.path)
                  && moved.to.lastPathComponent == "smoke-renamed.txt", moved.to.lastPathComponent)

            let undoMsg = Archiver.shared.undoLast()
            check("撤销还原", undoMsg != nil && FileManager.default.fileExists(atPath: src.path)
                  && !FileManager.default.fileExists(atPath: moved.to.path), undoMsg ?? "nil")
            try? FileManager.default.removeItem(at: tmpDir)
        } catch {
            check("归档→撤销链路", false, "\(error)")
        }

        // 7. GTD 理清链路:捕获 → 理清 → 矩阵可见 → 完成
        do {
            var item = Item.newCapture(text: "smoke-理清测试:是否复用风控的幂等组件?", source: "smoke")
            try? AppDatabase.shared.dbQueue.write { db in try item.insert(db) }
            let inboxHas = AppDatabase.shared.inboxCaptures().contains { $0.id == item.id }
            check("捕获进收件箱", inboxHas)
            AppDatabase.shared.applyClarify(itemId: item.id!, isActionable: true,
                                            nextAction: "找李四要接入文档", projectId: nil,
                                            importance: 1, urgency: 0)
            let open = AppDatabase.shared.actionableOpen()
            let row = open.first { $0.id == item.id }
            check("理清后进入行动列表", row != nil && row?.nextAction == "找李四要接入文档"
                  && row?.importance == 1 && row?.urgency == 0)
            AppDatabase.shared.markItemDone(item.id!)
            check("标记完成后离开列表", !AppDatabase.shared.actionableOpen().contains { $0.id == item.id })
            try? AppDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [item.id])
            }
        }

        // 8. 时间提及识别(detect 走系统检测器或中文兜底,CI 英文 locale 下走兜底)
        let mention = DateMention.detect(in: "明天下午3点跟张三对齐接口")
        let mentionHour = mention.map { Calendar.current.component(.hour, from: $0) }
        check("时间提及识别", mention != nil && mentionHour == 15,
              mention.map { DateMention.format($0) } ?? "nil")
        // 中文兜底解析(locale 无关)单独验证
        let zh1 = DateMention.detectChinese("下周三上午10点半评审")
        check("中文时间兜底:下周X+钟点", zh1.map { Calendar.current.component(.minute, from: $0) } == 30,
              zh1.map { DateMention.format($0) } ?? "nil")
        let zh2 = DateMention.detectChinese("8月15号交材料")
        check("中文时间兜底:X月X号", zh2 != nil, zh2.map { DateMention.format($0) } ?? "nil")
        check("无时间不误报", DateMention.detectChinese("整理一下会议纪要") == nil)

        // 9. 清单路由 + 行动链顺序解锁
        do {
            let db = AppDatabase.shared
            var proj = Project(id: nil, name: "smoke-链路项目", path: "1-Projects/smoke-链路项目",
                               status: "active", dueDate: nil, lastWorkedAt: nil, lastProgressNote: nil,
                               purpose: nil, outcome: nil, createdAt: Date(), completedAt: nil)
            try? db.dbQueue.write { d in try proj.insert(d) }
            db.savePlan(projectId: proj.id!, purpose: "验证链路", outcome: "冒烟通过",
                        steps: [("第一步", nil), ("第二步", nil), ("第三步", nil)])
            let global1 = db.globalNextActions()
            let chainVisible = global1.filter { $0.source == "plan" }
            check("行动链只露出第 1 步", chainVisible.count == 1 && chainVisible.first?.nextAction == "第一步",
                  chainVisible.map { $0.nextAction ?? "" }.joined(separator: ","))
            if let first = chainVisible.first, let fid = first.id {
                db.markItemDone(fid)
                let unlocked = db.unlockedStep(afterDone: first)
                check("完成前置解锁后置", unlocked?.nextAction == "第二步", unlocked?.nextAction ?? "nil")
            } else { check("完成前置解锁后置", false, "无第一步") }
            // 等待/搁置清单路由
            var idea = Item.newCapture(text: "smoke-等张三回邮件", source: "smoke")
            try? db.dbQueue.write { d in try idea.insert(d) }
            db.applyClarify(itemId: idea.id!, isActionable: true, nextAction: "催张三",
                            projectId: nil, importance: 0, urgency: 1,
                            list: "waiting", waitingFor: "张三")
            let w = db.items(inList: "waiting").first { $0.id == idea.id }
            check("等待清单路由", w != nil && w?.waitingFor == "张三")
            // 清理
            try? db.dbQueue.write { d in
                try d.execute(sql: "DELETE FROM item WHERE id IN (SELECT itemId FROM itemProjectLink WHERE projectId = ?)", arguments: [proj.id])
                try d.execute(sql: "DELETE FROM itemProjectLink WHERE projectId = ?", arguments: [proj.id])
                try d.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [proj.id])
                try d.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [idea.id])
            }
        }

        // 10. 截止日期 + 等待催办 + 分析统计
        do {
            let db = AppDatabase.shared
            var proj = Project(id: nil, name: "smoke-due", path: "1-Projects/smoke-due",
                               status: "active", dueDate: nil, lastWorkedAt: nil, lastProgressNote: nil,
                               purpose: nil, outcome: nil, createdAt: Date(), completedAt: nil)
            try? db.dbQueue.write { d in try proj.insert(d) }
            let due = Calendar.current.date(byAdding: .day, value: 5, to: Date())!
            db.setProjectDue(proj.id!, date: due)
            let saved = db.project(byId: proj.id!)?.dueDate
            check("项目截止日期读写", saved != nil)

            var wait = Item.newCapture(text: "smoke-等审批", source: "smoke")
            try? db.dbQueue.write { d in try wait.insert(d) }
            db.applyClarify(itemId: wait.id!, isActionable: true, nextAction: "催审批",
                            projectId: nil, importance: 0, urgency: 0, list: "waiting", waitingFor: "审批流")
            try? db.dbQueue.write { d in
                try d.execute(sql: "UPDATE item SET updatedAt = ? WHERE id = ?",
                              arguments: [Calendar.current.date(byAdding: .day, value: -5, to: Date())!, wait.id])
            }
            let stale = db.staleWaiting(days: 3)
            check("等待催办识别(搁5天)", stale.contains { $0.id == wait.id })

            let a = Telemetry.analytics()
            check("分析统计可算", a.captured > 0 && a.clarifyRate >= 0 && a.clarifyRate <= 100,
                  "捕获\(a.captured) 理清率\(a.clarifyRate)%")
            try? db.dbQueue.write { d in
                try d.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [wait.id])
                try d.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [proj.id])
            }
        }

        // 11. 待办改提醒 + 项目重命名(目录/DB 同步)
        do {
            let db = AppDatabase.shared
            var it = Item.newCapture(text: "smoke-改提醒", source: "smoke")
            try? db.dbQueue.write { d in try it.insert(d) }
            let when = Date().addingTimeInterval(7200)
            db.setRemind(it.id!, at: when)
            let fetched = try? db.dbQueue.read { d in
                try Item.fetchOne(d, sql: "SELECT * FROM item WHERE id = ?", arguments: [it.id])
            }
            check("待办设提醒", (fetched ?? nil)?.remindAt != nil && (fetched ?? nil)?.remindedAt == nil)
            db.setRemind(it.id!, at: nil)
            let cleared = try? db.dbQueue.read { d in
                try Item.fetchOne(d, sql: "SELECT * FROM item WHERE id = ?", arguments: [it.id])
            }
            check("待办清提醒", (cleared ?? nil)?.remindAt == nil)
            try? db.dbQueue.write { d in try d.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [it.id]) }

            let dest = try? ParaTree.shared.createDestination(kind: "project", name: "smoke-改名前")
            if dest != nil, let p = db.project(byPath: "1-Projects/smoke-改名前") {
                let newPath = ProjectLifecycle.rename(p, to: "smoke-改名后")
                let dirOK = FileManager.default.fileExists(atPath: ParaTree.root.appendingPathComponent("1-Projects/smoke-改名后").path)
                let dbOK = db.project(byPath: "1-Projects/smoke-改名后") != nil
                check("项目重命名同步", newPath == "1-Projects/smoke-改名后" && dirOK && dbOK)
                try? FileManager.default.removeItem(at: ParaTree.root.appendingPathComponent("1-Projects/smoke-改名后"))
                try? db.dbQueue.write { d in try d.execute(sql: "DELETE FROM project WHERE path LIKE '1-Projects/smoke-改名%'") }
            } else {
                check("项目重命名同步", false, "前置创建失败")
            }
        }

        // 12. 文档关系 v1:两两关联 + 查询
        do {
            let db = AppDatabase.shared
            let a = "/tmp/smoke-docA.md", b = "/tmp/smoke-docB.md", c = "/tmp/smoke-docC.md"
            let added = db.linkDocs([a, b, c])
            check("文档两两关联", added == 3, "新增 \(added) 组")
            let rel = db.relatedDocs(of: a)
            check("关联查询", rel.contains(b) && rel.contains(c) && rel.count == 2)
            let again = db.linkDocs([a, b])
            check("重复关联去重", again == 0)
            try? db.dbQueue.write { d in
                try d.execute(sql: "DELETE FROM docRelation WHERE aPath LIKE '/tmp/smoke-%'")
            }
        }

        // 13. 埋点可算指标
        Telemetry.record(event: "confirm", suggestedPaths: ["a"], suggestedScores: [0.9], chosenPath: "a", chosenRank: 1, latencyMs: 800)
        let summary = Telemetry.summary()
        check("埋点统计", summary.contains("首选命中率"), summary.components(separatedBy: "\n").first ?? "")

        print(failures == 0 ? "\n全部通过 🎉" : "\n\(failures) 项失败")
        return failures == 0 ? 0 : 1
    }
}
