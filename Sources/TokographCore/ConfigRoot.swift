import Foundation

public enum ConfigRootResolution: Equatable, Sendable {
    case resolved(URL)
    case configError
}

public enum ConfigRoot {
    public static func resolve(defaultsValue: String?, env: [String: String], home: URL) -> ConfigRootResolution {
        let override = defaultsValue ?? env["CLAUDE_CONFIG_DIR"]
        guard let raw = override else {
            return .resolved(home.appendingPathComponent(".claude"))
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .configError }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.isReadableFile(atPath: expanded) else {
            return .configError
        }
        return .resolved(URL(fileURLWithPath: expanded))
    }
}
