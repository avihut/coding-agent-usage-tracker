#!/usr/bin/env swift
// Dumps every window's static texts and titled controls WITH FRAMES —
// numeric truth for layout bugs (overflow past the window edge, overlapping
// rows) that text-only dumps can't see. The verification harness's eyes,
// next to axpress's hands. Usage: axdump.swift [pid] — defaults to the
// newest running ClaudeUsage.

import AppKit
import ApplicationServices

func resolvePid() -> pid_t {
    if let arg = CommandLine.arguments.dropFirst().first {
        guard let pid = Int32(arg) else {
            FileHandle.standardError.write(Data("not a pid: \(arg)\n".utf8))
            exit(2)
        }
        return pid
    }
    let candidates = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == "com.avihu.ClaudeUsage" || $0.localizedName == "ClaudeUsage"
    }
    guard let newest = candidates.max(by: {
        ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast)
    }) else {
        FileHandle.standardError.write(Data("no running ClaudeUsage and no pid given\n".utf8))
        exit(2)
    }
    return newest.processIdentifier
}

let app = AXUIElementCreateApplication(resolvePid())

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let posValue = attr(element, kAXPositionAttribute),
          let sizeValue = attr(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func describeFrame(_ rect: CGRect?) -> String {
    guard let rect else { return "" }
    return String(
        format: " [x %.0f y %.0f w %.0f h %.0f]",
        rect.origin.x, rect.origin.y, rect.width, rect.height)
}

func walk(_ element: AXUIElement, depth: Int, out: inout [String]) {
    let role = attr(element, kAXRoleAttribute) as? String ?? "?"
    let title = attr(element, kAXTitleAttribute) as? String
    var text: String?
    if role == "AXStaticText" {
        text = (attr(element, kAXValueAttribute) as? String).map { String($0.prefix(56)) }
    } else if let title, !title.isEmpty {
        text = "[\(role)] \(title)"
    } else if role == "AXSlider", let value = attr(element, kAXValueAttribute) {
        text = "[AXSlider] \(value)"
    }
    if let text, !text.isEmpty {
        out.append(String(repeating: " ", count: min(depth, 8)) + text + describeFrame(frame(element)))
    }
    if let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children { walk(child, depth: depth + 1, out: &out) }
    }
}

var out: [String] = []
var roots: [AXUIElement] = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
// NSPopover windows never appear in AXWindows — they're roleless direct
// children of the app element. Sweep those in too (menu bars excluded).
if let children = attr(app, kAXChildrenAttribute) as? [AXUIElement] {
    for child in children {
        let role = attr(child, kAXRoleAttribute) as? String
        if role != "AXMenuBar", !roots.contains(where: { CFEqual($0, child) }) {
            roots.append(child)
        }
    }
}
if roots.isEmpty {
    out.append("no windows")
} else {
    for (index, root) in roots.enumerated() {
        let role = attr(root, kAXRoleAttribute) as? String ?? "roleless"
        let title = (attr(root, kAXTitleAttribute) as? String) ?? "untitled"
        out.append("=== root \(index) (\(role)): \(title)\(describeFrame(frame(root)))")
        walk(root, depth: 0, out: &out)
    }
}
print(out.joined(separator: "\n"))
