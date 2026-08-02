import AppKit

// SwiftPM builds this target as a plain executable, so there is no Info.plist
// telling AppKit we are an app until `Scripts/bundle-app.sh` wraps it in one.
// Setting the activation policy here means the binary behaves correctly whether
// it is launched from the bundle or straight out of `.build` during development.
let application = NSApplication.shared
application.setActivationPolicy(.regular)

let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.activate(ignoringOtherApps: true)
application.run()
