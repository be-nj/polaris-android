import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:polaris/core/cache/media.dart';
import 'package:polaris/core/client/api/v8_client.dart' show artistImagePath;
import 'package:polaris/core/client/app_client.dart';
import 'package:polaris/core/connection.dart' as connection;
import 'package:polaris/ui/utils/fallback_artwork.dart';

final getIt = GetIt.instance;

class Thumbnail extends StatefulWidget {
  final String? path;
  final ArtworkSize size;

  /// What to show when there is no image
  final Widget fallback;

  /// Called when the image could not be obtained
  final void Function()? onMissing;

  const Thumbnail(this.path, this.size, {this.fallback = const FallbackArtwork(), this.onMissing, Key? key})
      : super(key: key);

  @override
  State<Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<Thumbnail> {
  Future<Uint8List?>? futureImage;

  @override
  void initState() {
    super.initState();
    _fetchImage();
  }

  @override
  void didUpdateWidget(Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      setState(() {
        _fetchImage();
      });
    }
  }

  void _fetchImage() {
    String? path = widget.path;
    if (path != null) {
      final onMissing = widget.onMissing;
      futureImage = getIt<AppClient>().getImage(path, widget.size).then((image) {
        if (image == null) {
          onMissing?.call();
        }
        return image;
      });
    } else {
      futureImage = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: futureImage,
      builder: (context, snapshot) {
        switch (snapshot.connectionState) {
          case ConnectionState.none:
            return widget.fallback;
          case ConnectionState.waiting:
          case ConnectionState.active:
            return Container();
          case ConnectionState.done:
            if (!snapshot.hasData || snapshot.data == null) {
              return widget.fallback;
            }
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
            );
        }
      },
    );
  }
}

class LargeThumbnail extends StatelessWidget {
  final String? path;

  const LargeThumbnail(this.path, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8.0),
      child: AspectRatio(
        aspectRatio: 1.0,
        child: Thumbnail(path, ArtworkSize.small),
      ),
    );
  }
}

class ListThumbnail extends StatelessWidget {
  final String? path;

  const ListThumbnail(this.path, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4.0),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Thumbnail(path, ArtworkSize.tiny),
      ),
    );
  }
}

/// Round picture of an artist. Artists without a picture are shown as an icon.
///
/// [path] is the picture the collection has of the artist. Artists without one are looked
/// up by [artistName] on servers which find pictures online (be-nj/polaris, API version 8.4).
class ArtistThumbnail extends StatelessWidget {
  final String? path;
  final String? artistName;
  final double size;

  // Artists the server found no picture of, by server. Lists rebuild their rows as they
  // scroll, which would otherwise ask again and again for pictures which do not exist.
  static final Map<String, Set<String>> _artistsWithoutPicture = {};

  const ArtistThumbnail(this.path, {this.artistName, this.size = 36, Key? key}) : super(key: key);

  /// Whether the server can have pictures of artists whose [ArtistHeader.artwork] is empty
  static bool serverFindsPictures() {
    final connectionManager = getIt<connection.Manager>();
    return connectionManager.apiVersion == 8 && (connectionManager.apiMinorVersion ?? 0) >= 4;
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: Theme.of(context).textTheme.labelSmall?.color?.withValues(alpha: 0.1),
      alignment: Alignment.center,
      child: Icon(Icons.person, size: size * 2 / 3),
    );

    String? picturePath = path;
    void Function()? onMissing;
    final name = artistName;
    if (picturePath == null && name != null && serverFindsPictures()) {
      final connectionManager = getIt<connection.Manager>();
      final withoutPicture = _artistsWithoutPicture.putIfAbsent(connectionManager.url ?? '', () => {});
      if (!withoutPicture.contains(name)) {
        picturePath = artistImagePath(name);
        onMissing = () {
          // Pictures also fail to load when the server cannot be reached
          if (connectionManager.isConnected()) {
            withoutPicture.add(name);
          }
        };
      }
    }

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        // Tiny thumbnails (40 pixels) are smaller than this widget on most screens
        child: Thumbnail(picturePath, ArtworkSize.small, fallback: placeholder, onMissing: onMissing),
      ),
    );
  }
}
