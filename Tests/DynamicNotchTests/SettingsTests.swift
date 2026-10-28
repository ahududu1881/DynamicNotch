import XCTest
@testable import DynamicNotch

final class SettingsTests: XCTestCase {
    override func tearDown() {
        Settings.shared.resetToDefaults()
        super.tearDown()
    }

    func testDockAndMenuBarIconCanNeverBothBeOff() {
        let s = Settings.shared
        s.showInDock = false
        s.showMenuBarIcon = true
        s.showMenuBarIcon = false
        XCTAssertTrue(s.showInDock, "hiding the menu bar icon brings the Dock icon back so Settings stays reachable")
        s.showInDock = false
        XCTAssertTrue(s.showMenuBarIcon, "hiding the Dock icon brings the menu bar icon back")
    }

    func testDockAndMenuBarIconMayBothBeOn() {
        let s = Settings.shared
        s.showMenuBarIcon = true
        s.showInDock = true
        XCTAssertTrue(s.showInDock && s.showMenuBarIcon)
    }

    func testAPIPortRejectsUnusableValues() {
        let s = Settings.shared
        s.setAPIPort(40_000)
        XCTAssertEqual(s.apiPort, 40_000)
        for bad in [0, 80, 1023, 65_536, 1_000_000, -5] {
            s.setAPIPort(bad)
            XCTAssertEqual(s.apiPort, 40_000, "\(bad) must be ignored")
        }
    }

    func testResetRestoresEverything() {
        let s = Settings.shared
        s.language = AppLanguage.tr.rawValue
        s.showInDock = true
        s.animationSpeed = 1.5
        s.apiToken = "secret"
        s.setAPIPort(41_000)
        s.resetToDefaults()
        XCTAssertEqual(s.language, AppLanguage.system.rawValue)
        XCTAssertFalse(s.showInDock)
        XCTAssertTrue(s.showMenuBarIcon)
        XCTAssertEqual(s.animationSpeed, 1)
        XCTAssertEqual(s.apiToken, "")
        XCTAssertEqual(s.apiPort, 39_283)
        XCTAssertNil(Localization.override)
    }

    func testLanguageOverride() {
        Settings.shared.language = AppLanguage.tr.rawValue
        XCTAssertEqual(L("merhaba", "hello"), "merhaba")
        Settings.shared.language = AppLanguage.en.rawValue
        XCTAssertEqual(L("merhaba", "hello"), "hello")
        Settings.shared.language = AppLanguage.system.rawValue
        XCTAssertNil(Localization.override)
    }

    func testTitleStripSettingIsPersisted() {
        let s = Settings.shared
        s.showTitleStrip = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: "showTitleStrip") as? Bool, false)
        s.resetToDefaults()
        XCTAssertTrue(s.showTitleStrip)
    }
}
