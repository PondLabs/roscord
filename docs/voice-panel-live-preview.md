# Voice panel LIVE preview: how the local video track can be rendered twice

Research note for GitHub issue #8 (sidebar voice panel shows a LIVE badge plus
a small preview of the user's own screen share / camera, with stop buttons).
Written 2026-09-16 against the code in this checkout. `docs/` already uses flat
topic notes (`docs/voice-audio-processing.md`), so this note follows that
convention instead of a `docs/research/` subfolder.

Sources are the vendored packages under `third_party/`, the app code under
`commet/lib/client/matrix/components/voip_room/` and `.../voip/`, and two
pub-cache packages that are **not** vendored:

- `matrix-dart-sdk` is a git dependency (`commet/pubspec.yaml:68-71`, ref
  `upstream-v6.1.1`), resolved in
  `~/.pub-cache/git/matrix-dart-sdk-58e0bd24c6a2d74d727dc92a24dc076144fae43b/`
  (commit 58e0bd24, "Merge pull request #11 from commetchat/upstream-6.1.1").
  Paths below written as `<msdk>/...` refer to that directory.
- `dart_webrtc` 1.8.1 (flutter_webrtc's web implementation of tracks and
  devices) at `~/.pub-cache/hosted/pub.dev/dart_webrtc-1.8.1/`, written as
  `<dart_webrtc>/...`.

## Summary

1. `buildVideoRenderer` returns a livekit `VideoTrackRenderer` (LiveKit path)
   or a flutter_webrtc `RTCVideoView` (legacy path). The LiveKit widget owns a
   private `RTCVideoRenderer` per widget instance; the legacy stream owns one
   `RTCVideoRenderer` per stream and every `RTCVideoView` built from it shares
   that renderer. Both can be built twice and mounted at once.
2. Native (Linux/Windows): each `RTCVideoRenderer` is one Flutter texture and
   one extra frame sink on the video track. The extra sink costs one YUV to
   ARGB conversion of the full capture frame per frame on the raster thread. It
   does not touch capture or encoding.
3. Web: `RTCVideoView` does not use `HtmlElementView` by default. Each renderer
   creates a hidden `<video>` element, and each mounted `RTCVideoView` runs its
   own `requestVideoFrameCallback` loop that copies every frame into a
   `ui.Image`. A second view therefore doubles that per-frame copy. Attaching
   the same `MediaStreamTrack` to two `<video>` elements is standard DOM use
   and nothing in the vendored code guards against it.
4. `onStateChanged` fires on the LiveKit session after every local publish,
   unpublish, mute and unmute (both from app calls and from room events). On
   the legacy session it fires on call state changes and stream add/remove, but
   **not** when the camera is toggled on an existing stream.
5. Browser "Stop sharing" reaches the LiveKit session only on web:
   `MediaStreamTrack.ended` -> livekit `TrackEndedEvent` -> `removePublishedTrack`
   -> `LocalTrackUnpublishedEvent` -> `onLocalTrackUnpublished` ->
   `onStateChanged`. On native desktop, flutter_webrtc never calls
   `MediaStreamTrack.onEnded`, so nothing fires. The legacy session installs no
   `onEnded` handler on screen-share tracks at all.
6. `isSharingScreen` / `isCameraEnabled`: LiveKit reads the local publication's
   `muted` flag by source; legacy reads `localScreenSharingStream != null` and
   `localUserMediaStream.isVideoMuted() == false`.
7. `aspectRatio`: LiveKit returns the server-reported publication dimensions
   (the requested 1280x720 on desktop, `getSettings()` on web/mobile) or `null`;
   legacy returns the renderer's decoded frame size or `1` until the first size
   event.
8. Tests: `commet/unit_test/` (run by CI as `flutter test unit_test`) already
   fakes `VoipSession` / `VoipStream` with `implements` + `noSuchMethod` and
   constructs a real `CallManager(ClientManager())`. Nothing mocks the global
   `clientManager` in `commet/lib/main.dart`; widget tests avoid it by taking a
   `VoipSession` directly.

## 1. `VoipStream.buildVideoRenderer(BoxFit fit, Key key)`

Interface: `commet/lib/client/components/voip/voip_stream.dart:12`.

### LiveKit path: `MatrixLivekitVoipStream`

`commet/lib/client/matrix/components/voip_room/matrix_livekit_voip_stream.dart:108-115`
returns `VideoTrackRenderer(publication.track as VideoTrack)` when the
publication's track is a `VideoTrack`, otherwise `null`. Both `fit` and `key`
are ignored (the widget gets no key and the default `VideoViewFit.contain`).

`VideoTrackRenderer` (`third_party/livekit-client-sdk-flutter/lib/src/widgets/video_track_renderer.dart`):

- It is a `StatefulWidget` whose state owns a private `rtc.VideoRenderer?
  _renderer` (`:88`). `_initializeRenderer` creates a new `rtc.RTCVideoRenderer()`
  and awaits `initialize()` the first time it runs (`:96-106`). So **each mounted
  `VideoTrackRenderer` owns its own `RTCVideoRenderer`** unless the caller
  passes `cachedRenderer` (`:66`, used in `initState` at `:142-144`).
- `dispose` calls `disposeRenderer()` (`:128-137`) when `autoDisposeRenderer`
  is true, which is the default (`:77`, `:159-161`). With `cachedRenderer` plus
  `autoDisposeRenderer: false` a caller can share one renderer between widgets.
- `_attach` (`:165-185`) sets `_renderer.srcObject = track.mediaStream`,
  listens for `TrackStreamUpdatedEvent` to re-point `srcObject`, and hooks
  `onResize` to update `_aspectRatio`.
- On native it wraps the view in a `FutureBuilder(_initializeRenderer())`
  (`:241-275`) and renders `rtc.RTCVideoView(_renderer, mirror: ...,
  filterQuality: FilterQuality.medium, objectFit: ...)` (`:233-238`). On web it
  initialises in `initState` and shows `Container()` until
  `_rendererReadyForWeb` (`:146-152`, `:203-219`).
- Each instance registers a `GlobalKey` on the track via
  `track.addViewKey()` (`:145`) and removes it on dispose (`:157`). For a
  `LocalVideoTrack` those keys are only stored (`.../track/local/local.dart:42-60`);
  nothing in the vendored SDK consumes them for local tracks, so a second view
  has no publish-side effect. (`onVideoViewBuild` at `:210` and `:251` is a
  nullable callback that is only set for remote adaptive-stream tracks;
  UNVERIFIED beyond grep that no local code path sets it.)
- With `fit == contain` (the value the app gets) the widget wraps the view in a
  `LayoutBuilder` that sizes to `_aspectRatio` and, by default, a `Center`
  (`:283-323`). `_aspectRatio` stays `null` until the renderer's first
  `onResize`, in which case the child fills the parent (`:292-294`).

Calling `buildVideoRenderer` twice returns two independent widgets with two
independent renderers. The full-size call view already builds one per stream
through `VoipStreamView` (`commet/lib/ui/organisms/call_view/voip_stream_view.dart:243-247`,
mounted from `call_view.dart:306-326` with key `callView__<streamId>`). A
second one in the sidebar is the same operation again.

### Legacy path: `MatrixVoipStream`

`commet/lib/client/matrix/components/voip/matrix_voip_stream.dart`:

- The stream owns a single `RTCVideoRenderer? renderer` (`:15`). The
  constructor calls `initRenderer()` (`:24`), which creates and initialises a
  renderer and sets `srcObject` only if the wrapped `MediaStream` has a video
  track (`:38-46`). `initRenderer` is `async` and unawaited; it does **not**
  emit `onStreamChanged` when it completes, so a widget that saw `renderer ==
  null` is not told when the renderer becomes ready.
- `buildVideoRenderer` (`:125-145`): if `renderer == null` returns a
  `CircularProgressIndicator`; if `fit == BoxFit.contain` returns
  `AspectRatio(aspectRatio: aspectRatio ?? 1, child: RTCVideoView(renderer!))`
  (the `key` argument is ignored on this branch); otherwise returns
  `RTCVideoView(key: key, renderer!, objectFit: cover)` when `textureId !=
  null`, else `null`.
- Every `RTCVideoView` produced this way shares the one renderer (and on
  native the one texture). Building it twice adds a second `Texture` widget for
  the same texture id, not a second sink.

`RTCVideoView` on native
(`third_party/flutter-webrtc/lib/src/native/rtc_video_view_impl.dart`) is a
`StatelessWidget` (`:9`) that renders `Texture(textureId:
videoRenderer.textureId!)` inside a `FittedBox` driven by a
`ValueListenableBuilder` on the renderer (`:34-70`). It holds no per-widget
native state. Flutter's `Texture` widget docs describe the id as a reference
to a registry-managed backend texture (`/home/gabriel/flutter/packages/flutter/lib/src/widgets/texture.dart:16-24`);
they do not say two widgets may not reference the same id. UNVERIFIED: I did
not find an explicit statement either way in the framework source, but the
plugin side (below) keeps no per-widget state, so nothing on that side prevents
it.

### What a renderer costs on native (Linux/Windows)

`third_party/flutter-webrtc/lib/src/native/rtc_video_renderer_impl.dart`:

- `initialize()` invokes `createVideoRenderer` and subscribes to the
  `FlutterWebRTC/Texture<id>` event channel (`:21-34`). `srcObject=` invokes
  `videoRendererSetSrcObject` with the stream id (`:54-72`). `dispose()`
  invokes `videoRendererDispose` (`:96-114`).

`third_party/flutter-webrtc/common/cpp/src/flutter_video_renderer.cc`:

- `CreateVideoRendererTexture` allocates a `FlutterVideoRenderer`, wraps it in
  a `flutter::PixelBufferTexture` whose callback is `CopyPixelBuffer`, and
  registers it with the texture registrar; **one texture per renderer**
  (`:114-131`).
- `VideoRendererSetSrcObject` looks up the stream and calls
  `renderer->SetVideoTrack(video_tracks[0])` (`:133-163`). `SetVideoTrack`
  removes the renderer from the previous track and calls
  `track_->AddRenderer(this)` (`:84-94`). So **each renderer is one extra
  sink on the same track**; the track fans frames out to all sinks.
- `OnFrame` stores the frame reference under a mutex and calls
  `MarkTextureFrameAvailable` (`:47-82`). No pixel work happens here.
- `CopyPixelBuffer` runs when Flutter's raster thread pulls the texture and
  does `frame_->ConvertToARGB(kABGR, ...)` at the **frame's own width and
  height** (`:21-45`); the `width`/`height` arguments from Flutter are ignored.
  A 1280x720 screen share is therefore converted to a 3.7 MB ARGB buffer per
  frame per renderer, regardless of how small the widget is drawn.

Consequences for the issue's stutter concern: the second renderer never enters
the capture or encode pipeline (libwebrtc's track sinks are consumers; the
`RTCRtpSender` is another sink on the same track and is unaffected by how many
renderers exist). The added cost is one extra full-resolution colour conversion
per frame on the raster thread plus one extra texture upload. Rendering the
widget smaller does not reduce that conversion, because `CopyPixelBuffer`
ignores the requested size. Reusing the existing renderer (legacy path already
does; LiveKit path via `cachedRenderer` + `autoDisposeRenderer: false`) is the
only way to avoid the second conversion on native.

Android (not a Linux/Windows build, noted for completeness):
`third_party/flutter-webrtc/android/src/main/java/com/cloudwebrtc/webrtc/FlutterRTCVideoRenderer.java:265`
also does `videoTrack.addSink(surfaceTextureRenderer)` per renderer, i.e. the
same one-sink-per-renderer model.

## 2. Web rendering

`third_party/flutter-webrtc/lib/src/web/rtc_video_renderer_impl.dart`:

- `useHtmlElementView` defaults to `false` and is only switched on by the
  dart-define `WEBRTC_USE_HTML_ELEMENT_VIEW` (`:14-15`). No file in this repo
  sets that define (grep over `*.yaml`, `*.yml`, `*.sh`, `*.dart`, `*.nix`,
  `*.md` outside the vendored package), so the app runs the non-HtmlElementView
  path.
- Each `RTCVideoRenderer` gets a unique `_textureId` from a static counter
  (`:42-44`, `:50`) and therefore a unique element id `video_RTCVideoRenderer-<n>`
  (`:96-98`).
- `initialize()` in the default mode calls `createElement()` and appends the
  `<video>` to `document.body` (`:321-332`). `_applyDefaultVideoStyles` makes it
  `opacity: 0; position: absolute; pointer-events: none` (`:346-352`). So the
  element is a hidden decode surface, not the thing the user sees.
- `srcObject=` builds a **new** `web.MediaStream()` containing the source's
  video tracks (`:125-129`) and, if there are audio tracks, another one for
  audio that is attached to an `<audio>` element created per renderer under a
  hidden `html_webrtc_audio_manager_list` div, `muted` when
  `stream.ownerTag == 'local'` (`:131-151`, `:212-221`). `getDisplayMedia` and
  `getUserMedia` streams on web get `ownerTag 'local'`
  (`<dart_webrtc>/lib/src/mediadevices_impl.dart:88`, `:95`), so a local screen
  share with system audio (the LiveKit video track's `mediaStream` still holds
  the audio track, see
  `third_party/livekit-client-sdk-flutter/lib/src/track/local/video.dart:250-269`)
  creates a muted `<audio>` element per renderer and does not echo.

`third_party/flutter-webrtc/lib/src/web/rtc_video_view_impl.dart`:

- `RTCVideoView` is a `StatefulWidget` (`:15`). In `initState` it looks up the
  renderer's `<video>` element and starts `frameCallback` (`:40-54`).
- `frameCallback` uses `requestVideoFrameCallback` (falls back to
  `requestAnimationFrame`, `:210-232`) and, when `readyState > 2`, calls
  `capture()` (`:73-91`).
- `capture()` calls `ui_web.createImageFromTextureSource(element, width:
  element.videoWidth, height: element.videoHeight, transferOwnership: true)`
  and `setState`s the new `ui.Image` when `currentTime` advanced (`:95-120`).
  The image is at the video's native size; the widget then draws it through a
  `FittedBox` + `CustomPaint` (`:159-187`).
- In `HtmlElementView` mode it would instead return
  `HtmlElementView(viewType: videoRenderer.viewType)` (`:156-158`).

So on web the visible pixels come from a per-widget frame copy, not from the
`<video>` element itself. Two mounted `RTCVideoView`s mean two
`requestVideoFrameCallback` loops and two `createImageFromTextureSource` calls
per decoded frame, each at full video resolution, plus two `setState`s. This is
compositing/copy cost in the page; it does not feed back into `getDisplayMedia`
capture or the `RTCRtpSender`. If both views share one renderer (legacy path)
there is still one hidden `<video>` but the per-view copy loop is duplicated,
because the loop lives in `RTCVideoViewState`, not in the renderer.

Attaching the same `MediaStreamTrack` to two `<video>` elements (LiveKit path:
two renderers, each wrapping the track in its own `new MediaStream`) is plain
DOM usage; the vendored code contains no comment, guard or workaround about it.
I found no issue in the vendored sources that describes a problem with it.
UNVERIFIED: I did not check browser bug trackers.

One web caveat in the vendored code: `RTCVideoView.initState` writes
`videoRenderer.mirror` and `videoRenderer.objectFit` onto the shared renderer
(`:44-48`, again in `didUpdateWidget` `:143-151`). Two views on one renderer
with different `objectFit` would overwrite each other's element style, but in
the default non-HtmlElementView mode the element is invisible and the fit is
applied by each widget's own `FittedBox` (`:168-175`), so this is harmless.

## 3. When `onStateChanged` fires

### `MatrixLivekitVoipSession`

`commet/lib/client/matrix/components/voip_room/matrix_livekit_voip_session.dart`.
The session subscribes to the LiveKit room's event bus in its constructor
(`:39-49`) and `_stateChanged.add(())` is called from:

| Trigger | Where |
|---|---|
| `LocalTrackPublishedEvent` (adds a `MatrixLivekitVoipStream`) | `:268-276` |
| `LocalTrackUnpublishedEvent` (removes by publication sid) | `:278-284` |
| `TrackMutedEvent` (removes the stream if it is video, then fires) | `:151-169` |
| `TrackUnmutedEvent` (re-adds the stream if missing, then fires) | `:171-190` |
| `TrackPublishedEvent` / `TrackUnpublishedEvent` (remote) | `:192-201`, `:286-292` |
| after `setScreenShare` completes publishing | `:416`, `:472` |
| after `setCamera` / `stopCamera` / `stopScreenshare` | `:483`, `:490`, `:510` |
| after `setMicrophoneMute` / `setDeafened` / data-channel deafen updates | `:382`, `:408`, `:253` |
| `hangUpCall` (state = ended) | `:319-320` |

Order relative to publish: `LocalParticipant._publishVideoTrack` emits
`LocalTrackPublishedEvent` on `[events, room.events]` before `track.start()`
and before returning (`third_party/livekit-client-sdk-flutter/lib/src/participant/local.dart:250-258`),
so `onStateChanged` fires once from the event handler while `setScreenShare`
is still awaiting `publishVideoTrack`, and once more from `setScreenShare`
itself (`:472`). The stream appears in `streams` at the first of those.

Order relative to unpublish: `removePublishedTrack` removes the publication
from `trackPublications` first (`local.dart:544`), then removes the sender and
renegotiates, then emits `LocalTrackUnpublishedEvent` (`local.dart:588-592`).
So when the app's handler runs, `isSharingScreen` is already `false` and the
stream is removed from `streams` in the same handler (`:279-283`).

Camera off goes through `setCameraEnabled(false)` ->
`setSourceEnabled(camera, false)` -> `publication.mute(...)`
(`local.dart:756-758`, `:796-806`). `LocalTrack.mute` calls `updateMuted(true,
shouldSendSignal: true)` (`.../track/local/local.dart:186-195`), which emits
`InternalTrackMuteUpdatedEvent` (`.../track/track.dart:198-212`); the
publication converts that into `TrackMutedEvent` on `[participant.events,
participant.room.events]` (`.../publication/track_publication.dart:132-144`).
The app's `onTrackMutedEvent` removes the video stream from `streams` and fires
`onStateChanged` (`:151-169`); `stopCamera` fires it again (`:490`). Camera on
is the mirror image via `TrackUnmutedEvent` (`:171-190`). Note
`addInitialStreams` also skips muted video publications (`:111-113`), so a
muted camera never appears in `streams`.

### Browser "Stop sharing" (track ended) on the LiveKit path

- **Web**: `MediaStreamTrackWeb` registers a DOM `'ended'` listener that calls
  `onEnded` (`<dart_webrtc>/lib/src/media_stream_track_impl.dart:12-17`).
  `LocalTrack`'s constructor sets `mediaStreamTrack.onEnded` to emit
  `TrackEndedEvent` (`.../track/local/local.dart:177-181`, event defined at
  `.../internal/events.dart:779-787`). After publishing, `LocalParticipant`
  listens for `TrackEndedEvent` on the track and calls
  `removePublishedTrack(pub.sid)` (`local.dart:245-248` for audio, `:529-532`
  for video), which emits `LocalTrackUnpublishedEvent` (`:588-592`) ->
  `onLocalTrackUnpublished` -> `onStateChanged`. The screen-share **audio**
  publication is not removed by that path unless its own track also ends
  (browsers do end it together with the video track; UNVERIFIED against a
  spec, observed behaviour only).
- **Native desktop (Linux/Windows)**: `MediaStreamTrackNative` never invokes
  `onEnded`; the only callbacks it drives are `onMute`/`onUnMute` from
  `enabled=` (`third_party/flutter-webrtc/lib/src/native/media_stream_track_impl.dart:33-45`).
  No event channel in `third_party/flutter-webrtc/lib/src/native/` or
  `common/cpp/` delivers an "ended" event (grep for `onEnded`, `trackEnded`
  finds none; the only `"ended"` string is `trackStateToString` in
  `common/cpp/src/flutter_peerconnection.cc:305-315`, used for describing
  sender state, not as an event). The LiveKit engine itself comments that
  `track.onEnded` "doesn't get called reliably"
  (`.../core/engine.dart:714-717`). So on desktop the OS ending a capture
  (window closed, etc.) produces **no** `TrackEndedEvent`, no unpublish, and no
  `onStateChanged`; the publication stays and `isSharingScreen` stays `true`
  until the user presses stop.

### Legacy `MatrixVoipSession`

`commet/lib/client/matrix/components/voip/matrix_voip_session.dart`.
`_onStateChanged.add(null)` is called from:

| Trigger | Where |
|---|---|
| `session.onCallStateChanged` (matrix-dart-sdk `CallState`) | `:42-45` |
| `session.onStreamAdd` (only if `shouldAddStream`) | `:53`, `:322-336` |
| `session.onStreamRemoved` | `:54`, `:338-341` |
| `setDeafened` | `:204` |

In matrix-dart-sdk, `onCallStateChanged` is emitted by `setCallState`
(`<msdk>/lib/src/voip/call_session.dart:763-767`), `onStreamAdd` by
`addLocalStream` (`:621-644`, emit at `:644`) and `_addRemoteStream`
(`:710`), `onStreamRemoved` by `removeLocalStream` (`:744-761`, emit at
`:759`) and `deleteFeedByStream` (`:726-736`).

Screen share on this path: `setScreenShare` calls `getDisplayMedia` itself and
then `session.addLocalStream(stream, Screenshare)` (`:227-258`) — it does
**not** use the SDK's `setScreensharingEnabled`, which is the only place the
SDK installs a `track.onEnded` handler for screen share (`call_session.dart:591-593`).
`commet/lib` sets no `onEnded` anywhere (grep). So on the legacy path the
browser's "Stop sharing" is not observed on web either; the stream stays in
`streams` until `stopScreenshare` (`:260-266` ->
`session.removeLocalStream` -> `onStreamRemoved`).

Camera on this path: `setCamera` / `stopCamera` (`:268-283`) call
`session.setLocalVideoMuted`, which calls
`localUserMediaStream.setVideoMuted(muted)` and `updateMuteStatus()`
(`call_session.dart:769-780`). `setVideoMuted` emits only the wrapped stream's
`onMuteStateChanged` (`<msdk>/lib/src/voip/utils/wrapped_media_stream.dart:96-99`);
`updateMuteStatus` toggles track `enabled` and sends SDP metadata (`:1254-1276`)
without `setCallState`. `MatrixVoipStream` listens only to
`stream.onStreamChanged` (`matrix_voip_stream.dart:25`), and the session listens
to none of the wrapped-stream events. Result: **toggling the camera on the
legacy session fires neither `onStateChanged` nor `onStreamChanged`.** The
call view only notices because something else rebuilds it. A LIVE panel driven
by `onStateChanged` will not update for legacy camera toggles unless the
session is changed to emit after `setCamera` / `stopCamera` (the LiveKit
session already does that at `:483` and `:490`).

The exception: `setCamera` on an audio-only stream first calls
`insertVideoTrackToAudioOnlyStream` (`:270-275`), which replaces the tracks in
the existing `MediaStream` in place (`call_session.dart:782-800`); I found no
`setNewStream` / `onStreamAdd` emission on that path either.

### `isSharingScreen` / `isCameraEnabled`

- LiveKit: `livekitRoom.localParticipant?.isScreenShareEnabled() ?? false`
  (`matrix_livekit_voip_session.dart:348-350`) and
  `isCameraEnabled()` (`:341-343`). Those read
  `!(getTrackPublicationBySource(source)?.muted ?? true)`
  (`third_party/livekit-client-sdk-flutter/lib/src/participant/participant.dart:302-304`,
  `:312-314`); `muted` is the publication's `_metadataMuted`
  (`.../publication/track_publication.dart:44`), updated by the mute event
  path above (`:138`). A screen share is unpublished rather than muted
  (`local.dart:798-804`), so `isSharingScreen` goes false because the
  publication disappears.
- Legacy: `session.localScreenSharingStream != null`
  (`matrix_voip_session.dart:89-90`; SDK getter at
  `call_session.dart:158-166`, "first local stream with purpose Screenshare")
  and `session.localUserMediaStream?.isVideoMuted() == false` (`:92-94`;
  `isVideoMuted` is "no video tracks or videoMuted flag",
  `wrapped_media_stream.dart:82-84`).

## 4. Outgoing screenshare / video streams in `streams`

### LiveKit

- `streams` is a plain growable list on the session
  (`matrix_livekit_voip_session.dart:513-514`), populated by
  `addInitialStreams` (`:107-134`) and the handlers in section 3. Local
  publications are added on `LocalTrackPublishedEvent` (`:268-276`).
- `direction`: `publication is LocalTrackPublication ? outgoing : incoming`
  (`matrix_livekit_voip_stream.dart:117-120`).
- `type`: `audio` if the track is an `AudioTrack`; else `screenshare` if
  `publication.isScreenShare`; else `video` (`:131-142`). `isScreenShare` is
  `kind == VIDEO && source == screenShareVideo`
  (`.../publication/track_publication.dart:87`). Screen-share **audio** is
  therefore a separate `audio`-typed outgoing stream.
- `aspectRatio`: `publication.dimensions.width / height`, or `null` when
  `dimensions` is null (`:99-106`). `dimensions` is set from the server's
  `TrackInfo` in `updateFromInfo` (`.../publication/track_publication.dart:90-100`,
  line 97), which for a local publication is the `AddTrackResponse` for the
  request built in `_publishVideoTrack`: width/height from
  `track.currentOptions.params.dimensions`, overridden by
  `mediaStreamTrack.getSettings()` only on web and mobile
  (`.../participant/local.dart:321-334`, request fields `:426-428`,
  publication constructed with that info `:516-520`). The app requests
  `VideoDimensionsPresets.h720_169` for screen share
  (`matrix_livekit_voip_session.dart:445`), so on desktop `aspectRatio` is
  `1280/720 = 1.777...` regardless of the real capture size; on web it is the
  browser-reported capture size. UNVERIFIED: that the LiveKit server echoes
  width/height unchanged in `TrackInfo` (server code not in this repo).

### Legacy

- `streams` is built by `initStreams` from local + remote wrapped streams
  filtered by `shouldAddStream` (`matrix_voip_session.dart:285-320`) and kept
  in sync by `onStreamAdded` / `onStreamRemoved` (`:322-341`).
- `direction`: `stream.isLocal()` (`matrix_voip_stream.dart:147-150`);
  `isLocal` compares `participant == voip.localParticipant`
  (`wrapped_media_stream.dart:74-76`).
- `type`: `screenshare` when `purpose == Screenshare`; otherwise `audio` if
  `videoMuted`, else `video` (`:48-59`). Because `type` reads the mutable
  `videoMuted` flag, a camera toggle changes an existing stream's `type`
  between `audio` and `video` without any event (see section 3).
- `aspectRatio`: `renderer.videoWidth / videoHeight` when both are `> 0`,
  else `1` (`:99-111`). Those values come from the native
  `didTextureChangeVideoSize` event (`rtc_video_renderer_impl.dart:125-131`)
  or, on web, the `<video>` `resize` event (`web/rtc_video_renderer_impl.dart:289-294`).
  So it is `1` until the first frame is decoded, and it is the real capture
  size afterwards.

Also worth knowing: `remoteUserMediaStream` constructs a **new**
`MatrixVoipStream` (and therefore, if the remote stream has video, a new
`RTCVideoRenderer`) on every access (`matrix_voip_session.dart:96-99`), and
`generalAudioLevel` reads it every 200 ms (`:349`, timer `:47-50`). That is a
pre-existing renderer leak on the legacy path, unrelated to the sidebar
preview but relevant if renderer count is being budgeted.

## 5. Tests, the `clientManager` global, and docs conventions

- There is no `commet/test/`. Unit and widget tests live in
  `commet/unit_test/` and CI runs them with `flutter test unit_test`
  (`.github/workflows/ci.yml:41`, `:69`). Integration tests (`commet/integration_test/`)
  boot the real `App(clientManager: clientManager!)` against a Synapse
  (`commet/integration_test/extensions/common_flows.dart:60`) and are not
  suitable for this.
- Fake session pattern: `commet/unit_test/deafen_test.dart` defines
  `FakeVoipSession implements VoipSession` and `FakeVoipStream implements
  VoipStream` that override only what the test needs and route the rest to
  `noSuchMethod` (`:11-88`, `:90-121`). It also constructs a real
  `CallManager(ClientManager())` and pushes the fake into
  `callManager.currentSessions` (`:213-217`, `:238-241`); `currentSessions` is
  a `NotifyingList<VoipSession>` (`commet/lib/client/call_manager.dart:39-40`).
- Widget test harness: `commet/unit_test/screen_share_audio_test.dart:12-21`
  wraps the widget in `MaterialApp(theme: ThemeData.light().copyWith(extensions:
  const [ThemeSettings()]))` so `tiamat` widgets can resolve their theme
  extension.
- `clientManager` is a top-level nullable global in `commet/lib/main.dart:65`
  (`preferences` at `:62`), assigned in `main` at `:222` by
  `ClientManager.init()`. `CallSessionsPanel` reads
  `clientManager!.callManager.currentSessions` in `initState` and `build`
  (`commet/lib/ui/molecules/call_sessions_panel.dart:26`, `:41`), and the
  per-session `CallSessionPanel` calls `clientManager!.callManager.mute()` etc.
  from button handlers (`:157-160`, `:174-177`). No existing test assigns the
  global or mocks `callManager`; `deafen_test.dart` builds its own
  `CallManager` instance instead. A widget test can therefore test a panel that
  takes a `VoipSession` in its constructor (as `CallSessionPanel` does,
  `:55-58`) without touching the global, as long as the widget under test does
  not itself dereference `clientManager!` during build. Setting the global
  from a test would require constructing a `ClientManager()` (the no-argument
  constructor used in `deafen_test.dart:213` works without I/O; UNVERIFIED
  whether `CallManager` construction triggers any audio-player setup in a
  test binding, `call_manager.dart:41-44` only wires stream listeners).
- Docs convention: `docs/` contains a single flat topic note,
  `docs/voice-audio-processing.md`, referenced from `CLAUDE.md`. This note
  follows that flat layout.

## Implications for the issue (facts only, no design)

- Rendering the local track a second time is safe on both paths and does not
  reach capture or encoding. The extra cost is per-renderer on native (one
  full-size ARGB conversion per frame, `flutter_video_renderer.cc:21-45`) and
  per-mounted-view on web (one full-size `createImageFromTextureSource` per
  frame, `web/rtc_video_view_impl.dart:95-120`). Drawing the widget smaller
  does not shrink either of those; only sharing a renderer (LiveKit
  `cachedRenderer`/`autoDisposeRenderer: false`, `video_track_renderer.dart:66-67`)
  removes the native duplicate, and nothing in the vendored code lowers the
  frame rate of a single view.
- `session.onStateChanged` is a sufficient rebuild trigger on the LiveKit path
  for publish, unpublish, mute, unmute, and (web only) browser-initiated stop.
  It is not sufficient for legacy camera toggles or for OS-initiated stop on
  native desktop.
- `isSharingScreen` / `isCameraEnabled` and the presence of an
  `outgoing`+`screenshare`/`video` entry in `streams` agree on the LiveKit path
  (both derive from the same publication state) once the corresponding event
  has been processed; on the legacy path `isCameraEnabled` and the stream's
  `type` both derive from `videoMuted`, but no event announces the change.
