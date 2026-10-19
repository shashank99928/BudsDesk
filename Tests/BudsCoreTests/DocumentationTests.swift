import XCTest
@testable import BudsCore

/// The README, the changelog and the site all state things about this code: how many checks the
/// self-check runs, which version the bundle builds, which controls actually write, how many
/// models are measured. Those are facts the code already knows, and the failure mode is quiet —
/// prose drifts, a reader acts on it, and nothing fails.
///
/// The sharpest case is the site's structured data. A page can carry `FAQPage` markup that answers
/// questions appearing nowhere on the page: a crawler reads a generous FAQ, a visitor sees less.
/// That is not a hypothetical here — the marked-up questions and the visible ones were the same
/// *subject* and different *words* on every page, and one page had marked-up questions with no
/// visible FAQ at all. `Tools/faq-jsonld.py` builds the markup out of the visible FAQ and these
/// tests refuse to let the two separate again.
final class DocumentationTests: XCTestCase {

    // MARK: - Reading the documents

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()            // Tests/BudsCoreTests
        .deletingLastPathComponent()            // Tests
        .deletingLastPathComponent()            // the package root

    private static let site = root.appendingPathComponent("docs")

    /// Every page the site serves, `404.html` included: the 404 page is in the navigation's
    /// blast radius and its links are as capable of rotting as any other's.
    private static let pages: [URL] = {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: site, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension == "html" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    private func document(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func page(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Every match, as its capture groups. An empty array means the sentence is gone, which fails
    /// the test that wanted it — a rewrite that drops a number must not silently stop checking it.
    private func rows(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            XCTFail("`\(pattern)` is not a valid pattern")
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).map { group in
                guard let found = Range(match.range(at: group), in: text) else { return "" }
                return String(text[found])
            }
        }
    }

    /// The first group of every match, for the patterns that capture one thing.
    private func captures(_ pattern: String, in text: String) -> [String] {
        rows(pattern, in: text).map { $0.first ?? "" }
    }

    // MARK: - The counts the prose states

    func testTheCheckCountInProseMatchesTheCode() throws {
        let result = BudsProtocol.selfCheck()
        XCTAssertTrue(result.passed, "the self-check fails: \(result.failures)")

        // Prose wraps, so the sentence is matched across lines wherever it can be.
        let readme = try document("README.md")
        let stated = try XCTUnwrap(
            captures(#"(\d+) protocol\s+checks against the corpus"#, in: readme).first,
            "the README no longer says how many checks --selfcheck runs")
        XCTAssertEqual(Int(stated), result.checks, "the README's check count is stale")

        // The changelog states the same number for the release that added it, and a reader has no
        // way to tell a stale changelog from a current one.
        let changelog = try document("CHANGELOG.md")
        let released = try XCTUnwrap(
            captures(#"\((\d+) protocol checks\)"#, in: changelog).first,
            "the changelog no longer says how many checks the self-check runs")
        XCTAssertEqual(Int(released), result.checks, "the changelog's check count is stale")
    }

    func testTheVersionTheSiteAndReadmeAdvertiseIsTheVersionTheBundleBuilds() throws {
        let plist = try document("Resources/Info.plist")
        let built = try XCTUnwrap(
            captures(#"CFBundleShortVersionString</key>\s*<string>([0-9.]+)</string>"#, in: plist).first,
            "the bundle version could not be read")

        let readme = try document("README.md")
        XCTAssertEqual(try XCTUnwrap(captures(#"Status: v([0-9.]+)"#, in: readme).first,
                                     "the README no longer states a version"),
                       built, "the README advertises a different version than the bundle builds")

        let home = try page(Self.site.appendingPathComponent("index.html"))
        XCTAssertEqual(try XCTUnwrap(captures(#""softwareVersion": "([0-9.]+)""#, in: home).first,
                                     "the site no longer advertises a version"),
                       built, "the site advertises a different version than the bundle builds")
        XCTAssertEqual(try XCTUnwrap(
            captures(#"Latest release <strong>v([0-9.]+)</strong>"#, in: home).first,
            "the site no longer says which release is current"),
                       built, "the site shows an older release than the one people can download")

        // The changelog's newest heading is the release the version above describes, and a reader
        // with a bug to report looks there first for whether it was already fixed.
        let changelog = try document("CHANGELOG.md")
        XCTAssertEqual(try XCTUnwrap(captures(#"## \[([0-9.]+)\]"#, in: changelog).first,
                                     "the changelog has no released version at the top"),
                       built, "the changelog's newest release is not the version the app is")

        // One download, named once: a reader who finds the app on the site and reads about it in
        // the README must be sent to the same place.
        let download = "https://github.com/shashank99928/BudsDesk/releases/latest/download/BudsDesk.dmg"
        XCTAssertTrue(readme.contains(download), "the README's download link moved")
        XCTAssertTrue(home.contains(download), "the site's download link moved")

        // `--version` asks the bundle when there is one and falls back to this literal when there
        // is not, which is the case `swift run` is in. Two answers to "what version is this" is
        // one answer too many, so they are held together here.
        let cli = try document("Sources/BudsDeskMac/CLI.swift")
        let fallback = try XCTUnwrap(
            captures(#"sourceFallbackVersion = "([0-9.]+)""#, in: cli).first,
            "the CLI no longer carries a version for a build with no bundle to ask")
        XCTAssertEqual(fallback, built,
                       "`swift run` reports \(fallback) and the app is \(built)")
    }

    // MARK: - The site's structured data quotes the site

    private struct Question: Equatable {
        let name: String
        let answer: String
    }

    /// The questions the crawler is told about, in page order.
    private func markedUpFAQ(in page: String) throws -> [Question] {
        var found: [Question] = []
        for block in captures(#"<script type="application/ld\+json">(.*?)</script>"#, in: page) {
            let root = try JSONSerialization.jsonObject(with: Data(block.utf8))
            for node in nodes(in: root) where node["@type"] as? String == "FAQPage" {
                for entry in node["mainEntity"] as? [[String: Any]] ?? [] {
                    guard let name = entry["name"] as? String,
                          let answer = (entry["acceptedAnswer"] as? [String: Any])?["text"] as? String
                    else { continue }
                    found.append(Question(name: name, answer: answer))
                }
            }
        }
        return found
    }

    /// Every dictionary anywhere under a parsed JSON-LD block, following `@graph`.
    private func nodes(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            return [dictionary] + (dictionary["@graph"] as? [Any] ?? []).flatMap { nodes(in: $0) }
        }
        if let array = value as? [Any] {
            return array.flatMap { nodes(in: $0) }
        }
        return []
    }

    /// The FAQ a reader sees, as `(question, answer)` in the order the page shows them.
    private func visibleFAQ(in page: String) -> [Question] {
        guard let block = captures(#"<dl class="faq">(.*?)</dl>"#, in: page).first else { return [] }
        let names = captures(#"<dt>(.*?)</dt>"#, in: block).map(visibleText)
        let answers = captures(#"<dd>(.*?)</dd>"#, in: block).map(visibleText)
        XCTAssertEqual(names.count, answers.count,
                       "a <dt> without a <dd> is a question nobody answered")
        return zip(names, answers).map { Question(name: $0.0, answer: $0.1) }
    }

    /// What the reader's eye lands on: tags gone, entities decoded, runs of space collapsed — the
    /// same normalisation `Tools/faq-jsonld.py` applies, so a wrapped answer and its one-line
    /// markup copy compare equal.
    private func visibleText(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: "<[^>]+>", with: "",
                                                 options: .regularExpression)
        // `&amp;` last: decoding it first would turn `&amp;lt;` into a tag boundary.
        for (entity, character) in ["&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
                                    "&nbsp;": " ", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
                                    "&lt;": "<", "&gt;": ">", "&amp;": "&"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testTheMarkedUpFAQIsTheFAQThePageShows() throws {
        var checked = 0
        for url in Self.pages {
            let name = url.lastPathComponent
            let body = try page(url)
            let marked = try markedUpFAQ(in: body)
            let shown = visibleFAQ(in: body)

            if marked.isEmpty && shown.isEmpty { continue }
            XCTAssertFalse(marked.isEmpty,
                           "\(name) shows a FAQ with no structured data; run Tools/faq-jsonld.py")
            XCTAssertFalse(shown.isEmpty,
                           "\(name) marks up a FAQ that is not on the page — write it out or delete "
                           + "the block; markup a visitor cannot see is an overclaim")
            XCTAssertEqual(marked.count, shown.count,
                           "\(name): \(marked.count) questions marked up, \(shown.count) on the page")
            for (index, question) in marked.enumerated() where index < shown.count {
                XCTAssertEqual(question.name, shown[index].name,
                               "\(name) question \(index + 1): markup and page disagree")
                XCTAssertEqual(question.answer, shown[index].answer,
                               "\(name) answer \(index + 1): markup and page disagree")
            }
            checked += marked.count
        }
        XCTAssertGreaterThanOrEqual(checked, 20,
                                    "the site lost its FAQ, so this test stopped checking anything")
    }

    func testNoPageMarksUpAReviewNobodyWrote() throws {
        for url in Self.pages {
            let body = try page(url)
            for claim in ["aggregateRating", "ratingValue", "reviewCount", "\"@type\": \"Review\""] {
                XCTAssertFalse(body.contains(claim),
                               "\(url.lastPathComponent) carries `\(claim)`; nobody has reviewed "
                               + "this app, so there is no rating to mark up")
            }
        }
    }

    // MARK: - The site's own links

    func testEveryInternalLinkAndAssetResolvesToAFileThatShips() throws {
        var checked = 0
        for url in Self.pages {
            let body = try page(url)

            // Navigation and prose links, written absolute so the pages can live at any depth.
            let links = captures(#"(?:href|src)="/BudsDesk/([^#"?]*)""#, in: body)
            // A page's own assets, written relative. A missing one draws nothing at all, which is
            // the kind of absence nobody reports as a bug.
            let assets = captures(#"(?:href|src)="(assets/[^"]+)""#, in: body)

            for target in Set(links + assets) {
                let file = Self.site.appendingPathComponent(target.isEmpty ? "index.html" : target)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                              "\(url.lastPathComponent) refers to \(target), which does not ship")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 8,
                                    "the navigation and the pages stopped referring to anything")
    }

    func testTheSitemapListsEveryPageAndNothingElse() throws {
        let sitemap = try document("docs/sitemap.xml")
        let listed = Set(captures(#"<loc>https://shashank99928\.github\.io/BudsDesk/([^<]*)</loc>"#,
                                  in: sitemap).map { $0.isEmpty ? "index.html" : $0 })
        let shipped = Set(Self.pages.map(\.lastPathComponent)).subtracting(["404.html"])
        XCTAssertEqual(listed, shipped,
                       "a page a search engine is told about and a page that ships have diverged")
    }

    // MARK: - One value, in every form it is written

    /// The control service UUID was wrong here for the life of the repository. The byte array the
    /// app opens the channel with was right; the *string* form of that same constant was one digit
    /// off, and the string is the half that got published — into the registry that gates matching,
    /// the protocol spec, the recording's own provenance, the docs and the site. No test caught it
    /// because the registry's UUID check compares the registry to our own constant, so a pair of
    /// self-consistent errors agreed with itself forever.
    ///
    /// So this checks the two forms against each other *and* against the one value read off the
    /// earbuds. See `EVIDENCE.md`, fact 1, and `capture/sdp-oneplus-buds-4-2026-10-19.txt`.
    func testTheControlServiceHasOneValueInBothForms() throws {
        // Read from the OnePlus Buds 4's own SDP record. It is written out rather than derived,
        // because the device is the only authority for it: changing this line means reading the
        // hardware again, not editing the code until the test passes.
        let measured = "0000079a-d102-11e1-9b23-00025b00a5a5"

        let source = try document("Sources/BudsDeskMac/DeviceCatalog.swift")

        let byteBlock = try XCTUnwrap(
            captures(#"controlServiceUUIDBytes: \[UInt8\] = \[(.*?)\]"#, in: source).first,
            "controlServiceUUIDBytes is gone from DeviceCatalog.swift")
        let bytes = captures(#"0x([0-9a-fA-F]{2})"#, in: byteBlock).compactMap { UInt8($0, radix: 16) }
        XCTAssertEqual(bytes.count, 16, "the byte form of the control UUID is not sixteen bytes")
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let asUUID = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))"
            + "-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"

        let literal = try XCTUnwrap(
            captures(#"controlServiceUUIDString: String \{ "([^"]+)" \}"#, in: source).first,
            "controlServiceUUIDString is gone from DeviceCatalog.swift")

        XCTAssertEqual(literal, asUUID,
                       "the string form and the byte form of the control UUID disagree: the bytes "
                       + "open the channel and the string is what gets published")
        XCTAssertEqual(literal, measured,
                       "the control UUID no longer matches the earbuds' SDP record — read the "
                       + "device again before changing this, and update EVIDENCE.md")
    }

    /// Everything that *publishes* the control UUID has to publish the same one: the registry that
    /// gates matching, the recording's provenance, the protocol spec and the docs. The sweep is
    /// deliberately blunt — every UUID on the vendor's base `-d102-11e1-9b23-00025b00a5a5` in a
    /// published file must be the measured one — because the original defect was one digit inside
    /// such a string, which no reader notices and no link checker sees.
    ///
    /// `EVIDENCE.md` is excluded on purpose: it documents the whole UUID family the vendor's own
    /// app references, most of which this project does not speak to.
    func testNothingPublishedCarriesADifferentControlServiceUUID() throws {
        let measured = "0000079a-d102-11e1-9b23-00025b00a5a5"

        var files = ["SCOPE.md", "capture/README.md", "protocol/PROTOCOL.md", "protocol/spec.yaml",
                     "devices/README.md", "devices/oneplus-buds-4.json", "devices/generic-family.json"]
        files += Self.pages.map { "docs/\($0.lastPathComponent)" }

        for path in files {
            let text = try document(path)
            for uuid in captures(#"([0-9a-fA-F]{8}-d102-11e1-9b23-00025b00a5a5)"#, in: text) {
                XCTAssertEqual(uuid.lowercased(), measured,
                               "\(path) publishes a control service UUID the earbuds do not advertise")
            }
        }

        // The two machine-read sources, where a wrong value is not merely published but *used*.
        let registry = try CapabilityRegistry.load(from: Self.root.appendingPathComponent("devices"))
        for profile in registry.profiles {
            XCTAssertEqual(profile.match.serviceUUIDs, [measured],
                           "\(profile.id) gates matching on a different UUID")
        }
        for recording in CaptureCorpus.recordings {
            XCTAssertEqual(recording.provenance.serviceUUID, measured,
                           "\(recording.provenance.id) records a different UUID")
        }
    }

    /// The navigation is the site's map and it is copied into every page, which is the arrangement
    /// that drifts: one page gains a link, another loses one, and both still look finished. The
    /// current page is marked on the page it is current for, so that is the one thing allowed to
    /// differ between two copies.
    func testEveryPageCarriesTheSameNavigation() throws {
        var navigation: [String: String] = [:]
        for url in Self.pages {
            let body = try page(url)
            let nav = try XCTUnwrap(
                captures(#"<nav class="site" aria-label="Main">(.*?)</nav>"#, in: body).first?
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .replacingOccurrences(of: #" aria-current="page""#, with: ""),
                "\(url.lastPathComponent) has no main navigation")
            navigation[url.lastPathComponent] = nav
        }

        let distinct = Set(navigation.values)
        XCTAssertEqual(distinct.count, 1,
                       "the pages disagree about the navigation: "
                       + navigation.filter { $0.value != distinct.first }.keys.sorted()
                           .joined(separator: ", "))

        let shared = try XCTUnwrap(distinct.first)
        for brand in ["oneplus-buds-on-mac.html", "oppo-buds-on-mac.html", "realme-buds-on-mac.html"] {
            XCTAssertTrue(shared.contains("/BudsDesk/\(brand)"),
                          "the navigation no longer reaches \(brand)")
        }
    }

    /// A brand page is a page about models nobody has recorded here, which makes it exactly the
    /// page that could quietly imply support it cannot back. So every one has to carry the download
    /// and send the reader to the page that spells out what measured, inferred and unconfirmed
    /// mean — and a brand with no measured model has to say `read-only` rather than leave the
    /// absence to be inferred.
    func testEveryBrandPageSaysWhatIsNotMeasured() throws {
        let download = "https://github.com/shashank99928/BudsDesk/releases/latest/download/BudsDesk.dmg"
        let registry = try CapabilityRegistry.load(from: Self.root.appendingPathComponent("devices"))
        let measuredVendors = Set(registry.profiles.filter { $0.match.fallback != true }.map(\.vendor))

        let brands = [("oneplus-buds-on-mac.html", "OnePlus"),
                      ("oppo-buds-on-mac.html", "OPPO"),
                      ("realme-buds-on-mac.html", "realme")]

        for (name, vendor) in brands {
            let body = try page(Self.site.appendingPathComponent(name))
            XCTAssertTrue(body.contains(download), "\(name) does not carry the download link")
            XCTAssertTrue(body.contains(#"href="/BudsDesk/models.html""#),
                          "\(name) does not send the reader to the model list, which is where the "
                          + "three evidence levels are explained")
            if !measuredVendors.contains(vendor) {
                XCTAssertTrue(body.lowercased().contains("read-only"),
                              "\(name) is about \(vendor) earbuds, no \(vendor) model is measured, "
                              + "and the page never says read-only")
            }
        }
    }

    // MARK: - The site's support claims

    /// The table on the home page is the closest thing the site has to a specification, and the
    /// registry is the thing that decides what is actually on screen. If the site shows four
    /// controls that write, the registry had better have four write paths.
    func testTheFeatureTableClaimsNoWriteTheRegistryCannotBack() throws {
        let registry = try CapabilityRegistry.load(from: Self.root.appendingPathComponent("devices"))
        let profile = try XCTUnwrap(registry.profile(id: "oneplus-buds-4"),
                                    "the model the site's table is about is not in the registry")
        let writable = Capability.allCases.filter { profile.canWrite($0) }
        let readable = Capability.allCases.filter { profile.offers($0) }

        let home = try page(Self.site.appendingPathComponent("index.html"))
        let table = rows(#"<tr><td>([^<]*)</td><td class="yes">([^<]*)</td>"#
                         + #"<td class="(?:no|partial)">([^<]*)</td></tr>"#, in: home)
        XCTAssertGreaterThanOrEqual(table.count, 10,
                                    "the feature table changed shape, so this test is checking "
                                    + "nothing — update the pattern with it")
        let features = table.map { (feature: $0[0], ours: $0[1], family: $0[2]) }

        let writes = features.filter { $0.ours.contains("writes") }
        XCTAssertEqual(writes.count, writable.count,
                       "the site shows \(writes.count) controls that write: "
                       + "\(writes.map(\.feature)); the registry has \(writable.count): "
                       + "\(writable.map(\.rawValue).sorted())")

        let reads = features.filter { $0.ours.contains("Measured") }
        XCTAssertLessThanOrEqual(reads.count, readable.count,
                                 "the site claims more measured reads than the registry offers")

        for row in features {
            XCTAssertFalse(row.family.contains("Measured") || row.family.contains("writes"),
                           "the table offers the rest of the family `\(row.family)` for "
                           + "\(row.feature), which no recording backs")
        }
    }

    /// "One model measured end to end" is the claim the whole project rests on, and it is the one
    /// that goes stale first: a second model gets recorded and the prose keeps apologising for a
    /// gap that no longer exists.
    func testTheNumberOfMeasuredModelsIsTheNumberTheProseStates() throws {
        let registry = try CapabilityRegistry.load(from: Self.root.appendingPathComponent("devices"))
        let measured = registry.profiles.filter { $0.match.fallback != true }

        let spelled = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]
        for (path, pattern) in [
            ("README.md", #"Status: v[0-9.]+, (\w+) models? verified"#),
            ("docs/models.html", #"(\w+) models? is measured end to end"#),
        ] {
            let stated = try XCTUnwrap(captures(pattern, in: try document(path)).first,
                                       "\(path) no longer states how many models are measured")
            let count = try XCTUnwrap(spelled[stated.lowercased()] ?? Int(stated),
                                      "\(path) states `\(stated)`, which is not a number of models")
            XCTAssertEqual(count, measured.count,
                           "\(path) says \(stated); the registry has \(measured.count) measured "
                           + "profile(s): \(measured.map(\.id).sorted())")
        }

        // And a measured model nobody wrote down is a model nobody can find.
        let readme = try document("README.md")
        for profile in measured {
            XCTAssertTrue(readme.contains(profile.model),
                          "the registry measures \(profile.model) and the README never names it")
        }
    }
}
