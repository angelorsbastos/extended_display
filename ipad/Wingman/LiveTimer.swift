import ActivityKit
import Foundation

/// Starts, updates and ends the Dock timer's Live Activity (TimerActivity,
/// drawn by the widget extension).
@available(iOS 16.2, *)
enum LiveTimer {
    static func show(_ state: TimerActivity.ContentState, active: Bool) async {
        let current = Activity<TimerActivity>.activities
        guard active else {
            for activity in current {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        // stale once it should have ended: iOS greys it out if nobody updates it
        let content = ActivityContent(state: state, staleDate: state.end)
        if state.finished {
            for activity in current {
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(5 * 60)))
            }
        } else if let activity = current.first {
            await activity.update(content)
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: TimerActivity(), content: content)
        }
    }
}
