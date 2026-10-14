import XCTest

/// Apple's reviewer's path through the public demo server, as the TestFlight
/// review notes give it: a fresh app, the demo's address typed on the first
/// screen, the demo account signed in, then music, a film, a book and photos
/// opened. A picture of each step goes to DEMO_SHOTS. The address and account
/// are the private repo's (DEMO.md), passed in, never written here:
///
///   TEST_RUNNER_DEMO_ADDRESS=... TEST_RUNNER_DEMO_USER=demo TEST_RUNNER_DEMO_PASSWORD=... \
///   TEST_RUNNER_DEMO_SHOTS=/some/folder xcodebuild test ... -only-testing:SoundStormUITests/DemoReviewTests
///
/// Skipped without them.
@MainActor
final class DemoReviewTests: XCTestCase {
    private var app: XCUIApplication!
    private var shots = ""
    private var step = 0

    func testTheReviewersPath() throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["DEMO_ADDRESS"], let user = env["DEMO_USER"], let password = env["DEMO_PASSWORD"] else {
            throw XCTSkip("No demo server given")
        }
        shots = env["DEMO_SHOTS"] ?? NSTemporaryDirectory()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-serverURL", ""]
        app.launch()

        // 1. The address on the first screen, then Connect (Return).
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no address box on the first screen")
        snap("first screen")
        focus(field)
        field.typeText(address + "\n")

        // 2. The demo account on the server's sign-in page.
        let web = app.webViews.firstMatch
        let username = web.textFields.firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 30), "the server's sign-in page never appeared")
        snap("sign-in page")
        focus(username)
        username.typeText(user)
        let pw = web.secureTextFields.firstMatch
        focus(pw)
        pw.typeText(password + "\n")

        // Whatever the app or page asks first is answered as a reviewer might.
        XCTAssertTrue(web.buttons["Music"].waitForExistence(timeout: 30), "never got past signing in")
        snap("signed in")
        for _ in 0..<3 {
            let alert = app.alerts.firstMatch
            if alert.waitForExistence(timeout: 4) {
                snap("asked: " + alert.label)
                (alert.buttons["Not mine"].exists ? alert.buttons["Not mine"] : alert.buttons.firstMatch).tap()
            }
            for word in ["Not now", "Skip the rest of the welcome", "No thanks"] {
                let b = web.buttons[word]
                if b.exists && b.isHittable { b.tap() }
            }
        }
        snap("home")

        // 3. Music: an album opened from Home, its first song played.
        open(web, tab: "Home")
        tapText(web, "Chopin: Piano Works")
        snap("album")
        let play = web.buttons.matching(NSPredicate(format: "label ENDSWITH %@ AND NOT (label CONTAINS[c] %@)", "Play", "Play on")).firstMatch
        if play.waitForExistence(timeout: 8) { play.tap() } else { XCTFail("no Play on the album") }
        sleep(10)
        snap("now playing")
        app.swipeDown()
        sleep(2)
        snap("music playing on")

        // 4. Watch: a film played.
        open(web, tab: "Watch")
        tapText(web, "Big Buck Bunny")
        sleep(12)
        snap("film playing")
        let close = web.buttons.matching(NSPredicate(format: "label ==[c] %@", "Close")).firstMatch
        if close.exists && close.isHittable { close.tap() }
        sleep(2)

        // 5. Books, 6. Photos.
        open(web, tab: "Books")
        snap("books")
        open(web, tab: "Photos")
        sleep(3)
        snap("photos")
    }

    private func open(_ web: XCUIElement, tab: String) {
        let b = web.buttons[tab]
        if b.waitForExistence(timeout: 8) { b.tap() } else { XCTFail("no \(tab) tab") }
        sleep(3)
    }

    private func tapText(_ web: XCUIElement, _ text: String) {
        let t = web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
            .allElementsBoundByIndex.first { $0.isHittable } ?? web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if t.waitForExistence(timeout: 10) { t.tap() } else { XCTFail("no \(text)") }
        sleep(4)
    }

    private func tapFirstCover(_ web: XCUIElement) {
        let covers = web.images.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.width > 80 }
        if let first = covers.first { first.tap() } else { XCTFail("nothing to open on this page") }
        sleep(3)
    }

    private func snap(_ name: String) {
        step += 1
        let data = app.screenshot().pngRepresentation
        let file = URL(fileURLWithPath: shots).appending(path: String(format: "%02d %@.png", step, name.replacingOccurrences(of: "/", with: "-")))
        try? data.write(to: file)
    }

    private func focus(_ field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            field.tap()
            for _ in 0..<10 {
                if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
}
