import Foundation

/// PARA 目录里的一个可归档位置
struct Destination: Identifiable, Hashable {
    var id: String { relativePath }
    let relativePath: String   // 如 "1-Projects/公司-客户A支付网关"
    let url: URL
    let searchKey: SearchKey

    var displayName: String { relativePath }
    /// 语义名(最后一级目录名),用作 Finder 标签
    var leafName: String { url.lastPathComponent }
    var topCategory: String { relativePath.components(separatedBy: "/").first ?? "" }

    static func == (l: Destination, r: Destination) -> Bool { l.relativePath == r.relativePath }
    func hash(into hasher: inout Hasher) { hasher.combine(relativePath) }
}

/// PARA 目录树扫描与缓存(§3)。目录即真相源,零手工维护。
final class ParaTree {
    /// PARA 根目录:默认 ~/Documents/PARA,可用 .env 的 PARA_ROOT 覆盖(启动时设置)
    static var root: URL = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Documents/PARA")

    static let topDirs = ["0-Inbox", "1-Projects", "2-Areas", "3-Resources", "4-Archive"]

    private(set) var destinations: [Destination] = []
    private var lastScan: Date?

    static let shared = ParaTree()

    /// 确保根结构存在
    func ensureRoot() throws {
        let fm = FileManager.default
        for d in Self.topDirs {
            try fm.createDirectory(at: Self.root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
    }

    /// 扫描目录树(顶层 + 两级子目录),并把 Projects/Areas 登记进库
    @discardableResult
    func scan() -> [Destination] {
        let fm = FileManager.default
        var result: [Destination] = []
        var projects: [(String, String)] = []
        var areas: [(String, String)] = []

        for top in Self.topDirs {
            let topURL = Self.root.appendingPathComponent(top)
            guard fm.fileExists(atPath: topURL.path) else { continue }
            // 顶层目录本身可作为归档位置(如 0-Inbox、3-Resources 根)
            result.append(Destination(relativePath: top, url: topURL, searchKey: SearchKey(top)))
            for sub in subdirectories(of: topURL) {
                let rel = "\(top)/\(sub.lastPathComponent)"
                result.append(Destination(relativePath: rel, url: sub, searchKey: SearchKey(rel)))
                if top == "1-Projects" { projects.append((sub.lastPathComponent, rel)) }
                if top == "2-Areas" { areas.append((sub.lastPathComponent, rel)) }
                // 再往下一级(如 2-Areas/财务/2026)
                for sub2 in subdirectories(of: sub) {
                    let rel2 = "\(rel)/\(sub2.lastPathComponent)"
                    result.append(Destination(relativePath: rel2, url: sub2, searchKey: SearchKey(rel2)))
                }
            }
        }
        destinations = result
        lastScan = Date()
        AppDatabase.shared.registerScanned(projects: projects, areas: areas)
        return result
    }

    /// 3 秒内的重复扫描直接用缓存(面板反复唤起时)
    func freshDestinations() -> [Destination] {
        if let t = lastScan, Date().timeIntervalSince(t) < 3, !destinations.isEmpty {
            return destinations
        }
        return scan()
    }

    private func subdirectories(of url: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 新建项目 / 领域目录,返回 Destination
    func createDestination(kind: String, name: String) throws -> Destination {
        let top = kind == "area" ? "2-Areas" : "1-Projects"
        let url = Self.root.appendingPathComponent(top).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let rel = "\(top)/\(name)"
        scan()
        return Destination(relativePath: rel, url: url, searchKey: SearchKey(rel))
    }

    /// 项目目录内按 mtime 倒序取最近文件(工作台「最近动过的文件」)
    static func recentFiles(in dir: URL, limit: Int = 5) -> [(url: URL, mtime: Date)] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [(URL, Date)] = []
        var count = 0
        for case let url as URL in en {
            count += 1
            if count > 2000 { break }  // 大目录保护
            guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  rv.isRegularFile == true, let m = rv.contentModificationDate else { continue }
            files.append((url, m))
        }
        return Array(files.sorted { $0.1 > $1.1 }.prefix(limit))
    }
}
