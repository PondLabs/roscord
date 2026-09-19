// yt-dlp, as the DJ booth uses it: list what a link holds, and download one
// song's audio to the booth's cache, telling us the file as soon as it
// knows it so the song can play while it downloads.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:commet/client/matrix/components/dj/native/dj_tools.dart';

class YtDlpException implements Exception {
  final String message;
  YtDlpException(this.message);

  /// yt-dlp's own error line, without the noise around it.
  static YtDlpException fromOutput(String stderr, String fallback) {
    final lines = const LineSplitter()
        .convert(stderr)
        .map((l) => l.startsWith('ERROR:')
            ? l.substring(6).trim()
            // Its command line parser: an option this yt-dlp doesn't know.
            : l.contains(': error: ')
                ? l.substring(l.indexOf(': error: ') + 9).trim()
                : null)
        .whereType<String>()
        .toList();
    var message = lines.isEmpty ? fallback : lines.last;
    // "[youtube] dQw4w9WgXcQ: Video unavailable" -> "Video unavailable"
    message = message.replaceFirst(RegExp(r'^\[[^\]]+\]\s*[^:]*:\s*'), '');
    return YtDlpException(message);
  }

  @override
  String toString() => message;
}

/// A song's file and what yt-dlp said about it.
class YtDlpDownload {
  final String path;
  final Map<String, Object?> info;

  const YtDlpDownload(this.path, this.info);
}

/// A download under way.
class YtDlpFetch {
  /// The file yt-dlp is about to write, with its size (`filesize`, when the
  /// site gives it) and the song's details. The file may not exist yet.
  final Future<YtDlpDownload> started;

  /// The whole file is on disk.
  final Future<YtDlpDownload> finished;

  YtDlpFetch(this.started, this.finished);
}

class YtDlp {
  final DjToolPaths tools;

  YtDlp(this.tools);

  List<String> get _common => [
        '--ignore-config',
        '--no-warnings',
        '--js-runtimes',
        tools.jsRuntime,
      ];

  /// What [url] holds, without downloading: one video, or a playlist whose
  /// entries are only listed (`--flat-playlist`), which is fast.
  Future<Map<String, Object?>> inspect(String url,
      {bool playlist = false}) async {
    final result = await runQuietly(
        tools.ytDlp,
        [
          ..._common,
          '--dump-single-json',
          '--flat-playlist',
          playlist ? '--yes-playlist' : '--no-playlist',
          '--',
          url,
        ],
        timeout: const Duration(seconds: 90));
    final json = _lastJsonObject(result.stdout);
    if (json == null) {
      throw YtDlpException.fromOutput(result.stderr, "Couldn't read $url");
    }
    return json;
  }

  /// Audio formats the booth's decoder reads (AAC in MP4, MP3, Vorbis,
  /// FLAC) over plain HTTP: HLS from YouTube comes in MPEG-TS, which it
  /// doesn't read. MP3 is the exception, SoundCloud's HLS MP3 segments join
  /// into a valid file. The last resort is a small video with AAC audio,
  /// never a big HLS one.
  static const formatSelector = 'ba[acodec^=mp4a][protocol^=http]'
      '/ba[acodec=mp3]'
      '/ba[ext=m4a][protocol^=http]'
      '/ba[ext=mp3]'
      '/ba[acodec=vorbis][protocol^=http]'
      '/ba[acodec=flac][protocol^=http]'
      '/b[ext=mp4][protocol^=http][height<=480]'
      '/ba[protocol^=http]';

  static const _fields = 'title,uploader,channel,artist,creator,duration,'
      'thumbnail,id,extractor_key';
  static const _startMark = 'commet-start ';
  static const _doneMark = 'commet-done ';

  /// YouTube now and then refuses a download (HTTP 403) that works when
  /// asked again.
  static const _attempts = 2;

  /// Downloads [source]'s audio as `<directory>/<name>.<ext>`, reporting
  /// the file before its first byte so it can be read as it arrives.
  /// [knownSitesOnly] leaves out yt-dlp's generic extractor, which fetches
  /// any page it is given: for songs another client named.
  YtDlpFetch fetch(String source,
      {required String directory,
      required String name,
      bool knownSitesOnly = false,
      Duration timeout = const Duration(minutes: 10)}) {
    final started = Completer<YtDlpDownload>();
    final finished = Completer<YtDlpDownload>();
    // Whoever only waits for one of them must not see the other fail
    // unhandled.
    started.future.ignore();
    finished.future.ignore();

    void fail(Object error) {
      if (!started.isCompleted) started.completeError(error);
      if (!finished.isCompleted) finished.completeError(error);
    }

    /// One run of yt-dlp: its final report, or null and why not.
    Future<(Map<String, Object?>?, String)> run() async {
      final process = await startQuietly(tools.ytDlp, [
        ..._common,
        if (knownSitesOnly) ...['--use-extractors', 'default,-generic'],
        '--no-playlist',
        '--no-progress',
        '--no-mtime',
        // Written in place, so it can be played while it grows. A cut
        // short one is never taken for a song: only a finished download
        // gets a record in the cache.
        '--no-part',
        // Fixups rewrite the file once it is done, under whoever is
        // reading it; the player reads fragmented MP4 as it is.
        '--fixup',
        'never',
        // --print alone would only simulate.
        '--no-simulate',
        '-f',
        formatSelector,
        '-o',
        // `%` is template syntax in yt-dlp's output name.
        '${directory.replaceAll('%', '%%')}${Platform.pathSeparator}'
            '$name.%(ext)s',
        '--print',
        'before_dl:$_startMark%(.{filename,filesize,$_fields})j',
        '--print',
        'after_move:$_doneMark%(.{filepath,$_fields})j',
        '--',
        source,
      ]);
      final err = StringBuffer();
      Map<String, Object?>? done;
      final errDone = process.stderr
          .transform(const SystemEncoding().decoder)
          .forEach(err.write);
      final outDone = process.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .forEach((line) {
        if (line.startsWith(_startMark)) {
          final info = _jsonObject(line.substring(_startMark.length));
          final path = info?['filename'];
          if (info != null && path is String && !started.isCompleted) {
            started.complete(YtDlpDownload(path, info));
          }
        } else if (line.startsWith(_doneMark)) {
          done = _jsonObject(line.substring(_doneMark.length)) ?? done;
        }
      });
      try {
        await Future.wait([outDone, errDone]).timeout(timeout);
      } on TimeoutException {
        process.kill();
        throw YtDlpException('The download took too long');
      }
      final path = done?['filepath'];
      final ok = path is String && await File(path).exists();
      return (ok ? done : null, err.toString());
    }

    () async {
      try {
        for (var attempt = 1;; attempt++) {
          final (info, err) = await run();
          if (info != null) {
            final download = YtDlpDownload(info['filepath'] as String, info);
            if (!started.isCompleted) started.complete(download);
            finished.complete(download);
            return;
          }
          // Again, unless some of the song got written: a player may be
          // reading it.
          final file =
              started.isCompleted ? File((await started.future).path) : null;
          final written =
              file != null && await file.exists() && await file.length() > 0;
          if (attempt >= _attempts || written) {
            throw YtDlpException.fromOutput(err, "Couldn't download the song");
          }
          // yt-dlp would take an empty file for a finished download.
          if (file != null && await file.exists()) await file.delete();
        }
      } catch (e) {
        fail(e);
      }
    }();

    return YtDlpFetch(started.future, finished.future);
  }

  static Map<String, Object?>? _jsonObject(String text) {
    try {
      final json = jsonDecode(text.trim());
      return json is Map<String, Object?> ? json : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?>? _lastJsonObject(String output) {
    for (final line in const LineSplitter().convert(output).reversed) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      try {
        final json = jsonDecode(trimmed);
        if (json is Map<String, Object?>) return json;
      } catch (_) {}
    }
    return null;
  }
}
