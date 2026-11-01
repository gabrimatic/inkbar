// The Control Center and menu bar control for Inkbar. Its action, ToggleInkbarIntent, is
// shared with the app and runs only in the app's own process, so pausing and resuming
// never crosses an unauthenticated channel.
import AppIntents
import SwiftUI
import WidgetKit

@main
struct InkbarControls: WidgetBundle {
    var body: some Widget {
        PauseControl()
    }
}

struct PauseControl: ControlWidget {
    static let kind = "info.gabrimatic.inkbar.toggle"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleInkbarIntent()) {
                Label("Pause or Resume Inkbar", systemImage: "pause.circle")
            }
        }
        .displayName("Inkbar")
        .description("Pauses or resumes the Inkbar action bar.")
    }
}
