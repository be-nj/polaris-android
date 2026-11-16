import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:polaris/core/cache/collection.dart';
import 'package:polaris/core/cache/media.dart';
import 'package:polaris/core/client/api/v8_dto.dart' as dto;
import 'package:polaris/core/client/app_client.dart';
import 'package:polaris/core/connection.dart' as connection;
import 'package:polaris/core/media_item.dart';
import 'package:polaris/core/media_library.dart';
import 'package:rxdart/rxdart.dart';

Future<PolarisAudioHandler> initAudioService({
  required connection.Manager connectionManager,
  required CollectionCache collectionCache,
  required AppClient appClient,
}) async {
  return await AudioService.init(
    builder: () => PolarisAudioHandler(
      connectionManager: connectionManager,
      collectionCache: collectionCache,
      appClient: appClient,
    ),
    config: const AudioServiceConfig(
      androidNotificationIcon: "drawable/notification_icon",
      androidNotificationChannelName: 'Polaris Audio Playback',
      androidNotificationOngoing: true,
      androidBrowsableRootExtras: browsableRootExtras,
    ),
  );
}

class PolarisAudioHandler extends BaseAudioHandler with SeekHandler {
  final connection.Manager connectionManager;
  final CollectionCache collectionCache;
  final AppClient appClient;

  final audioPlayer = AudioPlayer();
  final BehaviorSubject<dto.Song?> _currentSong = BehaviorSubject.seeded(null);
  Stream<dto.Song?> get currentSong => _currentSong.stream;

  // The media library depends on objects which are created after the audio handler, so it is attached later.
  // Requests coming from media browsers (eg. Android Auto) wait until it is available.
  final Completer<MediaLibrary> _mediaLibrary = Completer();
  final BehaviorSubject<Map<String, dynamic>> _rootChanged = BehaviorSubject.seeded(<String, dynamic>{});

  PolarisAudioHandler({
    required this.collectionCache,
    required this.connectionManager,
    required this.appClient,
  }) {
    _forwardPlaybackState();
    _forwardSongMetadata();
  }

  void _forwardSongMetadata() {
    audioPlayer.sequenceStateStream.listen((sequenceState) async {
      final host = connectionManager.url;
      final currentMediaItem = sequenceState?.currentSource?.tag as MediaItem?;
      if (currentMediaItem == null || host == null) {
        _currentSong.value = null;
        mediaItem.add(null);
        return;
      }

      final path = currentMediaItem.getSongPath();
      final song = collectionCache.getSong(host, path);
      _currentSong.value = song;
      if (song == null) {
        mediaItem.add(currentMediaItem);
        return;
      }

      final String? artwork = song.artwork;
      Uri? artworkUri;
      if (artwork != null) {
        artworkUri = await appClient.getImageURI(artwork, ArtworkSize.small);
      }
      mediaItem.add(song.toMediaItem(currentMediaItem.id, artworkUri));
    });
  }

  void _forwardPlaybackState() {
    audioPlayer.playbackEventStream.listen((PlaybackEvent event) {
      final playing = audioPlayer.playing;
      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [1, 3],
        systemActions: {
          MediaAction.pause,
          MediaAction.play,
          MediaAction.playPause,
          MediaAction.seek,
          MediaAction.seekBackward,
          MediaAction.seekForward,
        },
        processingState: switch (audioPlayer.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: audioPlayer.position,
        bufferedPosition: audioPlayer.bufferedPosition,
        speed: audioPlayer.speed,
        queueIndex: event.currentIndex,
      ));
    });
  }

  @override
  Future<void> play() => audioPlayer.play();

  @override
  Future<void> pause() => audioPlayer.pause();

  @override
  Future<void> stop() async {
    audioPlayer.stop();
    super.stop();
  }

  @override
  Future<void> seek(Duration position) => audioPlayer.seek(position);

  @override
  Future<void> skipToQueueItem(int index) => audioPlayer.seek(Duration.zero, index: index);

  Future<void> resume(int index, Duration position) => audioPlayer.seek(position, index: index);

  @override
  Future<void> skipToNext() => audioPlayer.seekToNext();

  @override
  Future<void> skipToPrevious() => audioPlayer.seekToPrevious();

  void attachMediaLibrary(MediaLibrary mediaLibrary) {
    if (!_mediaLibrary.isCompleted) {
      _mediaLibrary.complete(mediaLibrary);
      mediaLibrary.rootChanged.listen(_rootChanged.add);
    }
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    return (await _mediaLibrary.future).getChildren(parentMediaId);
  }

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    if (parentMediaId == AudioService.browsableRootId) {
      // Root categories depend on whether we are in offline mode.
      return _rootChanged;
    }
    return super.subscribeToChildren(parentMediaId);
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    return (await _mediaLibrary.future).search(query);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    return (await _mediaLibrary.future).playFromMediaId(mediaId);
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    return (await _mediaLibrary.future).playFromSearch(query);
  }
}
