import 'package:material_ui/material_ui.dart';

import '../../xue_hua_navite_cache_manager.dart';

/// Signature for building a custom widget once the [ImageProvider] has resolved.
typedef CachedImageWidgetBuilder = Widget Function(
  BuildContext context,
  ImageProvider imageProvider,
);

/// Signature for building a static placeholder widget while the image is loading.
typedef CachedPlaceholderWidgetBuilder = Widget Function(
  BuildContext context,
  String url,
);

/// Signature for building a real-time download progress indicator widget.
typedef CachedProgressIndicatorBuilder = Widget Function(
  BuildContext context,
  String url,
  ImageChunkEvent? progress,
);

/// Signature for building a fallback widget when image loading or decoding fails.
typedef CachedLoadingErrorWidgetBuilder = Widget Function(
  BuildContext context,
  String url,
  Object error,
  StackTrace? stackTrace,
);

/// A high-performance widget that downloads, caches, and displays network images
/// using [XueHuaNaviteCacheManager] and [CachedNetworkImageProvider].
///
/// Designed for zero-jank 60/120 FPS scrolling in large lists and grids:
/// - Automatically short-circuits fade animations when an image is served synchronously
///   from Flutter's in-memory `ImageCache` (`wasSynchronouslyLoaded`).
/// - Supports C++ engine downsampling via [memCacheWidth] and [memCacheHeight] so
///   high-resolution images do not spike GPU memory or drop frames during rasterization.
/// - Supports HTTP 304 conditional revalidation, category [tag] grouping, [pinned] protection,
///   and MD5/SHA-256 [checksumAlgorithm] verification.
class CachedNetworkImage extends StatelessWidget {
  /// Creates a [CachedNetworkImage] widget.
  const CachedNetworkImage({
    super.key,
    required this.imageUrl,
    this.cacheKey,
    this.tag,
    this.httpHeaders = const <String, String>{},
    this.ttlSeconds,
    this.forceRefresh = false,
    this.fallbackToCacheOnError = true,
    this.pinned = false,
    this.checksumAlgorithm = CacheChecksumAlgorithm.none,
    this.expectedChecksum,
    this.cacheManager,
    this.imageBuilder,
    this.placeholder,
    this.progressIndicatorBuilder,
    this.errorWidget,
    this.fadeInDuration = const Duration(milliseconds: 250),
    this.fadeInCurve = Curves.easeOut,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.matchTextDirection = false,
    this.color,
    this.colorBlendMode,
    this.filterQuality = FilterQuality.medium,
    this.memCacheWidth,
    this.memCacheHeight,
    this.scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.gaplessPlayback = true,
    this.errorListener,
  });

  /// Remote HTTP or HTTPS URL of the image to display and cache.
  final String imageUrl;

  /// Optional custom cache key override.
  final String? cacheKey;

  /// Optional logical category tag (e.g. `'avatars'`, `'feed_images'`) for `removeByTag`.
  final String? tag;

  /// Optional custom HTTP headers sent when downloading the image.
  final Map<String, String> httpHeaders;

  /// Optional TTL override in seconds for this image.
  final int? ttlSeconds;

  /// When `true`, forces a conditional HTTP revalidation or full re-download.
  final bool forceRefresh;

  /// When `true` (default), serves an expired cached image if the network fails.
  final bool fallbackToCacheOnError;

  /// When `true`, pins the image in cache so quota eviction skips it.
  final bool pinned;

  /// Optional checksum algorithm to verify the downloaded image.
  final CacheChecksumAlgorithm checksumAlgorithm;

  /// Expected hex digest when [checksumAlgorithm] is enabled.
  final String? expectedChecksum;

  /// Optional custom [XueHuaNaviteCacheManager] instance.
  final XueHuaNaviteCacheManager? cacheManager;

  /// Optional builder to customize the rendered widget using the resolved [ImageProvider]
  /// (for example, wrapping in a `CircleAvatar` or `Container` with `DecorationImage`).
  final CachedImageWidgetBuilder? imageBuilder;

  /// Widget displayed while the image is loading. Mutually exclusive with [progressIndicatorBuilder].
  final CachedPlaceholderWidgetBuilder? placeholder;

  /// Widget displayed with live byte download progress while the image is loading.
  final CachedProgressIndicatorBuilder? progressIndicatorBuilder;

  /// Widget displayed if downloading or decoding the image fails.
  final CachedLoadingErrorWidgetBuilder? errorWidget;

  /// Duration of the fade-in transition when an image finishes loading asynchronously.
  /// Ignored when the image hits Flutter's synchronous memory `ImageCache` so scrolling never flickers.
  final Duration fadeInDuration;

  /// Curve of the fade-in transition.
  final Curve fadeInCurve;

  /// Target display width of the widget.
  final double? width;

  /// Target display height of the widget.
  final double? height;

  /// How the image should be inscribed into the space allocated during layout.
  final BoxFit? fit;

  /// How to align the image within its bounds.
  final AlignmentGeometry alignment;

  /// How to paint any portions of the layout bounds not covered by the image.
  final ImageRepeat repeat;

  /// Whether to paint the image in the direction of the [TextDirection].
  final bool matchTextDirection;

  /// Optional color to blend with the image.
  final Color? color;

  /// Blend mode used to apply [color].
  final BlendMode? colorBlendMode;

  /// Sampling quality used when scaling the image.
  final FilterQuality filterQuality;

  /// Target decode width in pixels inside the C++ image codec.
  /// Setting this on high-resolution images drastically reduces memory footprint and prevents UI jank.
  final int? memCacheWidth;

  /// Target decode height in pixels inside the C++ image codec.
  final int? memCacheHeight;

  /// Image scale factor.
  final double scale;

  /// Accessibility label for the image.
  final String? semanticLabel;

  /// Whether to exclude this image from semantics.
  final bool excludeFromSemantics;

  /// Whether to continue showing the old image when the image provider changes.
  final bool gaplessPlayback;

  /// Optional callback invoked when an error occurs during loading.
  final void Function(Object error)? errorListener;

  /// Creates the underlying [CachedNetworkImageProvider] configured for this widget.
  CachedNetworkImageProvider get imageProvider => CachedNetworkImageProvider(
    imageUrl,
    scale: scale,
    cacheKey: cacheKey,
    tag: tag,
    headers: httpHeaders,
    ttlSeconds: ttlSeconds,
    forceRefresh: forceRefresh,
    fallbackToCacheOnError: fallbackToCacheOnError,
    pinned: pinned,
    checksumAlgorithm: checksumAlgorithm,
    expectedChecksum: expectedChecksum,
    maxWidth: memCacheWidth,
    maxHeight: memCacheHeight,
    cacheManager: cacheManager,
    errorListener: errorListener,
  );

  @override
  Widget build(BuildContext context) {
    final provider = imageProvider;

    return Image(
      image: provider,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      matchTextDirection: matchTextDirection,
      color: color,
      colorBlendMode: colorBlendMode,
      filterQuality: filterQuality,
      semanticLabel: semanticLabel,
      excludeFromSemantics: excludeFromSemantics,
      gaplessPlayback: gaplessPlayback,
      frameBuilder:
          (
            BuildContext context,
            Widget child,
            int? frame,
            bool wasSynchronouslyLoaded,
          ) {
            final Widget resolvedChild = imageBuilder != null
                ? imageBuilder!(context, provider)
                : child;

            // If loaded synchronously from Flutter's ImageCache, render immediately with zero animation overhead.
            if (wasSynchronouslyLoaded) {
              return resolvedChild;
            }

            if (frame == null) {
              if (placeholder != null) {
                return SizedBox(
                  width: width,
                  height: height,
                  child: placeholder!(context, imageUrl),
                );
              }
              if (progressIndicatorBuilder != null) {
                return SizedBox(
                  width: width,
                  height: height,
                  child: progressIndicatorBuilder!(context, imageUrl, null),
                );
              }
              return SizedBox(width: width, height: height);
            }

            if (fadeInDuration == Duration.zero) {
              return resolvedChild;
            }

            return TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.0, end: 1.0),
              duration: fadeInDuration,
              curve: fadeInCurve,
              builder:
                  (BuildContext context, double opacity, Widget? animChild) {
                    return Opacity(opacity: opacity, child: animChild);
                  },
              child: resolvedChild,
            );
          },
      loadingBuilder: progressIndicatorBuilder != null
          ? (
              BuildContext context,
              Widget child,
              ImageChunkEvent? loadingProgress,
            ) {
              if (loadingProgress == null) {
                return child;
              }
              return SizedBox(
                width: width,
                height: height,
                child: progressIndicatorBuilder!(
                  context,
                  imageUrl,
                  loadingProgress,
                ),
              );
            }
          : null,
      errorBuilder:
          (BuildContext context, Object error, StackTrace? stackTrace) {
            if (errorWidget != null) {
              return SizedBox(
                width: width,
                height: height,
                child: errorWidget!(context, imageUrl, error, stackTrace),
              );
            }
            return SizedBox(
              width: width,
              height: height,
              child: const Center(
                child: Icon(Icons.broken_image_outlined, color: Colors.grey),
              ),
            );
          },
    );
  }
}
