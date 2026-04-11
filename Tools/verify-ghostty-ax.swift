#!/usr/bin/env swift
// One-off: dump Ghostty's AX tree to /tmp/ghostty-ax-dump.txt.
//
// Usage:
//   1. Open Ghostty with at least 2 tabs, one containing a split pane.
//   2. Make sure every surface has a non-default title (run `printf '\e]2;test\a'` in each pane).
//   3. Run: swift Tools/verify-ghostty-ax.swift
//   4. Inspect: cat /tmp/ghostty-ax-dump.txt

import AppKit
import ApplicationServices
import Foundation

let ghosttyBundleID = "com.mitchellh.ghostty"

print("Waiting 3 seconds — switch to Ghostty now...")
Thread.sleep(forTimeInterval: 3)

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).first else {
    print("ERROR: Ghostty not running")
    exit(1)
}
print("Found Ghostty pid=\(app.processIdentifier)")

guard AXIsProcessTrusted() else {
    print("ERROR: Accessibility permission not granted. Grant it to /usr/bin/swift or to Terminal and rerun.")
    exit(1)
}

let appRef = AXUIElementCreateApplication(app.processIdentifier)

func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var out: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(el, attr as CFString, &out)
    return out
}

func dump(_ el: AXUIElement, depth: Int, writer: (String) -> Void) {
    let indent = String(repeating: "  ", count: depth)
    let role = (copy(el, kAXRoleAttribute as String) as? String) ?? "?"
    let subrole = (copy(el, kAXSubroleAttribute as String) as? String) ?? ""
    let title = (copy(el, kAXTitleAttribute as String) as? String) ?? ""
    let desc = (copy(el, kAXDescriptionAttribute as String) as? String) ?? ""
    let ident = (copy(el, kAXIdentifierAttribute as String) as? String) ?? ""
    let children = (copy(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []

    writer("\(indent)[\(role)\(subrole.isEmpty ? "" : "/\(subrole)")] "
         + "title=\"\(title)\" desc=\"\(desc.prefix(60))\" ident=\"\(ident)\" children=\(children.count)")

    if depth < 6 {
        for c in children { dump(c, depth: depth + 1, writer: writer) }
    }
}

var lines: [String] = []
let writer: (String) -> Void = { lines.append($0) }

let windows = (copy(appRef, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
writer("Ghostty has \(windows.count) top-level AX windows")
for (i, w) in windows.enumerated() {
    writer("=== window \(i) ===")
    dump(w, depth: 0, writer: writer)
}

let out = lines.joined(separator: "\n") + "\n"
try? out.write(toFile: "/tmp/ghostty-ax-dump.txt", atomically: true, encoding: .utf8)
print("Done. See /tmp/ghostty-ax-dump.txt (\(lines.count) lines)")
