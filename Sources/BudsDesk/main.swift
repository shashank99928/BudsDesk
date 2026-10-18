import Foundation
import BudsDeskMac

// One binary, several jobs. A command-line mode runs and exits; with no arguments the app opens.
// The check for a mode happens before anything touches the radio, so `--selfcheck` and `--replay`
// are inert with respect to hardware by construction, not by discipline.
if let status = BudsDeskCLI.run(CommandLine.arguments) {
    exit(status)
}

// `main.swift`'s top-level code already runs on the main thread, and `NSApplication.run()` has to
// be entered there anyway, so this is a declaration of what is true rather than a hop.
MainActor.assumeIsolated {
    BudsDeskApp.main()
}
