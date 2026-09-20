// The booth builds yt-dlp's command line itself on Windows, so that the
// program (and the JavaScript runtime it starts in turn) gets a console with
// no window instead of one that flashes up. These pin the quoting: an output
// template naming a folder with a space in it, or a search for a song whose
// title has quotes in it, has to arrive as one argument.
import 'package:commet/client/matrix/components/dj/native/windows_hidden_process.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a plain argument is left alone', () {
    expect(quoteWindowsArgument('--no-playlist'), '--no-playlist');
    expect(quoteWindowsArgument(r'C:\Users\dj\yt-dlp.exe'),
        r'C:\Users\dj\yt-dlp.exe');
  });

  test('an empty argument is still an argument', () {
    expect(quoteWindowsArgument(''), '""');
  });

  test('spaces and tabs are quoted', () {
    expect(quoteWindowsArgument(r'C:\Program Files\dj-songs\a.%(ext)s'),
        r'"C:\Program Files\dj-songs\a.%(ext)s"');
    expect(quoteWindowsArgument('ytsearch1:Daft Punk - One More Time'),
        '"ytsearch1:Daft Punk - One More Time"');
  });

  test('quotes are escaped', () {
    expect(quoteWindowsArgument('say "hi"'), r'"say \"hi\""');
  });

  test('backslashes only double where they would escape a quote', () {
    // Inside the argument they mean themselves...
    expect(quoteWindowsArgument(r'a\b c'), r'"a\b c"');
    // ...before a quote, and before the closing one, they do not.
    expect(quoteWindowsArgument(r'a\"b c'), r'"a\\\"b c"');
    expect(quoteWindowsArgument(r'C:\songs\ dir'), r'"C:\songs\ dir"');
    // A trailing one would escape the closing quote, so it is doubled.
    expect(quoteWindowsArgument('C:\\my songs\\'), r'"C:\my songs\\"');
    // Without a space there is no quote for it to escape.
    expect(quoteWindowsArgument('C:\\songs\\'), 'C:\\songs\\');
  });
}
