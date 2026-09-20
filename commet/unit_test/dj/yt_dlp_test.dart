// The booth records what each song was actually downloaded as, so a track
// that sounds thin can be told apart from one that is. yt-dlp prints these
// fields with the file name, before the first byte arrives.
import 'package:commet/client/matrix/components/dj/native/yt_dlp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("YouTube's best AAC reads back in full", () {
    // itag 140, what formatSelector picks for a YouTube link.
    expect(
        describeDownloadedAudio({
          'format_id': '140',
          'acodec': 'mp4a.40.2',
          'abr': 129.502,
          'asr': 44100,
          'audio_channels': 2,
        }),
        'mp4a.40.2, 130 kbps, 44.1 kHz, stereo (format 140)');
  });

  test('a whole-numbered sample rate has no decimals', () {
    expect(
        describeDownloadedAudio({
          'format_id': 'hls_mp3_128',
          'acodec': 'mp3',
          'abr': 128,
          'asr': 48000,
          'audio_channels': 1,
        }),
        'mp3, 128 kbps, 48 kHz, mono (format hls_mp3_128)');
  });

  test('fields the site did not give are left out, not guessed', () {
    expect(describeDownloadedAudio({'format_id': 'http_mp3', 'acodec': 'mp3'}),
        'mp3 (format http_mp3)');
    expect(describeDownloadedAudio({'acodec': 'none', 'abr': 0}),
        'audio of an unreported kind');
    expect(describeDownloadedAudio(const {}), 'audio of an unreported kind');
  });
}
