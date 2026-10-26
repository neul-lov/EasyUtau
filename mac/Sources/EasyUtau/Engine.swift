import AppKit
import Foundation

/// EasyUtau 엔진(engine/, C#)을 켜고 명령을 주고받는다.
///
/// 엔진은 사용자가 깔아 둔 OpenUtau를 그대로 쓴다: OpenUtau.app의 프로그램 폴더를 앱 데이터 폴더에 복사해 두고
/// (APFS 복제라 자리를 거의 차지하지 않는다) OpenUtau.dll 자리에 EasyUtauEngine.dll을 넣어 돌린다.
/// 그래서 OpenUtau에 깐 가수(테토 등) · 발음 방식 · 설정을 그대로 쓰고, OpenUtau 앱 자체는 건드리지 않는다.
/// 실행 파일 이름은 EasyUtauEngine: OpenUtau는 같은 이름("OpenUtau")의 프로세스가 있으면 켜자마자 꺼져서,
/// 이름이 같으면 EasyUtau를 켜 둔 채로 OpenUtau를 열 수 없다.
final class Engine: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noOpenUtau
        case noEngine
        case oldOpenUtau(String)
        case message(String)

        var errorDescription: String? {
            switch self {
            case .noOpenUtau: "OpenUtau를 찾지 못했어요. 응용 프로그램 폴더에 OpenUtau.app이 있어야 해요."
            case .noEngine: "이 앱에 엔진이 들어 있지 않아요. 앱을 다시 받아 주세요."
            case .oldOpenUtau(let v): "OpenUtau가 너무 예전 버전이에요(\(v)). 최신 OpenUtau로 올려 주세요."
            case .message(let m): m
            }
        }
    }

    static let exeName = "EasyUtauEngine"

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EasyUtau", isDirectory: true)
    }

    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("EasyUtau", isDirectory: true)
    }

    static var logURL: URL { supportDir.appendingPathComponent("engine.log") }

    /// OpenUtau 프로그램 폴더 (OpenUtau 실행 파일 · OpenUtau.Core.dll이 있는 곳).
    static func openUtauDir() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["EASYUTAU_OPENUTAU"] { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(URL(fileURLWithPath: "/Applications/OpenUtau.app"))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/OpenUtau.app"))
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stakira.openutau") { candidates.append(found) }
        for c in candidates {
            for d in [c.appendingPathComponent("Contents/MacOS"), c] {
                let fm = FileManager.default
                if fm.fileExists(atPath: d.appendingPathComponent("OpenUtau.Core.dll").path),
                   fm.fileExists(atPath: d.appendingPathComponent("OpenUtau").path),
                   fm.fileExists(atPath: d.appendingPathComponent("OpenUtau.deps.json").path) {
                    return d
                }
            }
        }
        return nil
    }

    /// OpenUtau 앱 자체 (.app) — "OpenUtau에서 열기"에 쓴다.
    static func openUtauApp() -> URL? {
        guard let dir = openUtauDir() else { return nil }
        // …/OpenUtau.app/Contents/MacOS → …/OpenUtau.app
        var url = dir
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    static func engineDLL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["EASYUTAU_ENGINE_DLL"] {
            return URL(fileURLWithPath: env)
        }
        let url = Bundle.main.resourceURL?.appendingPathComponent("engine/EasyUtauEngine.dll")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    // MARK: 준비

    /// 엔진을 돌릴 폴더를 준비한다 (OpenUtau나 엔진이 바뀌었을 때만 다시 복사).
    static func prepare() throws -> URL {
        guard let src = openUtauDir() else { throw Failure.noOpenUtau }
        guard let dll = engineDLL() else { throw Failure.noEngine }
        let fm = FileManager.default
        let root = supportDir
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let host = root.appendingPathComponent("engine-host", isDirectory: true)
        let stamp = try stampOf(src: src, dll: dll)
        let stampURL = host.appendingPathComponent(".stamp")
        if let old = try? String(contentsOf: stampURL, encoding: .utf8), old == stamp,
           fm.fileExists(atPath: host.appendingPathComponent(exeName).path) {
            return host
        }
        let tmp = root.appendingPathComponent("engine-host.new", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // APFS 복제 (cp -c): 바로 끝나고 자리도 거의 안 쓴다
        if run("/bin/cp", ["-cR", src.path + "/.", tmp.path]) != 0 {
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: src, to: tmp)
        }
        try makeDeps(tmp)
        for name in ["EasyUtauEngine.dll", "OpenUtau.dll"] {
            let to = tmp.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: dll, to: to)
        }
        let exe = tmp.appendingPathComponent(exeName)
        try? fm.removeItem(at: exe)
        // 실행 파일(apphost)은 이름이 달라도 OpenUtau.dll을 돌린다
        try fm.copyItem(at: tmp.appendingPathComponent("OpenUtau"), to: exe)
        // 복사본에 붙은 "인터넷에서 받음" 표시만 뗀다 (OpenUtau 앱은 그대로)
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", tmp.path])
        try stamp.write(to: tmp.appendingPathComponent(".stamp"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: host)
        try fm.moveItem(at: tmp, to: host)
        return host
    }

    private static func stampOf(src: URL, dll: URL) throws -> String {
        let fm = FileManager.default
        let a = try fm.attributesOfItem(atPath: src.appendingPathComponent("OpenUtau.Core.dll").path)
        let b = try fm.attributesOfItem(atPath: dll.path)
        func s(_ attrs: [FileAttributeKey: Any]) -> String {
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)|\(Int(date))"
        }
        return "\(src.path)|\(s(a))|\(s(b))|1"
    }

    /// OpenUtau.deps.json의 런타임 부분만 남긴다 (OpenUtau.dll 자리의 다른 프로그램을 돌리려고).
    private static func makeDeps(_ folder: URL) throws {
        let depsURL = folder.appendingPathComponent("OpenUtau.deps.json")
        var data = try Data(contentsOf: depsURL)
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        guard let deps = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimeTarget = deps["runtimeTarget"] as? [String: Any],
              let target = runtimeTarget["name"] as? String,
              let targets = deps["targets"] as? [String: Any],
              let entries = targets[target] as? [String: Any] else {
            throw Failure.message("OpenUtau 파일 목록(deps.json)을 읽지 못했어요")
        }
        let packs = entries.filter { $0.key.lowercased().hasPrefix("runtimepack.") }
        let libraries = (deps["libraries"] as? [String: Any] ?? [:]).filter { packs[$0.key] != nil }
        let out: [String: Any] = [
            "runtimeTarget": runtimeTarget,
            "compilationOptions": [String: Any](),
            "targets": [target: packs],
            "libraries": libraries,
        ]
        let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
        try json.write(to: folder.appendingPathComponent("Microsoft.NETCore.App.deps.json"))
        try FileManager.default.removeItem(at: depsURL)
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: 켜기 · 주고받기

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let lock = NSLock()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var log: FileHandle?

    /// 엔진 알림 (메인 스레드에서 부른다): 이름, 내용
    var onEvent: (@MainActor (String, [String: Any]) -> Void)?
    /// 엔진이 꺼졌을 때 (메인 스레드에서): 마지막 기록
    var onExit: (@MainActor (Int32, String) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    func launch(host: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        fm.createFile(atPath: Self.logURL.path, contents: nil)
        log = try? FileHandle(forWritingTo: Self.logURL)

        let p = Process()
        p.executableURL = host.appendingPathComponent(Self.exeName)
        p.arguments = ["EasyUtauEngine.dll"]
        p.currentDirectoryURL = host
        var env = ProcessInfo.processInfo.environment
        env["EASYUTAU_CACHE"] = Self.cacheDir.path
        env["EASYUTAU_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.received(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            self?.lock.lock()
            self?.log?.write(data)
            self?.lock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            self.lock.lock()
            let pending = self.waiting
            self.waiting.removeAll()
            self.lock.unlock()
            for (_, c) in pending { c.resume(throwing: Failure.message("엔진이 꺼졌어요")) }
            let tail = self.logTail()
            let code = proc.terminationStatus
            Task { @MainActor in self.onExit?(code, tail) }
        }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
    }

    func stop() {
        try? input?.close()
        input = nil
        if let p = process, p.isRunning {
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
            p.terminate()
        }
        process = nil
    }

    func logTail(_ lines: Int = 12) -> String {
        guard let text = try? String(contentsOf: Self.logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    private func received(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let event = obj["event"] as? String {
                Task { @MainActor [weak self] in self?.onEvent?(event, obj) }
                continue
            }
            guard let id = (obj["id"] as? NSNumber)?.intValue else { continue }
            lock.lock()
            let c = waiting.removeValue(forKey: id)
            lock.unlock()
            if obj["ok"] as? Bool == true {
                c?.resume(returning: obj)
            } else {
                c?.resume(throwing: Failure.message(obj["error"] as? String ?? "엔진이 명령을 못 했어요"))
            }
        }
    }

    /// 명령 하나를 보내고 답을 기다린다.
    func send(_ cmd: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        guard let input else { throw Failure.message("엔진이 켜져 있지 않아요") }
        return try await withCheckedThrowingContinuation { c in
            lock.lock()
            let id = nextID
            nextID += 1
            waiting[id] = c
            lock.unlock()
            var obj = args
            obj["id"] = id
            obj["cmd"] = cmd
            do {
                var data = try JSONSerialization.data(withJSONObject: obj)
                data.append(0x0A)
                try input.write(contentsOf: data)
            } catch {
                lock.lock()
                let c = waiting.removeValue(forKey: id)
                lock.unlock()
                c?.resume(throwing: Failure.message("엔진에 보내지 못했어요: \(error.localizedDescription)"))
            }
        }
    }

    /// 답의 한 부분을 타입으로.
    static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        guard let value, JSONSerialization.isValidJSONObject(value) || value is [Any] else {
            throw Failure.message("엔진 답을 읽지 못했어요")
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Codable 값을 명령에 넣을 수 있게.
    static func object<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return obj
    }
}
