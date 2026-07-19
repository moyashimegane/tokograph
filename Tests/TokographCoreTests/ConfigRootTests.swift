import XCTest
@testable import TokographCore

final class ConfigRootTests: XCTestCase {
    private let home = URL(fileURLWithPath: NSHomeDirectory())
    private var tmpDir: URL!
    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmpDir) }

    func testDefaultWhenNothingSet() {
        let r = ConfigRoot.resolve(defaultsValue: nil, env: [:], home: home)
        XCTAssertEqual(r, .resolved(home.appendingPathComponent(".claude")))
    }
    func testDefaultsOverrideValidDir() {
        let r = ConfigRoot.resolve(defaultsValue: tmpDir.path, env: [:], home: home)
        XCTAssertEqual(r, .resolved(URL(fileURLWithPath: tmpDir.path)))
    }
    func testDefaultsTakesPrecedenceOverEnv() {
        let r = ConfigRoot.resolve(defaultsValue: tmpDir.path,
                                   env: ["CLAUDE_CONFIG_DIR": "/nonexistent"], home: home)
        XCTAssertEqual(r, .resolved(URL(fileURLWithPath: tmpDir.path)))
    }
    func testEnvOverrideValidDir() {
        let r = ConfigRoot.resolve(defaultsValue: nil, env: ["CLAUDE_CONFIG_DIR": tmpDir.path], home: home)
        XCTAssertEqual(r, .resolved(URL(fileURLWithPath: tmpDir.path)))
    }
    func testRelativeOverrideIsConfigError() {
        XCTAssertEqual(ConfigRoot.resolve(defaultsValue: "relative/path", env: [:], home: home), .configError)
    }
    func testNonexistentOverrideIsConfigErrorNotFallback() {
        XCTAssertEqual(ConfigRoot.resolve(defaultsValue: "/nonexistent/\(UUID().uuidString)",
                                          env: [:], home: home), .configError)
    }
    func testOverridePointingToFileIsConfigError() throws {
        let f = tmpDir.appendingPathComponent("file.txt")
        try Data().write(to: f)
        XCTAssertEqual(ConfigRoot.resolve(defaultsValue: f.path, env: [:], home: home), .configError)
    }
    func testTildeExpansion() {
        let r = ConfigRoot.resolve(defaultsValue: "~", env: [:], home: home)
        XCTAssertEqual(r, .resolved(URL(fileURLWithPath: NSHomeDirectory())))
    }
    func testEmptyDefaultsOverrideIsConfigError() {
        XCTAssertEqual(ConfigRoot.resolve(defaultsValue: "", env: [:], home: home), .configError)
    }
    func testEmptyEnvOverrideIsConfigError() {
        XCTAssertEqual(ConfigRoot.resolve(defaultsValue: nil, env: ["CLAUDE_CONFIG_DIR": ""], home: home), .configError)
    }
}
