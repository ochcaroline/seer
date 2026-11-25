/// One sidebar row of the file tree: a folder (`file == nil`) or a file (index into the input paths).
public struct TreeRow: Equatable {
    public let depth: Int
    public let name: String
    public let file: Int?
}

/// Lays out paths as a folder tree, merging folders whose only child is another folder ("a/b/c/").
public func fileTree(_ paths: [String]) -> [TreeRow] {
    final class Node {
        var dirs: [(String, Node)] = []
        var files: [(String, Int)] = []
        func dir(_ name: String) -> Node {
            if let d = dirs.first(where: { $0.0 == name }) { return d.1 }
            let n = Node()
            dirs.append((name, n))
            return n
        }
    }
    let root = Node()
    for (i, p) in paths.enumerated() {
        var parts = p.split(separator: "/").map(String.init)
        let name = parts.popLast() ?? p
        parts.reduce(root) { $0.dir($1) }.files.append((name, i))
    }
    var out: [TreeRow] = []
    func emit(_ node: Node, _ depth: Int) {
        for (name, child) in node.dirs {
            var label = name + "/", n = child
            while n.files.isEmpty, n.dirs.count == 1 {
                label += n.dirs[0].0 + "/"
                n = n.dirs[0].1
            }
            out.append(TreeRow(depth: depth, name: label, file: nil))
            emit(n, depth + 1)
        }
        out += node.files.map { TreeRow(depth: depth, name: $0.0, file: $0.1) }
    }
    emit(root, 0)
    return out
}
