/// Default network resource URLs, presets, and formatting utilities for the
/// `xue_hua_navite_cache_manager` example workbench.
library;

/// Android API 24 trusts this host. `flutter.github.io` fails there with
/// `CertPathValidatorException: Trust anchor for certification path not found`.
const String kDefaultFetchUrl = 'https://httpbin.org/image/jpeg';

/// Preset network resources used in the Download & Fetch tab.
///
/// Chip label "Owl Image (JPG)" is tapped by `example/test_driver/app_test.dart`.
const List<Map<String, String>> kSampleUrls = <Map<String, String>>[
  <String, String>{
    'label': 'Owl Image (JPG)',
    'url': kDefaultFetchUrl,
    'tag': 'images',
  },
  <String, String>{
    'label': 'Gallery Image 1 (JPG)',
    'url': 'https://www.gstatic.com/webp/gallery/1.jpg',
    'tag': 'images',
  },
  <String, String>{
    'label': 'Gallery Image 2 (JPG)',
    'url': 'https://www.gstatic.com/webp/gallery/2.jpg',
    'tag': 'images',
  },
  <String, String>{
    'label': 'Sample Video (MP4)',
    'url': 'https://filesamples.com/samples/video/mp4/sample_640x360.mp4',
    'tag': 'videos',
  },
];

/// 100 verified public photo IDs from Picsum Photos providing real, distinct
/// full-color photographic imagery (nature, landscapes, architecture, animals).
const List<int> _kGalleryPicsumIds = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
  33,
  34,
  35,
  36,
  37,
  38,
  39,
  40,
  41,
  42,
  43,
  44,
  45,
  46,
  47,
  48,
  49,
  50,
  51,
  52,
  53,
  54,
  55,
  56,
  57,
  58,
  59,
  60,
  61,
  62,
  63,
  64,
  65,
  66,
  67,
  68,
  69,
  70,
  71,
  72,
  73,
  74,
  75,
  76,
  77,
  78,
  79,
  80,
  81,
  82,
  83,
  84,
  85,
  87,
  88,
  89,
  90,
  91,
  92,
  93,
  94,
  95,
  96,
  98,
  99,
  100,
  101,
];

/// 104 HTTPS images (4 gstatic JPEGs + 100 Picsum photo JPEGs) for
/// concurrency, scrolling, and cross-restart persistence testing.
final List<Map<String, String>> kPublicGalleryImages = <Map<String, String>>[
  <String, String>{
    'title': '#1 gstatic gallery/1.jpg',
    'url': 'https://www.gstatic.com/webp/gallery/1.jpg',
  },
  <String, String>{
    'title': '#2 gstatic gallery/2.jpg (pinned)',
    'url': 'https://www.gstatic.com/webp/gallery/2.jpg',
  },
  <String, String>{
    'title': '#3 gstatic gallery/3.jpg (circle avatar)',
    'url': 'https://www.gstatic.com/webp/gallery/3.jpg',
  },
  <String, String>{
    'title': '#4 gstatic gallery/4.jpg',
    'url': 'https://www.gstatic.com/webp/gallery/4.jpg',
  },
  for (int i = 0; i < _kGalleryPicsumIds.length; i++)
    <String, String>{
      'title': 'Public Photo #${i + 5} (Picsum ID ${_kGalleryPicsumIds[i]})',
      'url': 'https://picsum.photos/id/${_kGalleryPicsumIds[i]}/400/280.jpg',
    },
];

/// Simulated broken URL card entry used to verify `CachedNetworkImage.errorBuilder`.
const Map<String, String> kBrokenGalleryCardItem = <String, String>{
  'title': 'Simulated Broken URL (Error Widget Test)',
  'url': 'https://invalid.xuehua.local/non_existent_image.png',
};

/// Formats a byte count into a human-readable string (`B`, `KB`, `MB`).
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}
