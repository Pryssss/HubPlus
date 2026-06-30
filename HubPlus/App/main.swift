import AppKit

// A plain AppKit entry point is more predictable than a SwiftUI `App` with only a
// Settings scene for an accessory app. Top-level code is not implicitly main-actor
// in Swift-5 language mode, but the process starts on the main thread, so it is safe
// to assert main-actor isolation here to construct the @MainActor delegate.
let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
