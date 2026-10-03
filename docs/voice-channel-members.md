# Who is in a voice channel

Report (2026-09-30): a voice channel sometimes shows nobody, or only the
people who came in recently, while others are in it and talking. It is the
people who have been in it for a while that go missing, in the sidebar list
under the channel and on the channel's own page ("It's quiet in here").

## Where the list comes from

- **Outside the call**, from the call memberships in the room state
  (`org.matrix.msc3401.call.member`, one per device). A membership with
  `application` counts until its `expires` window closes. The window is
  MatrixRTC's: `expires` milliseconds from its join time, which is
  `created_ts` once the membership has been rewritten and its
  `origin_server_ts` before that (`MatrixCallMembership.expiresAt`). Nothing
  arrives when a window closes, so a timer looks at the list again then
  (`MembershipLapseTimer`). Read by `MatrixActivitiesComponent.getSessions`
  (the sidebar), `MatrixVoipRoomComponent.getCurrentParticipants` (the
  channel's page), `MatrixUserPresenceComponent.callPresence` (the online
  dot) and the encryption key provider (who gets our keys).
- **In our own call**, also from LiveKit: everyone in the LiveKit room
  (`CallRoster.connectedUserIds`), with or without a stream, and whatever
  their membership says.

A membership stays open because its owner keeps writing it: each write
moves the window's end to four hours past then. The delayed leave (MSC4140,
30 s, restarted every 10 s) is what takes it down when a client dies; the
window only covers homeservers without delayed events.

Besides who is there, a membership carries what the list shows next to
them, in keys other clients ignore: `chat.commet.streams` (LIVE),
`chat.commet.voice_state` (muted, deafened), `chat.commet.away`, and
`chat.commet.dj` (`{"playing": bool}` while they are the DJ in the call's
booth, null otherwise), which shows a record next to them for people outside
the call, spinning while their music plays. Streams, voice state and the DJ
are written with or without a delayed leave. Without one (a homeserver
without delayed events) nothing takes them down if the client dies, so that
write also says `chat.commet.unguarded: true`, and readers stop believing the
three of them 90 minutes after it was written
(`MatrixCallMembership.unguardedStateLifetime`): its owner writes it again
every hour while it is alive. The member stays listed until the membership
itself lapses.

The sidebar shows up to eight rows of members under a channel
(`RoomTextButton.maxVisibleMembers`). A fuller channel shows seven, ourselves
and whoever is live first, and "and N more" on the eighth row opens the rest
in a list of their own. The channel's page shows everyone, with the same
badges on their tiles, before joining too.

**One person, one device in the call.** Joining a call you are already in
from another device takes the older device out of it: when its membership
sync or heartbeat finds a live membership of ours from another device that
joined later, it hangs up, which frees the DJ booth if it had it and stops
its screen share (`MatrixCallMembership.supersededBy`,
`MatrixLivekitVoipSession.leaveIfSuperseded`). The new device joins fresh,
unmuted. A device that is offline stays listed until its delayed leave or
window ends; the list shows a person once either way.

## What went wrong

| # | What happened | Fix |
|---|---------------|-----|
| 1 | Memberships were read against this machine's clock, while their windows run on the homeserver's. A clock three hours ahead (Windows reading a dual boot's UTC hardware clock as local time, in Brazil) closed every window three hours early: whoever had joined more than an hour before, or last written their membership more than an hour before, vanished. | `HomeserverClock` (`client/matrix/homeserver_clock.dart`) reads the homeserver's time off every sync: an event it serves carries its `unsigned.age`, and one sent from it has its clock in `origin_server_ts`. It keeps that time on a steady clock, so setting this machine's clock does not move it, and a reading that says it is earlier than the one kept (a late sync, a bridge's back-dated message) is ignored for five minutes. Every reader above, and the lapse timer, go by it. It logs `This machine's clock is … ahead of <server>'s` when that changes by more than a minute. |
| 2 | Our membership was only pushed out from the delayed-leave heartbeat. On a homeserver without delayed events (Synapse ships without them), or when arming the delayed leave failed once, nothing pushed it out, and four hours into a call everyone stopped listing us. | The heartbeat runs for the whole call whether or not there is a delayed leave (`MatrixLivekitVoipSession.startHeartbeat`), and pushes the membership out itself. |
| 3 | It was pushed out only in its last hour, by our clock. A writer's clock an hour behind, or a reader's an hour ahead, closed the window before the write. | Written again once three hours are left (`MatrixCallMembership.refreshWhenLeft`), so an hour after each write, as MatrixRTC's own clients do; by the later of the homeserver's time and ours (`_membershipTime`): a window cut short hides us from everyone, one a little long only keeps a client that died listed a little longer, where there are no delayed leaves. |
| 4 | Arming the delayed leave was tried once. One that failed (offline for a moment, rate limited) left the call without a delayed leave for good: no LIVE or muted badges, and no restoring the membership if it was cleared. | Tried again 30 s later, then a minute, two, and so on up to ten, asking whether the homeserver has delayed events too (`_armDelayedLeaveWhenDue`). |
| 5 | Pushing it out wrote our membership outside the publisher and without `away`, so someone away showed as back after each push. | It goes through `CallMembershipPublisher.rewrite`, one write at a time, saying what we advertise now. |
| 6 | In our call, the sidebar only added people from their streams. Someone connected without a stream (a microphone that would not open) and without a live membership was missing. | Everyone in the LiveKit room is listed, and someone connecting or leaving updates the list. |
| 7 | Its rate limits compared times on this machine's clock: a clock set back (someone fixing it) held the next push back by as much. | A clock that went back counts as the wait being over (`_waited`). |
| 8 | A list is only worked out again when a membership changes. Worked out right after the app starts, before any sync has said what time it is, it stayed as the wrong clock had it for up to an hour. | `HomeserverClock.onCorrected` fires when a reading moves its time by more than 30 s; the sidebar, the channel's page and the key provider work their lists out again, and the lapse timer is set again. |
| 9 | The sidebar asked for the member (name, avatar) of the people listed when the row was built only. Anyone who turned up later showed as their user id. | Everyone listed is asked for once, whenever they turn up (`RoomTextButton.fetchNewMembers`). |
| 10 | A heartbeat waited for its restart of the delayed leave for as long as the HTTP client did, 35 s, and the heartbeats after it waited for that one. A restart lost to a dropped connection (a network blip, a Wi-Fi roam) therefore outlived the delayed leave's 30 s: it fired, and the member dropped out of the list of everyone outside the call while still talking, until a later heartbeat put the membership back, a minute or more on. | A restart is given up on after 8 s (`MatrixLivekitVoipSession.restartTimeout`), before the next heartbeat is due, and that one restarts it in time. |
| 11 | Streams, voice state and the DJ were only written with the delayed leave armed. On a homeserver without delayed events nobody outside the call saw who was live, on camera, muted or deafened in it: the badges only showed once inside, from LiveKit. | Written either way, marked `chat.commet.unguarded` without a delayed leave, and dropped by readers 90 minutes after the last write (`_publishMembershipState`, `MatrixCallMembership.publishedStateIsStale`). |
| 12 | A denied or unavailable microphone produces no publication or mute event. Without delayed events, nothing published its initial muted state, so people outside the call saw it as unmuted. | Publish the session's initial state after registering its listeners and DJ booth, even if no track event follows. |
| 13 | A full reconnect clears LiveKit's publication map while screen capture continues. Stopping then emits no unpublish event, leaving LIVE advertised after the capture stops. | Publish the state after `stopScreenshare` verifies that the capture and its publications have stopped. |

## What the tests guard

| Invariant | Guarded by |
|-----------|------------|
| The homeserver's time comes from its own events' age, not another homeserver's or a local echo's; setting this machine's clock does not move it; a late or back-dated reading does not set it back, unless the one kept is five minutes old; the first reading after a sleep puts it right | `unit_test/homeserver_clock_test.dart` |
| Someone in for hours, with a clock three hours ahead, is listed in the sidebar and on the channel's page; a window closed by the homeserver's clock is not; the list is looked at again when one closes, not before, and as soon as a sync puts the time right; in our call, someone connected with no stream and no membership is listed, and connecting updates the list | `unit_test/voice_channel_member_list_test.dart` ("Members in the call for hours", "Voice channel page") |
| Written again an hour after each write, from the same join, with or without delayed events, away included; a clock three hours behind, a lagging homeserver time and a clock set back all still write a full window; a delayed leave, or the question, that failed is tried again 30 s later and not before, and less often while it keeps failing; a restart that is lost does not hold up the next heartbeat; LiveKit's participants are who is connected | `unit_test/call_membership_keepalive_test.dart` |
| When a membership is due, and the lapse timer counting by the homeserver's clock | `unit_test/matrix_call_membership_test.dart` |
| The sidebar row itself shows everyone under the channel by name, someone in for five hours included; on a clock three hours ahead, the ones in for hours turn up, by name, as soon as a sync says what time it is | `unit_test/voice_channel_sidebar_row_test.dart` |
| A rewrite waits its turn, is covered by a write going out anyway, is retried when it fails, and does nothing once stopped | `unit_test/call_membership_publisher_test.dart` |
| A mute is published without delayed events, marked unguarded, and guarded with them; unguarded badges show while they are kept written, go 90 minutes after the last write with no event, and their owner stays listed | `unit_test/call_membership_keepalive_test.dart`, `unit_test/voice_channel_member_list_test.dart` ("Badges of a member without a delayed leave"), `unit_test/matrix_call_membership_test.dart` |
| Badges show in the sidebar row and on the channel's page before joining; a full channel lists seven and opens the rest from "and N more", whoever is live among the seven | `unit_test/voice_channel_sidebar_row_test.dart`, `unit_test/voice_channel_page_badges_test.dart` |
| Joining without a microphone advertises muted even without delayed events or a track event; stopping a screen share during a full reconnect clears LIVE from the membership people outside the call read | `unit_test/call_membership_keepalive_test.dart`, `unit_test/screen_share_stop_test.dart` |

Reverting any one of these fixes turns at least one of these tests red
(checked by hand on 2026-09-30, twenty-two mutations).

## If it happens again

- `This machine's clock is … ahead of <server>'s` (or `behind`): the
  clock is off, and has been corrected for. Nothing to do.
- `Extending our call membership before it expires`, about once an hour in
  a call: the member keeps their membership up. Missing on a member's log
  while they sit in a call for hours means they run a build without this
  fix.
- `Homeserver does not support delayed events`: no delayed leave, so a
  client that dies stays listed until its window closes, up to four hours.
- `Our delayed leave is gone, arming a new one` followed by `Our call
  membership was cleared while we are in the call, restoring it`: the
  member's delayed leave fired while they were in the call, and they were
  missing from the list of everyone outside it until then.
- `Could not arm our delayed leave (attempt N, again in S s)`: tried again
  30 s later, then a minute, two, and so on up to ten.
- `Membership state is expired, skipping` (sidebar): a membership whose
  window closed. For someone still in the call, look at their log for the
  lines above.

## Known limits

- **Members on older builds.** Readers now go by the homeserver's clock,
  which covers a reader's wrong clock. A member whose own build predates
  this still pushes their membership out only in its last hour, by their
  own clock, and only with delayed events: they can still drop out of the
  list after four hours, until they update.
- **A homeserver that sends no `unsigned.age`.** Synapse sends it. Without
  it the clock stays this machine's; the hourly writes still leave three
  hours of room for a wrong clock.
- **The call's own grid** shows a tile per stream. Someone in the call with
  no stream at all is in the sidebar list but has no tile.
