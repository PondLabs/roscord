# Instagram reels and posts in the chat

A reel link (`instagram.com/reel/<code>`, `/reels/<code>`, `/<user>/reel/<code>`, `/p/<code>`, or the ddinstagram, kkinstagram and instagramez mirrors) previews as a video card. The card plays in the video dialog. A photo or carousel post previews as its photos. `InstagramProvider` (`commet/lib/client/components/video_embed/providers/instagram_provider.dart`) resolves it.

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
- **Photo or carousel post:** no video. The link previews as its photos (see below).
- **No post (private, removed, rate-limited, offline, or Instagram changed the page):** the official embed below.

## Photo posts

A single photo's embed page carries no post data. It sends `"contextJSON":null` and draws the post as plain markup instead:

- `.Embed[data-media-type="GraphImage"]`
- the photo: `img.EmbeddedMediaImage`, whose `srcset` also lists square crops after the copies that keep the photo's shape
- the frame: `.EmbedFrame`, whose `padding-bottom` is the photo's height over its width
- `.UsernameText`
- `.Caption`: the author's name, then the text, with `<br>` line breaks and hashtags as links

`InstagramMedia.fromEmbedPage` reads that markup when the JSON is missing. It takes the widest `srcset` copy up to 1080 pixels wide, because `src` is the original and can be 4000 pixels across. A carousel (`GraphSidecar`) does carry the JSON. Its photos are the `display_url` of each `edge_sidecar_to_children` node, and a video slide shows as its cover.

`InstagramProvider.resolvePost` turns either form into a `PhotoPost`, the same shape an X status with photos has. The preview shows the photo, or a grid of the first four photos with every photo in the lightbox. The title is `@username` and the text is the caption. The photo URLs are signed like the video's (`oe=`), but a preview loads them once, and they load without cookies or a Referer.

On web, where the page cannot be read, a `/p/` link stays an official embed card titled "Instagram Post", because it may hold photos or a video.

## Web and fallback: Instagram's own embed

A browser cannot read the embed page. instagram.com sends no CORS headers, and `Sec-Fetch-Mode` is set by the browser anyway. The web build therefore skips the fetch. It plays `https://www.instagram.com/reel/<code>/embed/` in an iframe instead (`OfficialEmbedFrame`, `commet/lib/ui/molecules/video_player/official_embed_frame_web.dart`).

The page sends no `X-Frame-Options` and no `frame-ancestors`, and the reel plays inside the iframe after a click. YouTube embeds use the same iframe on web.

On native builds, the official embed is only the fallback. It plays wherever `VideoPlaybackDialog.supportsOfficialEmbeds` allows: CEF, or the web view on macOS, Android and iOS. Everywhere else it opens in the browser.

On web the card's thumbnail and title come from the homeserver's URL preview, which reads the reel's og: tags. Without that preview, the card is a plain "Instagram Reel".

## When it breaks

The embed page's JSON and markup are not an API, and Instagram can change them. When it does, posts fall back to the official embed rather than failing. The fixtures in `commet/unit_test/fixtures/` (`instagram_reel_embed.html`, `instagram_photo_embed.html`) are trimmed from real pages, so compare them against fresh ones:

```sh
curl -s -H 'Sec-Fetch-Mode: navigate' \
  https://www.instagram.com/reel/C2X_BmsPg5d/embed/captioned/ | grep -c contextJSON
curl -s -H 'Sec-Fetch-Mode: navigate' \
  https://www.instagram.com/p/BsOGulcndj-/embed/captioned/ | grep -c EmbeddedMediaImage
```

yt-dlp's Instagram extractor reads the same page as its fallback, so its changelog is a good early warning.
