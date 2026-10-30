import 'dart:typed_data';
import 'dart:ui' as ui;

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
/// - Supports hardware-accelerated rounded corners via [borderRadius] using direct
///   `ui.ImageShader` + `Canvas.drawRRect` rendering without heavyweight `ClipRRect`
///   compositing layers or `saveLayer` offscreen buffers.
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
    this.errorBuilder,
    this.fadeInDuration = const Duration(milliseconds: 250),
    this.fadeInCurve = Curves.easeOut,
    this.width,
    this.height,
    this.borderRadius,
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

  /// Builder displayed if downloading or decoding the image fails.
  final CachedLoadingErrorWidgetBuilder? errorBuilder;

  /// Duration of the fade-in transition when an image finishes loading asynchronously.
  /// Ignored when the image hits Flutter's synchronous memory `ImageCache` so scrolling never flickers.
  final Duration fadeInDuration;

  /// Curve of the fade-in transition.
  final Curve fadeInCurve;

  /// Target display width of the widget.
  final double? width;

  /// Target display height of the widget.
  final double? height;

  /// Optional corner radius painted directly on the canvas without `ClipRRect` layer overhead.
  final BorderRadiusGeometry? borderRadius;

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

  static RawImage? _extractRawImage(Widget widget) {
    if (widget is RawImage) {
      return widget;
    }
    if (widget is Semantics && widget.child is RawImage) {
      return widget.child! as RawImage;
    }
    return null;
  }

  Widget _wrapWithSemanticsIfNeeded(Widget child) {
    if (excludeFromSemantics) {
      return child;
    }
    return Semantics(
      container: semanticLabel != null,
      image: true,
      label: semanticLabel ?? '',
      child: child,
    );
  }

  Widget _wrapImageBuilderResult(Widget built, RawImage? rawImage) {
    final ui.Image? decoded = rawImage?.image;
    final double imgScale = (rawImage?.scale != null && rawImage!.scale > 0)
        ? rawImage.scale
        : (scale > 0 ? scale : 1.0);
    final double? naturalWidth = decoded != null && decoded.width > 0
        ? decoded.width / imgScale
        : null;
    final double? naturalHeight = decoded != null && decoded.height > 0
        ? decoded.height / imgScale
        : null;

    bool hasOwnBoundedWidth = false;
    bool hasOwnBoundedHeight = false;
    if (built is Container && built.constraints != null) {
      hasOwnBoundedWidth = built.constraints!.hasBoundedWidth;
      hasOwnBoundedHeight = built.constraints!.hasBoundedHeight;
    } else if (built is SizedBox) {
      hasOwnBoundedWidth = built.width != null;
      hasOwnBoundedHeight = built.height != null;
    } else if (built is ConstrainedBox) {
      hasOwnBoundedWidth = built.constraints.hasBoundedWidth;
      hasOwnBoundedHeight = built.constraints.hasBoundedHeight;
    }

    Widget result = built;
    if (width != null || height != null) {
      result = SizedBox(width: width, height: height, child: result);
    }

    // Prevent childless Container(decoration: BoxDecoration(image: DecorationImage(...)))
    // from collapsing to 0x0 via Container's internal LimitedBox(0, 0) when placed
    // inside a Column, Row, ListView, or other parent with unbounded constraints.
    if (width == null || height == null) {
      final double aspectRatio =
          (naturalWidth != null && naturalHeight != null && naturalHeight > 0)
          ? naturalWidth / naturalHeight
          : 1.0;
      final double fallbackWidth =
          width ??
          (hasOwnBoundedWidth
              ? double.infinity
              : (height != null
                    ? height! * aspectRatio
                    : (naturalWidth ?? 100.0)));
      final double fallbackHeight =
          height ??
          (hasOwnBoundedHeight
              ? double.infinity
              : (width != null
                    ? width! / aspectRatio
                    : (naturalHeight ?? 100.0)));

      result = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: hasOwnBoundedWidth ? 0.0 : fallbackWidth,
          maxWidth: fallbackWidth,
          minHeight: hasOwnBoundedHeight ? 0.0 : fallbackHeight,
          maxHeight: fallbackHeight,
        ),
        child: result,
      );
    }

    return result;
  }

  Widget _buildRoundedRawImage(
    BuildContext context,
    RawImage rawImage, {
    required double opacity,
  }) {
    final Widget rounded = _RoundedRawImage(
      image: rawImage.image,
      width: width,
      height: height,
      scale: rawImage.scale,
      borderRadius: borderRadius!,
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      matchTextDirection: matchTextDirection,
      textDirection: Directionality.maybeOf(context),
      color: color,
      colorBlendMode: colorBlendMode,
      filterQuality: filterQuality,
      opacity: opacity,
    );
    return _wrapWithSemanticsIfNeeded(rounded);
  }

  @override
  Widget build(BuildContext context) {
    final CachedNetworkImageProvider provider = imageProvider;
    final bool hasRoundedCorners =
        borderRadius != null && borderRadius != BorderRadius.zero;
    bool hasFrameLoaded = false;

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
            hasFrameLoaded = frame != null;

            if (frame == null && !wasSynchronouslyLoaded) {
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

            final RawImage? rawImage = _extractRawImage(child);

            // Fast-path for rounded corners without custom imageBuilder:
            // render directly via _RoundedRawImage (ui.ImageShader + Canvas.drawRRect)
            // without ClipRRect or Opacity layers.
            if (imageBuilder == null &&
                hasRoundedCorners &&
                rawImage?.image != null) {
              if (wasSynchronouslyLoaded || fadeInDuration == Duration.zero) {
                return _buildRoundedRawImage(context, rawImage!, opacity: 1.0);
              }
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.0, end: 1.0),
                duration: fadeInDuration,
                curve: fadeInCurve,
                builder: (BuildContext context, double opacity, Widget? _) {
                  return _buildRoundedRawImage(
                    context,
                    rawImage!,
                    opacity: opacity,
                  );
                },
              );
            }

            final Widget resolvedChild = imageBuilder != null
                ? _wrapImageBuilderResult(
                    imageBuilder!(context, provider),
                    rawImage,
                  )
                : child;

            // If loaded synchronously from Flutter's ImageCache, render immediately with zero animation overhead.
            if (wasSynchronouslyLoaded || fadeInDuration == Duration.zero) {
              return resolvedChild;
            }

            // Start fade at 0.01 (alpha = 3/255) rather than 0.0 so RenderOpacity
            // does not short-circuit painting on frame 0, ensuring DecorationImage
            // inside imageBuilder resolves and paints immediately on its first frame.
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.01, end: 1.0),
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
              if (loadingProgress == null || hasFrameLoaded) {
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
            if (errorBuilder != null) {
              return SizedBox(
                width: width,
                height: height,
                child: errorBuilder!(context, imageUrl, error, stackTrace),
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

/// A lightweight leaf [RenderObjectWidget] that paints a decoded [ui.Image] with
/// rounded corners directly on the [Canvas] without creating a `ClipRRectLayer`
/// or triggering `saveLayer` offscreen rendering.
class _RoundedRawImage extends LeafRenderObjectWidget {
  const _RoundedRawImage({
    required this.image,
    required this.width,
    required this.height,
    required this.scale,
    required this.borderRadius,
    required this.fit,
    required this.alignment,
    required this.repeat,
    required this.matchTextDirection,
    required this.textDirection,
    required this.color,
    required this.colorBlendMode,
    required this.filterQuality,
    required this.opacity,
  });

  final ui.Image? image;
  final double? width;
  final double? height;
  final double scale;
  final BorderRadiusGeometry borderRadius;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageRepeat repeat;
  final bool matchTextDirection;
  final TextDirection? textDirection;
  final Color? color;
  final BlendMode? colorBlendMode;
  final FilterQuality filterQuality;
  final double opacity;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderRoundedImage(
      image,
      width,
      height,
      scale,
      borderRadius,
      fit,
      alignment,
      repeat,
      matchTextDirection,
      textDirection,
      color,
      colorBlendMode,
      filterQuality,
      opacity,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderRoundedImage renderObject,
  ) {
    renderObject
      ..image = image
      ..width = width
      ..height = height
      ..scale = scale
      ..borderRadius = borderRadius
      ..fit = fit
      ..alignment = alignment
      ..repeat = repeat
      ..matchTextDirection = matchTextDirection
      ..textDirection = textDirection
      ..color = color
      ..colorBlendMode = colorBlendMode
      ..filterQuality = filterQuality
      ..opacity = opacity;
  }
}

class _RenderRoundedImage extends RenderBox {
  _RenderRoundedImage(
    this._image,
    this._width,
    this._height,
    this._scale,
    this._borderRadius,
    this._fit,
    this._alignment,
    this._repeat,
    this._matchTextDirection,
    this._textDirection,
    this._color,
    this._colorBlendMode,
    this._filterQuality,
    this._opacity,
  );

  ui.Image? _image;
  set image(ui.Image? value) {
    if (identical(value, _image)) return;
    final bool sizeChanged =
        value?.width != _image?.width || value?.height != _image?.height;
    _image = value;
    _invalidateShader();
    if (sizeChanged && (_width == null || _height == null)) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  double? _width;
  set width(double? value) {
    if (value == _width) return;
    _width = value;
    _invalidateShader();
    markNeedsLayout();
  }

  double? _height;
  set height(double? value) {
    if (value == _height) return;
    _height = value;
    _invalidateShader();
    markNeedsLayout();
  }

  double _scale;
  set scale(double value) {
    if (value == _scale) return;
    _scale = value;
    _invalidateShader();
    markNeedsLayout();
  }

  BorderRadiusGeometry _borderRadius;
  set borderRadius(BorderRadiusGeometry value) {
    if (value == _borderRadius) return;
    _borderRadius = value;
    markNeedsPaint();
  }

  BoxFit? _fit;
  set fit(BoxFit? value) {
    if (value == _fit) return;
    _fit = value;
    _invalidateShader();
    markNeedsPaint();
  }

  AlignmentGeometry _alignment;
  set alignment(AlignmentGeometry value) {
    if (value == _alignment) return;
    _alignment = value;
    _invalidateShader();
    markNeedsPaint();
  }

  ImageRepeat _repeat;
  set repeat(ImageRepeat value) {
    if (value == _repeat) return;
    _repeat = value;
    _invalidateShader();
    markNeedsPaint();
  }

  bool _matchTextDirection;
  set matchTextDirection(bool value) {
    if (value == _matchTextDirection) return;
    _matchTextDirection = value;
    _invalidateShader();
    markNeedsPaint();
  }

  TextDirection? _textDirection;
  set textDirection(TextDirection? value) {
    if (value == _textDirection) return;
    _textDirection = value;
    _invalidateShader();
    markNeedsPaint();
  }

  Color? _color;
  set color(Color? value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  BlendMode? _colorBlendMode;
  set colorBlendMode(BlendMode? value) {
    if (value == _colorBlendMode) return;
    _colorBlendMode = value;
    markNeedsPaint();
  }

  FilterQuality _filterQuality;
  set filterQuality(FilterQuality value) {
    if (value == _filterQuality) return;
    _filterQuality = value;
    markNeedsPaint();
  }

  double _opacity;
  set opacity(double value) {
    if (value == _opacity) return;
    _opacity = value;
    markNeedsPaint();
  }

  ui.ImageShader? _cachedShader;
  Rect? _cachedShaderRect;

  void _invalidateShader() {
    _cachedShader?.dispose();
    _cachedShader = null;
    _cachedShaderRect = null;
  }

  @override
  void dispose() {
    _invalidateShader();
    super.dispose();
  }

  Size _sizeForConstraints(BoxConstraints constraints) {
    constraints = BoxConstraints.tightFor(
      width: _width,
      height: _height,
    ).enforce(constraints);

    if (_image == null) {
      return constraints.smallest;
    }

    return constraints.constrainSizeAndAttemptToPreserveAspectRatio(
      Size(
        _image!.width.toDouble() / _scale,
        _image!.height.toDouble() / _scale,
      ),
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    assert(height >= 0.0);
    if (_width == null && _height == null) {
      return 0.0;
    }
    return _sizeForConstraints(BoxConstraints.tightForFinite(height: height))
        .width;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    assert(height >= 0.0);
    return _sizeForConstraints(BoxConstraints.tightForFinite(height: height))
        .width;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    assert(width >= 0.0);
    if (_width == null && _height == null) {
      return 0.0;
    }
    return _sizeForConstraints(BoxConstraints.tightForFinite(width: width))
        .height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    assert(width >= 0.0);
    return _sizeForConstraints(BoxConstraints.tightForFinite(width: width))
        .height;
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    return _sizeForConstraints(constraints);
  }

  @override
  void performLayout() {
    size = _sizeForConstraints(constraints);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final ui.Image? img = _image;
    if (img == null || size.isEmpty || _opacity <= 0.0) {
      return;
    }

    final Rect rect = offset & size;
    final TextDirection resolvedDirection = _textDirection ?? TextDirection.ltr;
    final RRect rrect = _borderRadius.resolve(resolvedDirection).toRRect(rect);
    if (rrect.isEmpty) {
      return;
    }

    final Size inputSize = Size(img.width.toDouble(), img.height.toDouble());
    final BoxFit effectiveFit = _fit ?? BoxFit.scaleDown;
    final FittedSizes fittedSizes = applyBoxFit(
      effectiveFit,
      Size(inputSize.width / _scale, inputSize.height / _scale),
      rect.size,
    );
    final Size sourceSize = fittedSizes.source * _scale;
    final Size destinationSize = fittedSizes.destination;
    if (sourceSize.isEmpty || destinationSize.isEmpty) {
      return;
    }

    final Alignment resolvedAlignment = _alignment.resolve(resolvedDirection);
    final Rect destinationRect = resolvedAlignment.inscribe(
      destinationSize,
      rect,
    );
    final Rect sourceRect = resolvedAlignment.inscribe(
      sourceSize,
      Offset.zero & inputSize,
    );

    final bool coversFullBounds =
        _repeat == ImageRepeat.noRepeat &&
        destinationRect.left <= rect.left + 0.5 &&
        destinationRect.top <= rect.top + 0.5 &&
        destinationRect.right >= rect.right - 0.5 &&
        destinationRect.bottom >= rect.bottom - 0.5;

    if (coversFullBounds) {
      if (_cachedShader == null || _cachedShaderRect != rect) {
        _cachedShader?.dispose();
        final bool flipHorizontally =
            _matchTextDirection && resolvedDirection == TextDirection.rtl;
        final double scaleX = flipHorizontally
            ? -destinationRect.width / sourceRect.width
            : destinationRect.width / sourceRect.width;
        final double scaleY = destinationRect.height / sourceRect.height;
        final double translateX = flipHorizontally
            ? destinationRect.right - sourceRect.left * scaleX
            : destinationRect.left - sourceRect.left * scaleX;
        final double translateY = destinationRect.top - sourceRect.top * scaleY;

        final Float64List matrix4 = Float64List(16)
          ..[0] = scaleX
          ..[5] = scaleY
          ..[10] = 1.0
          ..[12] = translateX
          ..[13] = translateY
          ..[15] = 1.0;

        _cachedShader = ui.ImageShader(
          img,
          TileMode.clamp,
          TileMode.clamp,
          matrix4,
        );
        _cachedShaderRect = rect;
      }

      final Paint paint = Paint()
        ..isAntiAlias = true
        ..filterQuality = _filterQuality
        ..shader = _cachedShader;

      if (_opacity < 1.0) {
        paint.color = Color.fromRGBO(255, 255, 255, _opacity.clamp(0.0, 1.0));
      }
      if (_color != null) {
        paint.colorFilter = ColorFilter.mode(
          _color!,
          _colorBlendMode ?? BlendMode.srcIn,
        );
      }

      context.canvas.drawRRect(rrect, paint);
      return;
    }

    // Fallback for letterboxed fits (e.g. BoxFit.contain with empty bands) or
    // tiled ImageRepeat: clip on the canvas directly without pushing a ClipRRectLayer.
    final Canvas canvas = context.canvas;
    canvas.save();
    canvas.clipRRect(rrect, doAntiAlias: true);
    paintImage(
      canvas: canvas,
      rect: rect,
      image: img,
      scale: _scale,
      fit: _fit,
      alignment: resolvedAlignment,
      repeat: _repeat,
      flipHorizontally:
          _matchTextDirection && resolvedDirection == TextDirection.rtl,
      opacity: _opacity.clamp(0.0, 1.0),
      colorFilter: _color != null
          ? ColorFilter.mode(_color!, _colorBlendMode ?? BlendMode.srcIn)
          : null,
      filterQuality: _filterQuality,
      isAntiAlias: true,
    );
    canvas.restore();
  }
}
