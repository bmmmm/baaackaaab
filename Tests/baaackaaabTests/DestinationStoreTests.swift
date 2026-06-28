import XCTest
@testable import baaackaaab

// The on-disk destination store and the resolution order. Every test relocates
// the support dir to a throwaway directory via BAAACKAAAB_SUPPORT_DIR (read live
// by CredentialFiles.dir), so the real credential store is never touched, and
// clears any inherited RESTIC_* vars so resolution is deterministic and the
// Keychain fallback branch is never reached.
final class DestinationStoreTests: XCTestCase {

    private var supportDir: URL!

    override func setUp() {
        super.setUp()
        supportDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-store-\(UUID().uuidString)", isDirectory: true)
        setenv("BAAACKAAAB_SUPPORT_DIR", supportDir.path, 1)
        for v in ["RESTIC_REPOSITORY", "RESTIC_REPOSITORY_FILE", "RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE"] {
            unsetenv(v)
        }
    }

    override func tearDown() {
        unsetenv("BAAACKAAAB_SUPPORT_DIR")
        supportDir = nil
        super.tearDown()
    }

    /// Write a string to an arbitrary path, creating intermediate directories.
    /// CredentialFiles.write only creates the top-level support dir, so it can't
    /// be used to seed a nested destinations/<name>/ file directly.
    private func writeFile(_ s: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: url)
    }

    // MARK: - validName (pure)

    func testValidNameAccepts() {
        for n in ["default", "offsite-1", "a.b_c", "ABC123"] {
            XCTAssertTrue(DestinationStore.validName(n), n)
        }
    }

    func testValidNameRejects() {
        for n in ["", ".hidden", "a/b", "a b", "naïve", "a\tb"] {
            XCTAssertFalse(DestinationStore.validName(n), n)
        }
    }

    // MARK: - envOverlay (pure)

    func testEnvOverlayFileRepoAndPassword() {
        let d = Destination(name: "d", link: "l", order: 0, enabled: true,
                            repo: .file(URL(fileURLWithPath: "/x/url")),
                            password: .file(URL(fileURLWithPath: "/x/pw")))
        XCTAssertEqual(d.envOverlay,
                       ["RESTIC_REPOSITORY_FILE": "/x/url", "RESTIC_PASSWORD_FILE": "/x/pw"])
    }

    func testEnvOverlayValueRepoAndUnsetPassword() {
        let d = Destination(name: "d", link: "l", order: 0, enabled: true,
                            repo: .value("rest:https://h/r/"), password: .unset)
        XCTAssertEqual(d.envOverlay, ["RESTIC_REPOSITORY": "rest:https://h/r/"])
    }

    // MARK: - add / load / names / remove

    func testAddThenLoadAndNames() throws {
        try DestinationStore.add(name: "offsite", repoURL: "rest:https://h/offsite/",
                                 password: "key1", link: "wan", order: 5, enabled: false)
        XCTAssertEqual(DestinationStore.names(), ["offsite"])
        let d = try XCTUnwrap(DestinationStore.load("offsite"))
        XCTAssertEqual(d.name, "offsite")
        XCTAssertEqual(d.link, "wan")
        XCTAssertEqual(d.order, 5)
        XCTAssertFalse(d.enabled)
        XCTAssertEqual(d.displayURL, "rest:https://h/offsite/")
        XCTAssertTrue(d.passwordAvailable)
    }

    func testAddDuplicateThrows() throws {
        try DestinationStore.add(name: "dup", repoURL: "rest:https://h/d/",
                                 password: "k", link: "default", order: nil, enabled: true)
        XCTAssertThrowsError(try DestinationStore.add(
            name: "dup", repoURL: "rest:https://h/d2/", password: "k2",
            link: "default", order: nil, enabled: true))
    }

    func testAddInvalidNameThrows() {
        XCTAssertThrowsError(try DestinationStore.add(
            name: "bad/name", repoURL: "rest:https://h/x/", password: "k",
            link: "default", order: nil, enabled: true))
    }

    func testRemoveDeletesLocalPointer() throws {
        try DestinationStore.add(name: "gone", repoURL: "rest:https://h/g/",
                                 password: "k", link: "default", order: nil, enabled: true)
        XCTAssertTrue(try DestinationStore.remove(name: "gone"))
        XCTAssertEqual(DestinationStore.names(), [])
        XCTAssertFalse(try DestinationStore.remove(name: "gone"))   // already gone
    }

    func testAutoOrderIncrements() throws {
        try DestinationStore.add(name: "a", repoURL: "rest:https://h/a/", password: "k",
                                 link: "default", order: nil, enabled: true)
        try DestinationStore.add(name: "b", repoURL: "rest:https://h/b/", password: "k",
                                 link: "default", order: nil, enabled: true)
        let a = try XCTUnwrap(DestinationStore.load("a"))
        let b = try XCTUnwrap(DestinationStore.load("b"))
        XCTAssertEqual(a.order, 0)
        XCTAssertEqual(b.order, 1)
    }

    // MARK: - Legacy migration

    func testAddMigratesLegacySingleRepoToDefault() throws {
        try CredentialFiles.write("rest:https://h/legacy/", to: CredentialFiles.repoURLFile)
        try CredentialFiles.write("legacykey", to: CredentialFiles.repoPasswordFile)
        XCTAssertTrue(CredentialFiles.present)
        XCTAssertEqual(DestinationStore.names(), [])

        try DestinationStore.add(name: "offsite", repoURL: "rest:https://h/offsite/",
                                 password: "k2", link: "wan", order: nil, enabled: true)

        XCTAssertEqual(DestinationStore.names(), ["default", "offsite"])
        let def = try XCTUnwrap(DestinationStore.load("default"))
        XCTAssertEqual(def.displayURL, "rest:https://h/legacy/")
        // Legacy top-level files are removed once migrated (one copy of the key).
        XCTAssertFalse(CredentialFiles.present)
    }

    // MARK: - meta.json tolerance

    func testMissingMetaYieldsDefaults() throws {
        // Write only url + password files (no meta.json), as a hand-built dest.
        try writeFile("rest:https://h/m/", to: DestinationStore.urlFile("m"))
        try writeFile("k", to: DestinationStore.passwordFile("m"))
        let d = try XCTUnwrap(DestinationStore.load("m"))
        XCTAssertEqual(d.link, "default")
        XCTAssertEqual(d.order, 0)
        XCTAssertTrue(d.enabled)
    }

    func testPartialMetaKeepsPresentFields() throws {
        let meta = DestinationMeta(link: "default", order: 0, enabled: true)
        try DestinationStore.writeMeta(meta, to: "p")
        // Overwrite meta.json with a partial object missing two keys.
        try writeFile(#"{ "enabled": false }"#, to: DestinationStore.metaFile("p"))
        try writeFile("rest:https://h/p/", to: DestinationStore.urlFile("p"))
        try writeFile("k", to: DestinationStore.passwordFile("p"))
        let d = try XCTUnwrap(DestinationStore.load("p"))
        XCTAssertFalse(d.enabled)            // present key honored
        XCTAssertEqual(d.link, "default")    // absent keys default, not reset to nil
        XCTAssertEqual(d.order, 0)
    }

    // MARK: - DestinationMeta decode (pure)

    func testDestinationMetaDecodeTolerance() throws {
        let empty = try JSONDecoder().decode(DestinationMeta.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.link, "default")
        XCTAssertEqual(empty.order, 0)
        XCTAssertTrue(empty.enabled)

        let full = try JSONDecoder().decode(DestinationMeta.self,
            from: Data(#"{ "link": "wan", "order": 3, "enabled": false }"#.utf8))
        XCTAssertEqual(full.link, "wan")
        XCTAssertEqual(full.order, 3)
        XCTAssertFalse(full.enabled)
    }

    // MARK: - resolve precedence (no Keychain branch)

    func testResolveExplicitRepoWins() {
        setenv("RESTIC_PASSWORD", "p", 1)   // so adHocPassword never reaches Keychain
        defer { unsetenv("RESTIC_PASSWORD") }
        let dests = DestinationStore.resolve(explicitRepo: "rest:https://h/adhoc/")
        XCTAssertEqual(dests.count, 1)
        XCTAssertEqual(dests.first?.name, "explicit")
        if case .value(let v) = dests.first!.repo {
            XCTAssertEqual(v, "rest:https://h/adhoc/")
        } else {
            XCTFail("expected an explicit value repo")
        }
    }

    func testResolveEmptyExplicitIsTreatedAsAbsent() throws {
        try DestinationStore.add(name: "stored", repoURL: "rest:https://h/s/", password: "k",
                                 link: "default", order: nil, enabled: true)
        // An empty --restic-repo must not shadow the stored destinations.
        let dests = DestinationStore.resolve(explicitRepo: "")
        XCTAssertEqual(dests.map { $0.name }, ["stored"])
    }

    func testResolveFallsBackToStored() throws {
        try DestinationStore.add(name: "stored", repoURL: "rest:https://h/s/", password: "k",
                                 link: "default", order: nil, enabled: true)
        XCTAssertEqual(DestinationStore.resolve(explicitRepo: nil).map { $0.name }, ["stored"])
    }

    func testResolveEnabledFiltersDisabled() throws {
        try DestinationStore.add(name: "on", repoURL: "rest:https://h/on/", password: "k",
                                 link: "default", order: 0, enabled: true)
        try DestinationStore.add(name: "off", repoURL: "rest:https://h/off/", password: "k",
                                 link: "default", order: 1, enabled: false)
        XCTAssertEqual(DestinationStore.resolve(explicitRepo: nil).map { $0.name }, ["on", "off"])
        XCTAssertEqual(DestinationStore.resolveEnabled(explicitRepo: nil).map { $0.name }, ["on"])
    }
}
