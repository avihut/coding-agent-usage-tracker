#!/usr/bin/env swift
// Presses (or selects) the first element matching a title/description/value —
// buttons, tab items, and sidebar rows alike. The verification harness's
// hands, next to axdump's eyes. Usage: axpress.swift [pid] <target> — pid
// defaults to the newest running ClaudeUsage.

import AppKit
import ApplicationServices

var args = Array(CommandLine.arguments.dropFirst())
let explicitPid: pid_t? = args.first.flatMap { Int32($0) }
if explicitPid != nil { args.removeFirst() }
guard let target = args.first else {
    FileHandle.standardError.write(Data("usage: axpress.swift [pid] <target>\n".utf8))
    exit(2)
}

func resolvePid() -> pid_t {
    if let explicitPid { return explicitPid }
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

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    return (names as? [String]) ?? []
}

func matches(_ element: AXUIElement) -> Bool {
    let title = attr(element, kAXTitleAttribute) as? String ?? ""
    let description = attr(element, kAXDescriptionAttribute) as? String ?? ""
    let value = attr(element, kAXValueAttribute) as? String ?? ""
    return title == target || description == target || value == target
}

func find(_ element: AXUIElement) -> AXUIElement? {
    if matches(element) { return element }
    if let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            if let hit = find(child) { return hit }
        }
    }
    return nil
}

func activate(_ match: AXUIElement) -> String? {
    var element: AXUIElement? = match
    for _ in 0..<5 {
        guard let current = element else { break }
        if actions(current).contains(kAXPressAction) {
            AXUIElementPerformAction(current, kAXPressAction as CFString)
            return "pressed"
        }
        let role = attr(current, kAXRoleAttribute) as? String ?? ""
        if role == "AXRow" || role == "AXCell" || role == "AXOutlineRow" {
            AXUIElementSetAttributeValue(current, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            return "selected"
        }
        element = attr(current, kAXParentAttribute).map { ($0 as! AXUIElement) }
    }
    return nil
}

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
for root in roots {
    if let hit = find(root), let outcome = activate(hit) {
        print("\(outcome): \(target)")
        exit(0)
    }
}
print("not found: \(target)")
exit(1)
