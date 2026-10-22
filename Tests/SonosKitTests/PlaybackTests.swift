import Foundation
import Testing
@testable import SonosKit

private let trackDIDL = """
<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
<item id="-1" parentID="-1"><res>x-sonos-spotify:abc</res><upnp:albumArtURI>/getaa?s=1&amp;u=x</upnp:albumArtURI>\
<dc:title>Teardrop</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class>\
<dc:creator>Massive Attack</dc:creator><upnp:album>Mezzanine</upnp:album></item></DIDL-Lite>
"""

@Test func parsesQueueTrack() {
    let np = NowPlaying.parse(state: "PLAYING", mediaURI: "x-rincon-queue:RINCON_X#0", mediaMeta: "",
                              trackURI: "x-sonos-spotify:abc", trackMeta: trackDIDL)
    #expect(np.source == .queue && np.isPlaying && np.canSkip)
    #expect(np.title == "Teardrop" && np.artist == "Massive Attack" && np.album == "Mezzanine")
    #expect(np.artURL(device: "10.0.0.6")?.absoluteString == "http://10.0.0.6:1400/getaa?s=1&u=x")
}

@Test func parsesTVAndGrouped() {
    let tv = NowPlaying.parse(state: "PLAYING", mediaURI: "x-sonos-htastream:\(BAR):spdif", mediaMeta: nil,
                              trackURI: "", trackMeta: "NOT_IMPLEMENTED")
    #expect(tv.source == .tv && tv.title == "TV" && !tv.canSkip)
    let g = NowPlaying.parse(state: "PLAYING", mediaURI: "x-rincon:\(BAR)", mediaMeta: "", trackURI: "", trackMeta: nil)
    #expect(g.source == .grouped(coordinator: BAR))
    #expect(NowPlaying.parse(state: "STOPPED", mediaURI: "", mediaMeta: "", trackURI: "", trackMeta: "").source == .none)
}

@Test func parsesRadioStream() {
    let track = """
    <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" \
    xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="-1" parentID="-1">\
    <r:streamContent>Daft Punk - One More Time</r:streamContent><dc:title>x-sonosapi-stream:s1</dc:title></item></DIDL-Lite>
    """
    let media = """
    <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
    <item id="R:0" parentID="R:0"><dc:title>Radio Eins</dc:title></item></DIDL-Lite>
    """
    let np = NowPlaying.parse(state: "PLAYING", mediaURI: "x-sonosapi-stream:s1?sid=254", mediaMeta: media,
                              trackURI: "", trackMeta: track)
    #expect(np.source == .radio && np.artist == "Daft Punk" && np.title == "One More Time" && np.album == "Radio Eins")
}

@Test func groupHelpers() throws {
    let h = try baseline()
    let room = try #require(h.rooms[BAR])
    #expect(h.group(of: room) != nil)
    #expect(h.coordinator(of: room)?.uuid == h.group(of: room)?.coordinator)
}

@Test func driftAgainstOwnSnapshotIsEmpty() throws {
    let h = try baseline()
    #expect(Planner.restore(h, to: h).isEmpty)
}
