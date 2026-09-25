import Foundation

/// Minimal reader for Electron's app.asar: a JSON table of contents, then every file's bytes back to back.
/// Header: UInt32 4 · UInt32 headerSize · UInt32 payloadSize · UInt32 jsonLength · JSON; file data starts at 8 + headerSize.
struct Asar {
  struct Entry {
    let path: String, offset: Int, size: Int, unpacked: Bool
    var name: String { (path as NSString).lastPathComponent }
  }
  let url: URL
  let entries: [Entry]
  private let dataStart: Int

  init?(url: URL) {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    guard let head = try? fh.read(upToCount: 16), head.count == 16 else { return nil }
    let word = { (i: Int) in Int(UInt32(littleEndian: head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self) })) }
    guard word(0) == 4, let json = try? fh.read(upToCount: word(12)),
          let toc = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
    var list: [Entry] = []
    func walk(_ node: [String: Any], _ path: String) {
      for (name, value) in node["files"] as? [String: Any] ?? [:] {
        guard let v = value as? [String: Any] else { continue }
        let p = path.isEmpty ? name : "\(path)/\(name)"
        if v["files"] != nil { walk(v, p); continue }
        let offset = (v["offset"] as? String).flatMap { Int($0) } ?? (v["offset"] as? Int) ?? 0   // a string in the TOC
        list.append(Entry(path: p, offset: offset, size: v["size"] as? Int ?? 0, unpacked: v["unpacked"] as? Bool ?? false))
      }
    }
    walk(toc, "")
    self.url = url
    entries = list
    dataStart = 8 + word(4)
  }

  func read(_ e: Entry) -> Data? {
    // Files Electron couldn't pack sit next to the archive in app.asar.unpacked/.
    if e.unpacked { return try? Data(contentsOf: URL(fileURLWithPath: url.path + ".unpacked/" + e.path)) }
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    guard (try? fh.seek(toOffset: UInt64(dataStart + e.offset))) != nil, let data = try? fh.read(upToCount: e.size),
          data.count == e.size else { return nil }
    return data
  }
}
