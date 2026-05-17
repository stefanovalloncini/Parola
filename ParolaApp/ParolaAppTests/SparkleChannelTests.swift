import Foundation
import Testing
@testable import Parola

@Suite("SparkleChannel allow-list")
struct SparkleChannelTests {
    @Test(
        "allowedChannels maps each channel to its filter",
        arguments: [
            (SparkleChannel.stable, Set<String>()),
            (.rc,    Set(["rc"])),
            (.daily, Set(["rc", "daily"])),
        ]
    )
    func allowedChannelsMapping(channel: SparkleChannel, expected: Set<String>) {
        #expect(channel.allowedChannels == expected)
    }

    @Test("stable returns the empty set so Sparkle ships unchanneled items only")
    func stableHasEmptyAllowList() {
        #expect(SparkleChannel.stable.allowedChannels.isEmpty)
    }

    @Test("daily is a superset of rc")
    func dailyContainsRc() {
        #expect(SparkleChannel.daily.allowedChannels.isSuperset(of: SparkleChannel.rc.allowedChannels))
    }

    @Test("rawValue round-trips")
    func rawValueRoundTrip() {
        for channel in SparkleChannel.allCases {
            #expect(SparkleChannel(rawValue: channel.rawValue) == channel)
        }
    }

    @Test("ids are unique")
    func idsUnique() {
        let ids = SparkleChannel.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
