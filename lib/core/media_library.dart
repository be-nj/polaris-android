import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:polaris/core/authentication.dart' as authentication;
import 'package:polaris/core/cache/collection.dart';
import 'package:polaris/core/cache/media.dart';
import 'package:polaris/core/client/api/v8_dto.dart' as dto;
import 'package:polaris/core/client/app_client.dart';
import 'package:polaris/core/connection.dart' as connection;
import 'package:polaris/core/playlist.dart';
import 'package:polaris/ui/strings.dart';
import 'package:polaris/ui/utils/format.dart';
import 'package:polaris/utils.dart';
import 'package:rxdart/rxdart.dart';

// Content style hints understood by Android Auto / Android Automotive OS.
// See https://developer.android.com/training/cars/media#apply_content_style
const _contentStyleBrowsableHint = 'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
const _contentStylePlayableHint = 'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
const _contentStyleList = 1;
const _contentStyleGrid = 2;
const _searchSupported = 'android.media.browse.SEARCH_SUPPORTED';

/// Extras attached to the browsable root, read by Android Auto when it connects to the media browser service.
const Map<String, dynamic> browsableRootExtras = {
  _searchSupported: true,
  _contentStyleBrowsableHint: _contentStyleList,
  _contentStylePlayableHint: _contentStyleList,
};

const _idRecent = 'polaris:recent';
const _idRandom = 'polaris:random';
const _idArtists = 'polaris:artists';
const _idPlaylists = 'polaris:playlists';
const _idFiles = 'polaris:files';

const _prefixAlbum = 'album:';
const _prefixArtist = 'artist:';
const _prefixDirectory = 'dir:';
const _prefixPlaylist = 'playlist:';
const _prefixSong = 'song:';
const _prefixPlayAll = 'playall:';
const _prefixSearch = 'search:';

const _serverWaitTimeout = Duration(seconds: 15);

/// Exposes the music collection as a media browsing tree, so that it can be browsed and played
/// from clients like Android Auto, which cannot display the regular app UI.
class MediaLibrary {
  final connection.Manager connectionManager;
  final authentication.Manager authenticationManager;
  final AppClient appClient;
  final CollectionCache collectionCache;
  final Playlist playlist;
  final AudioPlayer audioPlayer;

  final PublishSubject<Map<String, dynamic>> _rootChanged = PublishSubject();
  final _random = Random();

  MediaLibrary({
    required this.connectionManager,
    required this.authenticationManager,
    required this.appClient,
    required this.collectionCache,
    required this.playlist,
    required this.audioPlayer,
  }) {
    connectionManager.addListener(_notifyRootChanged);
    authenticationManager.addListener(_notifyRootChanged);
  }

  /// Emits when the list of root categories may have changed (eg. when entering offline mode).
  Stream<Map<String, dynamic>> get rootChanged => _rootChanged.stream;

  void _notifyRootChanged() {
    _rootChanged.add(<String, dynamic>{});
  }

  bool get _isOnline => connectionManager.isConnected() && authenticationManager.isAuthenticated();
  bool get _isOffline => connectionManager.state == connection.State.offlineMode;

  /// When the app is started by Android Auto, the connection to the server is still being re-established.
  /// Wait for it (up to a timeout) instead of returning empty results right away.
  Future<bool> _waitForServer() async {
    if (_isOnline) {
      return true;
    }
    if (_isOffline) {
      return false;
    }

    final completer = Completer<void>();
    void listener() {
      final state = connectionManager.state;
      final isSettled = _isOnline ||
          _isOffline ||
          state == connection.State.disconnected ||
          (state == connection.State.connected &&
              authenticationManager.state == authentication.State.unauthenticated);
      if (isSettled && !completer.isCompleted) {
        completer.complete();
      }
    }

    connectionManager.addListener(listener);
    authenticationManager.addListener(listener);
    try {
      listener();
      await completer.future.timeout(_serverWaitTimeout);
    } on TimeoutException {
      // Fall through and report whatever state we ended up in.
    } finally {
      connectionManager.removeListener(listener);
      authenticationManager.removeListener(listener);
    }
    return _isOnline;
  }

  Future<List<MediaItem>> getChildren(String parentMediaId) async {
    try {
      return await _getChildren(parentMediaId);
    } catch (e) {
      developer.log('Error while listing children of $parentMediaId', error: e);
      return [];
    }
  }

  Future<List<MediaItem>> _getChildren(String parentMediaId) async {
    if (parentMediaId == AudioService.browsableRootId) {
      return _getRoot();
    }
    if (parentMediaId == AudioService.recentRootId) {
      final current = audioPlayer.sequenceState?.currentSource?.tag as MediaItem?;
      return current != null ? [current] : [];
    }
    if (parentMediaId == _idRecent) {
      if (!await _waitForServer()) return [];
      return _makeAlbumItems(await appClient.apiClient!.recent(offset: 0));
    }
    if (parentMediaId == _idRandom) {
      if (!await _waitForServer()) return [];
      return _makeAlbumItems(await appClient.apiClient!.random(seed: _random.nextInt(1 << 31), offset: 0));
    }
    if (parentMediaId == _idArtists) {
      if (!await _waitForServer()) return [];
      final artists = await appClient.apiClient!.getArtists();
      artists.sort((a, b) => compareStrings(a.name, b.name));
      return artists.map(_makeArtistItem).toList();
    }
    if (parentMediaId == _idPlaylists) {
      if (!await _waitForServer()) return [];
      final playlists = await appClient.apiClient!.listPlaylists();
      return playlists.map(_makePlaylistItem).toList();
    }
    if (parentMediaId == _idFiles) {
      return _getDirectoryChildren('');
    }
    if (parentMediaId.startsWith(_prefixArtist)) {
      if (!await _waitForServer()) return [];
      final artist = await appClient.apiClient!.getArtist(parentMediaId.substring(_prefixArtist.length));
      return _makeAlbumItems(artist.albums);
    }
    if (parentMediaId.startsWith(_prefixAlbum)) {
      if (!await _waitForServer()) return [];
      final album = await _getAlbum(parentMediaId);
      final artUri = await _getArtUri(album.artwork);
      return album.songs.map((s) => _makeSongItem(s, parentMediaId, artUri: artUri)).toList();
    }
    if (parentMediaId.startsWith(_prefixPlaylist)) {
      if (!await _waitForServer()) return [];
      final playlist = await appClient.apiClient!.getPlaylist(parentMediaId.substring(_prefixPlaylist.length));
      return [
        _makePlayAllItem(parentMediaId),
        ...playlist.songs.paths.map((path) => _makeSongPathItem(path, parentMediaId)),
      ];
    }
    if (parentMediaId.startsWith(_prefixDirectory)) {
      return _getDirectoryChildren(parentMediaId.substring(_prefixDirectory.length));
    }
    return [];
  }

  List<MediaItem> _getRoot() {
    final onlineOnly = !_isOffline;
    return [
      if (onlineOnly) _makeCategoryItem(_idRecent, autoRecentlyAdded, _contentStyleGrid),
      if (onlineOnly) _makeCategoryItem(_idRandom, autoRandom, _contentStyleGrid),
      if (onlineOnly) _makeCategoryItem(_idArtists, autoArtists, _contentStyleList),
      if (onlineOnly) _makeCategoryItem(_idPlaylists, autoPlaylists, _contentStyleList),
      _makeCategoryItem(_idFiles, autoFiles, _contentStyleList),
    ];
  }

  Future<List<MediaItem>> _getDirectoryChildren(String path) async {
    await _waitForServer();
    final parentId = '$_prefixDirectory$path';
    final entries = await appClient.browse(path);
    return [
      if (path.isNotEmpty && entries.isNotEmpty) _makePlayAllItem(parentId),
      ...entries.map((entry) {
        if (entry.isDirectory) {
          return MediaItem(
            id: '$_prefixDirectory${entry.path}',
            title: entry.formatName(),
            playable: false,
          );
        }
        return _makeSongPathItem(entry.path, parentId);
      }),
    ];
  }

  Future<dto.Album> _getAlbum(String albumId) async {
    final List<dynamic> key = jsonDecode(albumId.substring(_prefixAlbum.length));
    return appClient.apiClient!.getAlbum(key[0] as String, (key[1] as List<dynamic>).cast<String>());
  }

  Future<Uri?> _getArtUri(String? artwork) async {
    if (artwork == null) {
      return null;
    }
    return appClient.getImageURI(artwork, ArtworkSize.small);
  }

  MediaItem _makeCategoryItem(String id, String title, int childrenStyle) {
    return MediaItem(
      id: id,
      title: title,
      playable: false,
      extras: {
        _contentStyleBrowsableHint: childrenStyle,
        _contentStylePlayableHint: childrenStyle,
      },
    );
  }

  Future<List<MediaItem>> _makeAlbumItems(List<dto.AlbumHeader> albums) async {
    return Future.wait(albums.map((album) async {
      return MediaItem(
        id: '$_prefixAlbum${jsonEncode([album.name, album.mainArtists])}',
        title: album.name,
        artist: album.formatArtists(),
        displaySubtitle: album.formatArtists(),
        artUri: await _getArtUri(album.artwork),
        playable: false,
        extras: {
          _contentStylePlayableHint: _contentStyleList,
        },
      );
    }));
  }

  MediaItem _makeArtistItem(dto.ArtistHeader artist) {
    return MediaItem(
      id: '$_prefixArtist${artist.name}',
      title: artist.name,
      playable: false,
      extras: {
        _contentStyleBrowsableHint: _contentStyleGrid,
      },
    );
  }

  MediaItem _makePlaylistItem(dto.PlaylistHeader playlist) {
    return MediaItem(
      id: '$_prefixPlaylist${playlist.name}',
      title: playlist.name,
      playable: false,
    );
  }

  MediaItem _makePlayAllItem(String contextId) {
    return MediaItem(
      id: '$_prefixPlayAll$contextId',
      title: autoPlayAll,
      playable: true,
    );
  }

  MediaItem _makeSongItem(dto.Song song, String contextId, {Uri? artUri}) {
    return MediaItem(
      id: '$_prefixSong${jsonEncode([song.path, contextId])}',
      title: song.formatTitle(),
      artist: song.formatArtists(),
      album: song.album,
      displaySubtitle: song.formatArtists(),
      duration: song.duration != null ? Duration(seconds: song.duration!) : null,
      artUri: artUri,
      playable: true,
    );
  }

  MediaItem _makeSongPathItem(String path, String contextId) {
    final host = connectionManager.url;
    final song = host != null ? collectionCache.getSong(host, path) : null;
    if (song != null) {
      return _makeSongItem(song, contextId);
    }
    return MediaItem(
      id: '$_prefixSong${jsonEncode([path, contextId])}',
      title: basename(path),
      playable: true,
    );
  }

  /// Replaces the queue with the songs designated by [mediaId] and starts playback.
  Future<void> playFromMediaId(String mediaId) async {
    try {
      if (mediaId.startsWith(_prefixPlayAll)) {
        final contextId = mediaId.substring(_prefixPlayAll.length);
        await _playSongs(await _listSongs(contextId, recursive: true), 0);
        return;
      }
      if (mediaId.startsWith(_prefixSong)) {
        final List<dynamic> key = jsonDecode(mediaId.substring(_prefixSong.length));
        final String path = key[0] as String;
        final String contextId = key[1] as String;
        List<String> songs = await _listSongs(contextId, recursive: false);
        int index = songs.indexOf(path);
        if (index < 0) {
          songs = [path];
          index = 0;
        }
        await _playSongs(songs, index);
        return;
      }
      if (mediaId.startsWith(_prefixAlbum) || mediaId.startsWith(_prefixPlaylist)) {
        await _playSongs(await _listSongs(mediaId, recursive: true), 0);
        return;
      }
    } catch (e) {
      developer.log('Error while playing $mediaId', error: e);
    }
  }

  /// Searches the collection and plays the results. Used for voice requests like "Play X on Polaris".
  Future<void> playFromSearch(String query) async {
    try {
      if (!await _waitForServer()) {
        await audioPlayer.play();
        return;
      }
      if (query.trim().isEmpty) {
        // Generic "play music" request: play a random album.
        final albums = await appClient.apiClient!.random(seed: _random.nextInt(1 << 31), offset: 0);
        if (albums.isEmpty) return;
        final album = await appClient.apiClient!.getAlbum(albums.first.name, albums.first.mainArtists);
        await _playSongs(album.songs.map((s) => s.path).toList(), 0);
        return;
      }
      final results = await appClient.apiClient!.search(query);
      await _playSongs(results.paths, 0);
    } catch (e) {
      developer.log('Error while playing search results for $query', error: e);
    }
  }

  Future<List<MediaItem>> search(String query) async {
    try {
      if (!await _waitForServer() || query.trim().isEmpty) {
        return [];
      }
      final results = await appClient.apiClient!.search(query);
      final contextId = '$_prefixSearch$query';
      final songsByPath = {for (final song in results.firstSongs) song.path: song};
      return results.paths.take(100).map((path) {
        final song = songsByPath[path];
        if (song != null) {
          return _makeSongItem(song, contextId);
        }
        return _makeSongPathItem(path, contextId);
      }).toList();
    } catch (e) {
      developer.log('Error while searching for $query', error: e);
      return [];
    }
  }

  Future<List<String>> _listSongs(String contextId, {required bool recursive}) async {
    if (contextId.startsWith(_prefixAlbum)) {
      final album = await _getAlbum(contextId);
      return album.songs.map((s) => s.path).toList();
    }
    if (contextId.startsWith(_prefixPlaylist)) {
      final playlist = await appClient.apiClient!.getPlaylist(contextId.substring(_prefixPlaylist.length));
      return playlist.songs.paths;
    }
    if (contextId.startsWith(_prefixSearch)) {
      final results = await appClient.apiClient!.search(contextId.substring(_prefixSearch.length));
      return results.paths;
    }
    if (contextId.startsWith(_prefixDirectory)) {
      final path = contextId.substring(_prefixDirectory.length);
      if (recursive) {
        return (await appClient.flatten(path)).paths;
      }
      final entries = await appClient.browse(path);
      return entries.where((e) => !e.isDirectory).map((e) => e.path).toList();
    }
    return [];
  }

  Future<void> _playSongs(List<String> songs, int startIndex) async {
    if (songs.isEmpty) {
      return;
    }
    await playlist.clear();
    await playlist.queueLast(songs, autoPlay: false);
    final queueLength = audioPlayer.sequence?.length ?? 0;
    if (queueLength == 0) {
      return;
    }
    await audioPlayer.seek(Duration.zero, index: startIndex.clamp(0, queueLength - 1));
    await audioPlayer.play();
  }
}
