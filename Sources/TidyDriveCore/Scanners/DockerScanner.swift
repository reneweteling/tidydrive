import Foundation

/// Docker images and volumes per compose project, plus dangling images,
/// stopped containers and build cache. Anything a running container uses is
/// left out.
public struct DockerScanner: Scanner {
    public let category: Category = .docker

    public init() {}

    struct Container {
        var id: String
        var name: String
        var image: String
        var project: String?
        var running: Bool
        var mounts: [String]
        var size: Int64
    }

    public func scan(_ context: ScanContext) -> ([CleanupItem], [ScanNote]) {
        guard context.shell.has("docker") else { return ([], []) }
        let info = context.shell.run("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: 15)
        guard info.succeeded else {
            return ([], [ScanNote(category: .docker, message: "Docker is installed but not running. Start it and rescan to see images and volumes.")])
        }

        let df = context.shell.run("docker", ["system", "df", "-v", "--format", "{{json .}}"], timeout: 180)
        guard df.succeeded, let json = try? JSONSerialization.jsonObject(with: Data(df.stdout.utf8)) as? [String: Any] else {
            return ([], [ScanNote(category: .docker, message: "Could not read Docker disk usage: \(df.stderr.prefix(200))")])
        }

        let containers = ((json["Containers"] as? [[String: Any]]) ?? []).map { c -> Container in
            let labels = Self.labels(c["Labels"] as? String)
            return Container(
                id: c["ID"] as? String ?? "",
                name: c["Names"] as? String ?? "",
                image: c["Image"] as? String ?? "",
                project: labels["com.docker.compose.project"],
                running: (c["State"] as? String) == "running",
                mounts: (c["Mounts"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                size: Self.parseSize(c["Size"] as? String)
            )
        }

        var items: [CleanupItem] = []
        items += images((json["Images"] as? [[String: Any]]) ?? [], containers: containers)
        items += volumes((json["Volumes"] as? [[String: Any]]) ?? [], containers: containers)

        let stopped = containers.filter { !$0.running }
        if !stopped.isEmpty {
            items.append(CleanupItem(
                id: "docker:stopped-containers", category: .docker, group: "General", title: "Stopped containers",
                detail: "\(stopped.count) containers. docker compose up creates them again. Their volumes stay.",
                path: nil, size: stopped.reduce(0) { $0 + $1.size }, risk: .rebuild, selectedByDefault: true,
                action: .commands([Command("docker", ["container", "prune", "--force"])], fallbackDelete: [])
            ))
        }

        let buildCache = ((json["BuildCache"] as? [[String: Any]]) ?? [])
            .filter { ($0["InUse"] as? Bool) != true }
            .reduce(Int64(0)) { $0 + Self.parseSize($1["Size"] as? String) }
        if buildCache > 0 {
            items.append(CleanupItem(
                id: "docker:build-cache", category: .docker, group: "General", title: "Build cache",
                detail: "Layers cached by docker build. The next build is slower once.",
                path: nil, size: buildCache, risk: .safe, selectedByDefault: true,
                action: .commands([Command("docker", ["builder", "prune", "--all", "--force"])], fallbackDelete: [])
            ))
        }

        let note = ScanNote(category: .docker, message: "Docker Desktop keeps everything in one disk image. TidyDrive reports what was actually freed on your disk after cleaning, which can be less than Docker's own numbers.")
        return (items, [note])
    }

    private func images(_ raw: [[String: Any]], containers: [Container]) -> [CleanupItem] {
        raw.compactMap { image in
            let id = image["ID"] as? String ?? ""
            let shortID = String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
            let repo = image["Repository"] as? String ?? "<none>"
            let tag = image["Tag"] as? String ?? "<none>"
            let reference = repo == "<none>" ? shortID : (tag == "<none>" ? repo : "\(repo):\(tag)")
            let users = containers.filter { c in
                c.image == reference || c.image == id || c.image.hasPrefix(shortID)
                    || (tag == "latest" && c.image == repo)
            }
            if users.contains(where: \.running) { return nil }

            let size = Self.parseSize(image["UniqueSize"] as? String ?? image["Size"] as? String)
            let projects = Set(users.compactMap(\.project))
            let dangling = repo == "<none>"
            let group: String
            if dangling { group = "Dangling images" }
            else if let p = projects.sorted().first { group = "Project \(p)" }
            else if users.isEmpty { group = "Images no container uses" }
            else { group = "Images used by stopped containers" }

            var commands: [Command] = []
            if !users.isEmpty { commands.append(Command("docker", ["rm", "--force"] + users.map(\.id))) }
            commands.append(Command("docker", ["rmi", "--force", id]))

            var detail = "Image \(shortID) · created \(image["CreatedSince"] as? String ?? "?")"
            if !users.isEmpty { detail += " · removes \(users.count) stopped container\(users.count == 1 ? "" : "s")" }
            return CleanupItem(
                id: "docker:image:\(id)", category: .docker, group: group,
                title: dangling ? "<none> \(shortID)" : reference, detail: detail, path: nil, size: size,
                risk: .rebuild, selectedByDefault: dangling, action: .commands(commands, fallbackDelete: [])
            )
        }
    }

    private func volumes(_ raw: [[String: Any]], containers: [Container]) -> [CleanupItem] {
        raw.compactMap { volume in
            let name = volume["Name"] as? String ?? ""
            let labels = Self.labels(volume["Labels"] as? String)
            let users = containers.filter { $0.mounts.contains(name) }
            if users.contains(where: \.running) { return nil }

            let anonymous = labels["com.docker.volume.anonymous"] != nil
            let project = labels["com.docker.compose.project"] ?? users.compactMap(\.project).first
            let group = project.map { "Project \($0)" } ?? (anonymous ? "Anonymous volumes" : "Volumes")
            var commands: [Command] = []
            if !users.isEmpty { commands.append(Command("docker", ["rm", "--force"] + users.map(\.id))) }
            commands.append(Command("docker", ["volume", "rm", "--force", name]))

            let title = labels["com.docker.compose.volume"].map { "\(project ?? "")_\($0)" } ?? (anonymous ? String(name.prefix(12)) : name)
            let detail = (users.isEmpty ? "No container uses this volume. " : "Only stopped containers use this volume. ")
                + "It may hold a database or uploads, which do not come back."
            return CleanupItem(
                id: "docker:volume:\(name)", category: .docker, group: group, title: title, detail: detail, path: nil,
                size: Self.parseSize(volume["Size"] as? String), risk: .careful, selectedByDefault: false,
                action: .commands(commands, fallbackDelete: [])
            )
        }
    }

    // MARK: - Parsing

    /// Docker prints decimal units: "7.66GB", "349.2MB", "20.5kB", "2B".
    public static func parseSize(_ raw: String?) -> Int64 {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "N/A" else { return 0 }
        if let paren = s.firstIndex(of: " ") { s = String(s[..<paren]) }
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where s.hasSuffix(unit) {
            let number = Double(s.dropLast(unit.count)) ?? 0
            return Int64(number * factor)
        }
        return Int64(Double(s) ?? 0)
    }

    static func labels(_ raw: String?) -> [String: String] {
        var result: [String: String] = [:]
        for pair in (raw ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count >= 1 { result[String(parts[0])] = parts.count == 2 ? String(parts[1]) : "" }
        }
        return result
    }
}
