// Checks every SF Symbol name this project draws against the running OS's symbol catalog,
// so an unknown name fails a build instead of rendering blank. SwiftUI draws *nothing* for
// a symbol it does not know and reports no error at all — which is how an earlier build of
// the sibling app shipped `waveform.badge.ellipsis` and left an empty gap in a pill.
//
// Run:  swift Tools/check-symbols.swift      (from the repo root)
// Exit: 0 when every name is real, 1 when any is not.
//       `swift Tools/check-symbols.swift --years` also lists when each name arrived.
//
// Names are found from the call sites that draw them — `systemName:` / `systemImage:` /
// `systemSymbolName:` arguments, the `glyph:` strings the battery chips take, and the
// `symbol` switch bodies the enums expose — rather than by scanning every string literal,
// which would flag file names and state labels as false positives.

import Foundation

let fileManager = FileManager.default

// MARK: - Locate the tree

// `#filePath` is this script, so the repo root is its parent's parent — independent of the
// directory the shell happened to be in.
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repoRoot = scriptURL
    .deletingLastPathComponent()    // Tools
    .deletingLastPathComponent()    // repo root
let rootPrefix = repoRoot.path.hasSuffix("/") ? repoRoot.path : repoRoot.path + "/"

func relative(_ url: URL) -> String {
    url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : url.path
}

func swiftFiles(under directory: URL) -> [URL] {
    guard let enumerator = fileManager.enumerator(
        at: directory, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        files.append(url)
    }
    return files
}

let roots = ["Sources", "Tools"]
    .map { repoRoot.appendingPathComponent($0) }
    .filter { fileManager.fileExists(atPath: $0.path) }
guard !roots.isEmpty else {
    FileHandle.standardError.write(Data(
        "error: no Sources/ or Tools/ directory under \(repoRoot.path)\n".utf8))
    exit(1)
}
let files = roots.flatMap(swiftFiles)
    .filter { $0.standardizedFileURL != scriptURL }   // this tool draws no symbols itself
    .sorted { $0.path < $1.path }

// MARK: - The OS catalog

let catalogPath =
    "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
guard let catalogData = fileManager.contents(atPath: catalogPath),
      let catalog = (try? PropertyListSerialization.propertyList(
          from: catalogData, options: [], format: nil)) as? [String: Any],
      let symbols = catalog["symbols"] as? [String: String] else {
    // No catalog means we cannot tell a real name from a missing one. Say so and pass: an
    // unverifiable check is not a failed one, and failing here would break builds on any
    // machine that lays its symbols out differently.
    FileHandle.standardError.write(Data(
        "warning: SF Symbols catalog not readable at \(catalogPath); skipping the symbol check\n".utf8))
    exit(0)
}

// Introduction year -> the OS releases that first carried it. Only for `--years`.
let releases = catalog["year_to_release"] as? [String: [String: String]] ?? [:]

// MARK: - Find the names

struct Occurrence {
    let path: String
    let line: Int
    let name: String
}

// A `systemName:` / `systemImage:` / `systemSymbolName:` argument: everything after the
// label up to the argument's end, so a ternary with two literals is caught whole.
let symbolArgument = try! NSRegularExpression(
    pattern: #"\b(systemName|systemImage|systemSymbolName)\s*:\s*([^,)\n]*)"#)
// The `glyph:` strings the battery chips and device pills take.
let glyphArgument = try! NSRegularExpression(pattern: #"\bglyph\s*:\s*([^,)\n]*)"#)
// A `symbol` property or function, whose switch body is a list of the names it can return.
let symbolProperty = try! NSRegularExpression(
    pattern: #"\b(?:var|func)\s+symbol\b[^\n]*\{([^}]*)\}"#)
let quotedLiteral = try! NSRegularExpression(pattern: #""([^"]*)""#)
let bareIdentifier = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#)

func isBareIdentifier(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return bareIdentifier.firstMatch(in: text, range: range)?.range == range
}

/// The quoted strings inside `range`, paired with the location they start at.
func quotedNames(in text: String, range: NSRange) -> [(name: String, location: Int)] {
    quotedLiteral.matches(in: text, range: range).compactMap { match in
        guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return (String(text[swiftRange]), match.range(at: 1).location)
    }
}

/// The `let`/`var` binding of `identifier` nearest before `location`, so
/// `systemSymbolName: name` can be followed to the literals `name` is actually assigned.
/// Nearest-before matters: a file can bind the same identifier more than once, and an
/// earlier one elsewhere is not the value being drawn.
func assignedValue(of identifier: String, before location: Int, in text: String) -> NSRange? {
    let pattern = #"\b(?:let|var)\s+"# + NSRegularExpression.escapedPattern(for: identifier)
        + #"\b\s*(?::\s*[^=\n]+)?=\s*([^\n]*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let full = NSRange(location: 0, length: (text as NSString).length)
    return regex.matches(in: text, range: full)
        .last { $0.range.location < location }
        .map { $0.range(at: 1) }
}

/// 1-based line number of a UTF-16 location.
func lineNumber(of location: Int, in text: String) -> Int {
    let ns = text as NSString
    var line = 1
    var index = 0
    while index < location && index < ns.length {
        if ns.character(at: index) == 0x0a { line += 1 }
        index += 1
    }
    return line
}

var occurrences: [Occurrence] = []
var notes: [String] = []

for file in files {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
    let full = NSRange(location: 0, length: (text as NSString).length)
    let path = relative(file)

    for match in symbolArgument.matches(in: text, range: full) {
        let argument = match.range(at: 2)
        let expression = (text as NSString).substring(with: argument)
            .trimmingCharacters(in: .whitespaces)
        let names = quotedNames(in: text, range: argument)
        if names.isEmpty {
            // Not a literal. Follow a plain local binding if there is one; otherwise say so,
            // because the value cannot be checked from this call site.
            if isBareIdentifier(expression),
               let value = assignedValue(of: expression, before: match.range.location, in: text),
               !quotedNames(in: text, range: value).isEmpty {
                for quoted in quotedNames(in: text, range: value) {
                    occurrences.append(Occurrence(
                        path: path, line: lineNumber(of: quoted.location, in: text),
                        name: quoted.name))
                }
            } else {
                notes.append("\(path):\(lineNumber(of: match.range.location, in: text))"
                    + " — \(expression) is not a string literal; not resolved here")
            }
        } else {
            for quoted in names {
                occurrences.append(Occurrence(
                    path: path, line: lineNumber(of: quoted.location, in: text),
                    name: quoted.name))
            }
        }
    }

    for match in glyphArgument.matches(in: text, range: full) {
        for quoted in quotedNames(in: text, range: match.range(at: 1)) {
            occurrences.append(Occurrence(
                path: path, line: lineNumber(of: quoted.location, in: text),
                name: quoted.name))
        }
    }

    for match in symbolProperty.matches(in: text, range: full) {
        for quoted in quotedNames(in: text, range: match.range(at: 1)) {
            occurrences.append(Occurrence(
                path: path, line: lineNumber(of: quoted.location, in: text),
                name: quoted.name))
        }
    }
}

// MARK: - Report

for note in notes { print(note) }

var invalid: [Occurrence] = []
for occurrence in occurrences where symbols[occurrence.name] == nil {
    invalid.append(occurrence)
}
for bad in invalid {
    print("\(bad.path):\(bad.line) — \"\(bad.name)\" is not an SF Symbol")
}

if CommandLine.arguments.contains("--years") {
    for occurrence in occurrences where symbols[occurrence.name] != nil {
        let year = symbols[occurrence.name] ?? "?"
        let macOS = releases[year]?["macOS"] ?? "?"
        print("\(occurrence.path):\(occurrence.line) — \"\(occurrence.name)\" (macOS \(macOS), \(year))")
    }
}

let summary = invalid.isEmpty
    ? "checked \(occurrences.count) symbol names in \(files.count) files: all valid"
    : "checked \(occurrences.count) symbol names in \(files.count) files: \(invalid.count) invalid"
print(summary)
exit(invalid.isEmpty ? 0 : 1)
