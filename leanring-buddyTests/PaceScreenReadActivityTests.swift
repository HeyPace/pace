import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceScreenReadActivityTests {
    @Test func overlappingReadsRemainVisibleUntilTheLastReadEnds() {
        let activity = PaceScreenReadActivity()
        #expect(!activity.isReading)
        let firstReadIdentifier = activity.beginReading()
        let secondReadIdentifier = activity.beginReading()
        activity.endReading(firstReadIdentifier)
        #expect(activity.isReading)
        activity.endReading(firstReadIdentifier)
        #expect(activity.isReading)
        activity.endReading(secondReadIdentifier)
        #expect(!activity.isReading)
    }

    @Test func failedReadClearsItsIndicatorWithoutAVisualDelay() async {
        enum FixtureError: Error { case unavailable }
        let activity = PaceScreenReadActivity()
        do {
            try await activity.whileReading {
                #expect(activity.isReading)
                throw FixtureError.unavailable
            }
            Issue.record("Expected the read failure")
        } catch {
            #expect(!activity.isReading)
        }
    }

    @Test func cancelledReadReleasesOnlyItsOwnActivity() async {
        let activity = PaceScreenReadActivity()
        let otherReadIdentifier = activity.beginReading()
        let readingTask = Task {
            try await activity.whileReading {
                try Task.checkCancellation()
            }
        }
        readingTask.cancel()
        do {
            try await readingTask.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(activity.isReading)
        activity.endReading(otherReadIdentifier)
        #expect(!activity.isReading)
    }
}
