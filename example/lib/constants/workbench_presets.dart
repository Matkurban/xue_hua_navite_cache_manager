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

/// 104 HTTPS images (4 gstatic JPEGs + 100 placehold.co JPEGs) for
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
  for (int i = 1; i <= 100; i++)
    <String, String>{
      'title':
          'Public Photo #${i + 4} (placehold ${400 + (i % 20)}x${280 + i})',
      'url': 'https://placehold.co/${400 + (i % 20)}x${280 + i}.jpg',
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
