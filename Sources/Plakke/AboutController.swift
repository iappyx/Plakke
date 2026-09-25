import AppKit

enum AboutController {
    static let author = "iappyx"
    static let year = "2026"

    /// Native About panel: icon, name, version, copyright, and a short credits block.
    static func show() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Plakke"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6

        let credits = NSMutableAttributedString()
        func line(_ s: String, _ font: NSFont, _ color: NSColor = .labelColor) {
            credits.append(NSAttributedString(string: s + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: para,
            ]))
        }
        line("Hold \(Hotkey.current.modifierSymbols), tap \(Hotkey.current.keyName), release to paste.", .systemFont(ofSize: 12, weight: .medium))
        line("A ⌘Tab-style clipboard switcher for macOS. Plakke is Frisian for \"paste\".", .systemFont(ofSize: 11), .secondaryLabelColor)
        line("", .systemFont(ofSize: 4))
        line("Made by \(author)", .systemFont(ofSize: 11), .secondaryLabelColor)
        line("Released under the MIT License.", .systemFont(ofSize: 11), .secondaryLabelColor)
        line("Local only · no accounts · no telemetry", .systemFont(ofSize: 10), .tertiaryLabelColor)

        // An accessory app has to activate to put a window on screen, and it has to stay active for
        // that window to remain visible — so there is no "show the panel but give focus back".
        // Hiding the app afterwards hid the panel along with it.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: name,
            .applicationVersion: "\(version) (\(build))",
            .version: "",
            .credits: credits,
            .applicationIcon: NSApp.applicationIconImage as Any,
        ])
    }
}
