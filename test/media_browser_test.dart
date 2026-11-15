import 'mock/client.dart' as mock;
import 'mock/connection.dart' as mock;
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polaris/core/cache/collection.dart';
import 'package:polaris/core/client/api/v8_dto.dart' as dto;
import 'package:polaris/core/media_browser.dart';
import 'package:polaris/core/media_item.dart';
import 'package:polaris/ui/strings.dart';

const host = 'host';
const aegeusDirectory = 'root/Heron/Aegeus';
const labyrinth = '$aegeusDirectory/Labyrinth.mp3';
const fallingInwards = '$aegeusDirectory/Falling Inwards.mp3';
const maze = '$aegeusDirectory/Bonus/Maze.mp3';
const aegeusSongs = [labyrinth, fallingInwards];
const searchResults = [fallingInwards, maze, labyrinth];

class APIClient extends mock.APIClient {
  final aegeus = dto.Album(name: 'Aegeus', mainArtists: ['Heron', 'Friends'])
    ..songs = aegeusSongs.map((path) => dto.Song(path: path)).toList();

  @override
  Future<List<dto.AlbumHeader>> recent({required int offset}) async => [aegeus];

  @override
  Future<List<dto.AlbumHeader>> random({required int seed, required int offset}) async => [aegeus, aegeus];

  @override
  Future<dto.Album> getAlbum(String name, List<String> mainArtists) async {
    expect(name, equals(aegeus.name));
    expect(mainArtists, equals(aegeus.mainArtists));
    return aegeus;
  }

  @override
  Future<List<dto.PlaylistHeader>> listPlaylists() async {
    return [dto.PlaylistHeader(name: 'Road Trip', numSongsByGenre: {}, duration: 0)];
  }

  @override
  Future<dto.Playlist> getPlaylist(String name) async {
    expect(name, equals('Road Trip'));
    return dto.Playlist(
      name: name,
      duration: 0,
      numSongsByGenre: <String, int>{},
      songs: dto.SongList(paths: [maze, labyrinth], firstSongs: []),
    );
  }

  @override
  Future<dto.SongList> search(String path) async {
    if (path == 'error') {
      throw 'Search failed';
    }
    expect(path, equals('heron'));
    return dto.SongList(paths: searchResults, firstSongs: []);
  }
}

class AppClient extends mock.AppClient {
  AppClient(super.apiClient);

  @override
  Future<List<dto.BrowserEntry>> browse(String path, {bool useCache = true}) async {
    return switch (path) {
      '' => [dto.BrowserEntry(path: 'root', isDirectory: true)],
      aegeusDirectory => [
          dto.BrowserEntry(path: '$aegeusDirectory/Bonus', isDirectory: true),
          dto.BrowserEntry(path: labyrinth, isDirectory: false),
          dto.BrowserEntry(path: fallingInwards, isDirectory: false),
        ],
      _ => throw 'Directory not found',
    };
  }

  @override
  Future<dto.SongList> flatten(String path) async {
    expect(path, equals(aegeusDirectory));
    return dto.SongList(paths: [maze, labyrinth, fallingInwards], firstSongs: []);
  }
}

MediaBrowser makeMediaBrowser({bool connected = true, String? host = host, CollectionCache? collectionCache}) {
  return MediaBrowser(
    connectionManager: mock.ConnectionManager(host, connected: connected),
    collectionCache: collectionCache ?? CollectionCache(Collection()),
    appClient: AppClient(connected ? APIClient() : null),
  );
}

Future<MediaItem> findChild(MediaBrowser mediaBrowser, String parentMediaID, String title) async {
  final children = await mediaBrowser.getChildren(parentMediaID);
  return children.firstWhere((item) => item.title == title);
}

Future<MediaItem> findCategory(MediaBrowser mediaBrowser, String title) {
  return findChild(mediaBrowser, AudioService.browsableRootId, title);
}

List<String> titles(List<MediaItem> items) => items.map((i) => i.title).toList();

void main() {
  test('Lists categories', () async {
    final mediaBrowser = makeMediaBrowser();
    final root = await mediaBrowser.getChildren(AudioService.browsableRootId);
    expect(titles(root),
        equals([mediaBrowserRecentAlbums, mediaBrowserRandomAlbums, mediaBrowserPlaylists, mediaBrowserFiles]));
    expect(root.every((item) => item.playable == false), isTrue);
    expect(root.map((item) => item.id).toSet().length, equals(root.length));
  });

  test('Only lists files while offline', () async {
    final mediaBrowser = makeMediaBrowser(connected: false);
    final root = await mediaBrowser.getChildren(AudioService.browsableRootId);
    expect(titles(root), equals([mediaBrowserFiles]));
  });

  test('Lists nothing when no server is known', () async {
    final mediaBrowser = makeMediaBrowser(connected: false, host: null);
    expect(await mediaBrowser.getChildren(AudioService.browsableRootId), isEmpty);
  });

  test('Lists albums', () async {
    final mediaBrowser = makeMediaBrowser();

    final recent = await findCategory(mediaBrowser, mediaBrowserRecentAlbums);
    final recentAlbums = await mediaBrowser.getChildren(recent.id);
    expect(titles(recentAlbums), equals(['Aegeus']));
    expect(recentAlbums.first.artist, equals('Heron, Friends'));
    expect(recentAlbums.first.playable, isFalse);

    final random = await findCategory(mediaBrowser, mediaBrowserRandomAlbums);
    expect(titles(await mediaBrowser.getChildren(random.id)), equals(['Aegeus', 'Aegeus']));
  });

  test('Lists songs in albums', () async {
    final mediaBrowser = makeMediaBrowser();
    final recent = await findCategory(mediaBrowser, mediaBrowserRecentAlbums);
    final album = await findChild(mediaBrowser, recent.id, 'Aegeus');
    final songs = await mediaBrowser.getChildren(album.id);
    expect(songs.map((s) => s.getSongPath()), equals(aegeusSongs));
    expect(songs.every((s) => s.playable == true), isTrue);
    expect(titles(songs), equals(['Labyrinth.mp3', 'Falling Inwards.mp3']));
  });

  test('Uses known song metadata', () async {
    final collectionCache = CollectionCache(Collection());
    collectionCache.putSongs(host, [
      dto.Song(path: fallingInwards)
        ..title = 'Falling Inwards'
        ..artists = ['Heron']
        ..album = 'Aegeus'
        ..duration = 300
    ]);
    final mediaBrowser = makeMediaBrowser(collectionCache: collectionCache);
    final recent = await findCategory(mediaBrowser, mediaBrowserRecentAlbums);
    final album = await findChild(mediaBrowser, recent.id, 'Aegeus');
    final song = await findChild(mediaBrowser, album.id, 'Falling Inwards');
    expect(song.artist, equals('Heron'));
    expect(song.album, equals('Aegeus'));
    expect(song.duration, equals(const Duration(seconds: 300)));
    expect(song.getSongPath(), equals(fallingInwards));
  });

  test('Playing a song plays the album it was selected from', () async {
    final mediaBrowser = makeMediaBrowser();
    final recent = await findCategory(mediaBrowser, mediaBrowserRecentAlbums);
    final album = await findChild(mediaBrowser, recent.id, 'Aegeus');
    final song = await findChild(mediaBrowser, album.id, 'Falling Inwards.mp3');

    final playback = await mediaBrowser.getPlayback(song.id);
    expect(playback?.songs, equals(aegeusSongs));
    expect(playback?.index, equals(1));

    final albumPlayback = await mediaBrowser.getPlayback(album.id);
    expect(albumPlayback?.songs, equals(aegeusSongs));
    expect(albumPlayback?.index, equals(0));
  });

  test('Lists and plays playlists', () async {
    final mediaBrowser = makeMediaBrowser();
    final playlists = await findCategory(mediaBrowser, mediaBrowserPlaylists);
    final playlist = await findChild(mediaBrowser, playlists.id, 'Road Trip');
    expect(playlist.playable, isFalse);

    final songs = await mediaBrowser.getChildren(playlist.id);
    expect(songs.map((s) => s.getSongPath()), equals([maze, labyrinth]));

    final playback = await mediaBrowser.getPlayback(songs[1].id);
    expect(playback?.songs, equals([maze, labyrinth]));
    expect(playback?.index, equals(1));
  });

  test('Lists files and directories', () async {
    final mediaBrowser = makeMediaBrowser();
    final files = await findCategory(mediaBrowser, mediaBrowserFiles);
    final topLevel = await mediaBrowser.getChildren(files.id);
    expect(titles(topLevel), equals(['root']));
    expect(topLevel.first.playable, isFalse);
  });

  test('Plays files along with their siblings', () async {
    final mediaBrowser = makeMediaBrowser(connected: false);
    final children = await mediaBrowser.getChildren('["directory","$aegeusDirectory"]');
    expect(titles(children), equals(['Bonus', 'Labyrinth.mp3', 'Falling Inwards.mp3']));
    expect(children.map((c) => c.playable), equals([false, true, true]));

    final playback = await mediaBrowser.getPlayback(children[2].id);
    expect(playback?.songs, equals(aegeusSongs));
    expect(playback?.index, equals(1));
  });

  test('Playing a directory includes its subdirectories', () async {
    final mediaBrowser = makeMediaBrowser();
    final playback = await mediaBrowser.getPlayback('["directory","$aegeusDirectory"]');
    expect(playback?.songs, equals([maze, labyrinth, fallingInwards]));
    expect(playback?.index, equals(0));
  });

  test('Searches', () async {
    final mediaBrowser = makeMediaBrowser();
    final results = await mediaBrowser.search('heron');
    expect(results.map((s) => s.getSongPath()), equals(searchResults));

    final playback = await mediaBrowser.getPlayback(results[1].id);
    expect(playback?.songs, equals(searchResults));
    expect(playback?.index, equals(1));

    final searchPlayback = await mediaBrowser.getSearchPlayback(' heron ');
    expect(searchPlayback?.songs, equals(searchResults));
    expect(searchPlayback?.index, equals(0));
  });

  test('Handles empty and failed searches', () async {
    final mediaBrowser = makeMediaBrowser();
    expect(await mediaBrowser.search(''), isEmpty);
    expect(await mediaBrowser.getSearchPlayback('  '), isNull);
    expect(await mediaBrowser.search('error'), isEmpty);
    expect(await mediaBrowser.getSearchPlayback('error'), isNull);
    expect(await makeMediaBrowser(connected: false).search('heron'), isEmpty);
  });

  test('Handles errors and unknown media', () async {
    final mediaBrowser = makeMediaBrowser();
    expect(await mediaBrowser.getChildren('not a media ID'), isEmpty);
    expect(await mediaBrowser.getChildren('["unknown"]'), isEmpty);
    expect(await mediaBrowser.getChildren('[]'), isEmpty);
    expect(await mediaBrowser.getChildren('["directory","missing"]'), isEmpty);
    expect(await mediaBrowser.getPlayback('not a media ID'), isNull);
    expect(await mediaBrowser.getPlayback('["directory","missing"]'), isNull);

    // Songs whose list can no longer be found are played on their own
    final playback = await mediaBrowser.getPlayback('["song","$maze","[\\"directory\\",\\"missing\\"]"]');
    expect(playback?.songs, equals([maze]));
    expect(playback?.index, equals(0));
  });
}
