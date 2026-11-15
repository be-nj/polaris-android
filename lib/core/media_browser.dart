import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:polaris/core/cache/collection.dart';
import 'package:polaris/core/client/api/api_client.dart';
import 'package:polaris/core/client/api/v8_dto.dart' as dto;
import 'package:polaris/core/client/app_client.dart';
import 'package:polaris/core/connection.dart' as connection;
import 'package:polaris/core/media_item.dart';
import 'package:polaris/ui/strings.dart';
import 'package:polaris/ui/utils/format.dart';
import 'package:polaris/utils.dart';

enum _Kind {
  recentAlbums,
  randomAlbums,
  playlists,
  album,
  playlist,
  directory,
  search,
  song,
}

/// Identifies an entry of the media tree. Media IDs are opaque strings as far as
/// media browsing clients are concerned.
class _MediaID {
  final _Kind kind;
  final List<String> arguments;

  const _MediaID(this.kind, [this.arguments = const []]);

  factory _MediaID.album(dto.AlbumHeader album) => _MediaID(_Kind.album, [album.name, ...album.mainArtists]);
  factory _MediaID.song(String path, _MediaID parent) => _MediaID(_Kind.song, [path, parent.encode()]);

  static _MediaID? decode(String mediaID) {
    try {
      final components = (jsonDecode(mediaID) as List<dynamic>).cast<String>();
      final kind = _Kind.values.asNameMap()[components.first];
      if (kind == null) {
        return null;
      }
      return _MediaID(kind, components.sublist(1));
    } catch (e) {
      return null;
    }
  }

  String encode() => jsonEncode([kind.name, ...arguments]);
}

/// Content of an entry of the media tree
class _Listing {
  List<dto.AlbumHeader> albums = [];
  List<String> playlists = [];
  List<String> directories = [];
  List<String> songs = [];
}

/// Songs to play in response to a playback request, and which one to begin with.
class MediaBrowserPlayback {
  final List<String> songs;
  final int index;
  MediaBrowserPlayback(this.songs, this.index);
}

/// Presents the music collection as a tree of media items, which can be browsed
/// and played from outside of the app (eg. by Android Auto).
class MediaBrowser {
  static const int maxSearchResults = 100;

  final connection.ManagerInterface connectionManager;
  final CollectionCache collectionCache;
  final AppClientInterface appClient;

  // Keeps the list of random albums stable while it is being browsed
  final int _randomSeed = Random().nextInt(1 << 31);

  MediaBrowser({
    required this.connectionManager,
    required this.collectionCache,
    required this.appClient,
  });

  /// Lists the content of an entry of the media tree.
  Future<List<MediaItem>> getChildren(String parentMediaID) async {
    if (parentMediaID == AudioService.browsableRootId) {
      return _listRoot();
    }
    final parent = _MediaID.decode(parentMediaID);
    if (parent == null) {
      return [];
    }
    final listing = await _list(parent);
    return [
      ...listing.albums.map(_makeAlbumItem),
      ...listing.playlists.map((name) => _makeBrowsableItem(_MediaID(_Kind.playlist, [name]), name)),
      ...listing.directories.map((path) => _makeBrowsableItem(_MediaID(_Kind.directory, [path]), basename(path))),
      ...listing.songs.map((path) => _makeSongItem(path, parent)),
    ];
  }

  /// Lists songs matching a search query.
  Future<List<MediaItem>> search(String query) async {
    return getChildren(_MediaID(_Kind.search, [query]).encode());
  }

  /// Determines what to play when a media item is selected. Selecting a song
  /// plays the list it is part of, beginning with this song.
  Future<MediaBrowserPlayback?> getPlayback(String mediaID) async {
    final id = _MediaID.decode(mediaID);
    if (id == null) {
      return null;
    }

    if (id.kind != _Kind.song) {
      final songs = await _flatten(id);
      return songs.isEmpty ? null : MediaBrowserPlayback(songs, 0);
    }

    final String path = id.arguments[0];
    final parent = _MediaID.decode(id.arguments[1]);
    final List<String> siblings = parent == null ? [] : (await _list(parent)).songs;
    final int index = siblings.indexOf(path);
    if (index < 0) {
      return MediaBrowserPlayback([path], 0);
    }
    return MediaBrowserPlayback(siblings, index);
  }

  /// Determines what to play in response to a search (eg. a voice command).
  Future<MediaBrowserPlayback?> getSearchPlayback(String query) async {
    return getPlayback(_MediaID(_Kind.search, [query]).encode());
  }

  List<MediaItem> _listRoot() {
    if (connectionManager.url == null) {
      return [];
    }
    final files = _makeBrowsableItem(const _MediaID(_Kind.directory, ['']), mediaBrowserFiles);
    if (!connectionManager.isConnected()) {
      return [files];
    }
    return [
      _makeBrowsableItem(const _MediaID(_Kind.recentAlbums), mediaBrowserRecentAlbums),
      _makeBrowsableItem(const _MediaID(_Kind.randomAlbums), mediaBrowserRandomAlbums),
      if ((connectionManager.apiVersion ?? 0) >= 8)
        _makeBrowsableItem(const _MediaID(_Kind.playlists), mediaBrowserPlaylists),
      files,
    ];
  }

  Future<_Listing> _list(_MediaID id) async {
    final listing = _Listing();
    try {
      final APIClientInterface? apiClient = appClient.apiClient;
      switch (id.kind) {
        case _Kind.recentAlbums:
          listing.albums = await apiClient?.recent(offset: 0) ?? [];
        case _Kind.randomAlbums:
          listing.albums = await apiClient?.random(seed: _randomSeed, offset: 0) ?? [];
        case _Kind.playlists:
          listing.playlists = (await apiClient?.listPlaylists() ?? []).map((p) => p.name).toList();
        case _Kind.album:
          final album = await apiClient?.getAlbum(id.arguments.first, id.arguments.sublist(1));
          listing.songs = (album?.songs ?? []).map((s) => s.path).toList();
        case _Kind.playlist:
          final playlist = await apiClient?.getPlaylist(id.arguments.first);
          listing.songs = playlist?.songs.paths ?? [];
        case _Kind.directory:
          final entries = await appClient.browse(id.arguments.first);
          listing.directories = entries.where((e) => e.isDirectory).map((e) => e.path).toList();
          listing.songs = entries.where((e) => !e.isDirectory).map((e) => e.path).toList();
        case _Kind.search:
          final String query = id.arguments.first.trim();
          if (query.isNotEmpty) {
            final results = await apiClient?.search(query);
            listing.songs = (results?.paths ?? []).take(maxSearchResults).toList();
          }
        case _Kind.song:
          break;
      }
    } catch (e) {
      developer.log('Error while listing media items: $e');
    }
    return listing;
  }

  /// Lists all the songs to play when an entry of the media tree is played as a whole.
  Future<List<String>> _flatten(_MediaID id) async {
    try {
      if (id.kind == _Kind.directory) {
        return (await appClient.flatten(id.arguments.first)).paths;
      }
    } catch (e) {
      developer.log('Error while listing media items: $e');
      return [];
    }
    return (await _list(id)).songs;
  }

  MediaItem _makeBrowsableItem(_MediaID id, String title) {
    return MediaItem(id: id.encode(), title: title, playable: false);
  }

  MediaItem _makeAlbumItem(dto.AlbumHeader album) {
    return MediaItem(
      id: _MediaID.album(album).encode(),
      title: album.name,
      artist: album.formatArtists(),
      playable: false,
    );
  }

  MediaItem _makeSongItem(String path, _MediaID parent) {
    final String id = _MediaID.song(path, parent).encode();
    final String? host = connectionManager.url;
    final dto.Song? song = host == null ? null : collectionCache.getSong(host, path);
    return song?.toMediaItem(id, null) ?? makeMediaItem(id, path);
  }
}
