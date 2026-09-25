# Instagram reels in the chat

A reel link (`instagram.com/reel/<code>`, `/reels/<code>`, `/<user>/reel/<code>`, `/p/<code>`, or the ddinstagram, kkinstagram and instagramez mirrors) previews as a video card. The card plays in the video dialog. `InstagramProvider` (`commet/lib/client/components/video_embed/providers/instagram_provider.dart`) resolves it.

## Native: play the MP4 ourselves

Instagram's embed page, `https://www.instagram.com/reel/<code>/embed/captioned/`, carries the post as JSON. A JSON string sits under `contextJSON` inside the page's `PolarisEmbedSimple` init arguments, so it is decoded twice. It holds `gql_data.shortcode_media`, which includes:

- `video_url`, a progressive H.264/AAC MP4 on the Instagram CDN
- `display_url` (the thumbnail)
- `dimensions`
- `video_duration`
- the caption
- `owner.username`

Instagram only renders that page for a navigation. The request must carry `Sec-Fetch-Mode: navigate`, as an iframe load would. Without it, the reply is the app shell (`"pageID":"httpErrorPage"`) with no post in it. No cookies, login or particular User-Agent are needed; Dart's default UA works.

The MP4 plays without cookies or a Referer. It answers range requests and sends `access-control-allow-origin: *`. Its URL is signed (`oe=` is the expiry, about two days out). For that reason the preview keeps only metadata, and opening the dialog fetches a fresh URL.

Outcomes:

- **Video post:** a `NativeVideoSource`, played by media_kit with seeking, volume and fullscreen.
- **Photo or carousel post** (`is_video: false`): no video. The link previews as a page from the homeserver's og: tags.
- **No post data** (private, removed, rate-limited, offline, or Instagram changed the page): the official embed below.

## Web and fallback: Instagram's own embed

A browser cannot read the embed page. instagram.com sends no CORS headers, and `Sec-Fetch-Mode` is set by the browser anyway. The web build therefore skips the fetch. It plays `https://www.instagram.com/reel/<code>/embed/` in an iframe instead (`OfficialEmbedFrame`, `commet/lib/ui/molecules/video_player/official_embed_frame_web.dart`).

The page sends no `X-Frame-Options` and no `frame-ancestors`, and the reel plays inside the iframe after a click. YouTube embeds use the same iframe on web.

On native builds, the official embed is only the fallback. It plays wherever `VideoPlaybackDialog.supportsOfficialEmbeds` allows: CEF, or the web view on macOS, Android and iOS. Everywhere else it opens in the browser.

On web the card's thumbnail and title come from the homeserver's URL preview, which reads the reel's og: tags. Without that preview, the card is a plain "Instagram Reel".

## When it breaks

The embed page's JSON is not an API, and Instagram can change it. When it does, reels fall back to the official embed rather than failing. The fixture in `commet/unit_test/fixtures/instagram_reel_embed.html` is trimmed from a real page, so compare it against a fresh one:

```sh
curl -s -H 'Sec-Fetch-Mode: navigate' \
  https://www.instagram.com/reel/C2X_BmsPg5d/embed/captioned/ | grep -c contextJSON
```

yt-dlp's Instagram extractor reads the same page as its fallback, so its changelog is a good early warning.
