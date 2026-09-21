# Away

The status dot next to someone's name says one of three things: online
(green), away (amber), offline (grey). Away means nobody has touched that
person's machine for fifteen minutes — not that roscord is in the background.
Someone sitting in a voice channel with a game in front of them is online;
someone who walked off leaving roscord focused is away.

## Where idle time comes from

`commet/lib/utils/idle/` asks the platform how long since the last keyboard,
mouse or touch input anywhere on the machine:

| Platform | Source | Sees input outside the app |
| --- | --- | --- |
| Windows | `GetLastInputInfo` | yes |
| Linux, GNOME | `org.gnome.Mutter.IdleMonitor.GetIdletime` (D-Bus) | yes |
| Linux, KDE | `org.freedesktop.ScreenSaver.GetSessionIdleTime` (D-Bus) | yes |
| Linux, other X11 | `XScreenSaverQueryInfo` | yes, under X; under XWayland only what reached an X client |
| Browser | Idle Detection API, where the page has already been granted it | yes |
| Browser, otherwise | input events in the page | no |
| Android, iOS, macOS | nothing | no |

The Linux sources are tried in that order and the one that answers is kept.
Nothing asks for the browser's idle-detection permission: a prompt out of
nowhere would be worse than the fallback. Where there is no source at all,
`UserIdleWatcher` falls back to how long the app has been in the background,
which is the nearest those platforms have.

`UserIdleWatcher` (`commet/lib/client/components/user_presence/`) polls every
30 s and holds the answer in `isAway`.

## How other people find out

Two ways, because one of them is often not there:

- **Matrix presence.** `setStatus` sets `unavailable`, and also sets
  `syncPresence` — a `/sync` without `set_presence` means online per the
  spec, so without that the homeserver would undo it within seconds.
  Homeservers that share no presence at all (matrix.org among them) make this
  path invisible to everyone else.
- **The call membership.** `chat.commet.away` in our
  `org.matrix.msc3401.call.member` event, next to the stream and mute state
  already published there (see `matrix_call_membership.dart`). This works on
  any homeserver, and covers the case that matters most: someone in a voice
  channel who has walked away.

`MatrixUserPresenceComponent.callPresence` folds the second into the first. A
live membership that reports its owner away wins over whatever presence the
homeserver holds, since it is first hand and recent; a membership that
reports them present makes them online where the homeserver says offline.
Someone in a call from two devices is away only if both say so.
