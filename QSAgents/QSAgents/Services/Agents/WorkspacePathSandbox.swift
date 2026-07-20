import Foundation

/// Shared workspace containment — resolves symlinks so `ln -s` cannot escape the project root.
enum WorkspacePathSandbox {
    static func realStandardizedPath(_ path: String) -> String {
        let std = (path as NSString).standardizingPath
        return URL(fileURLWithPath: std).resolvingSymlinksInPath().path
    }

    /// True when `candidate` is the workspace root or a path inside it (after symlink resolution).
    static func contains(candidate: String, workspaceRoot root: String) -> Bool {
        let rootReal = realStandardizedPath(root)
        let candReal = realStandardizedPath(candidate)
        let prefix = rootReal.hasSuffix("/") ? rootReal : rootReal + "/"
        return candReal == rootReal || candReal.hasPrefix(prefix)
    }
}
