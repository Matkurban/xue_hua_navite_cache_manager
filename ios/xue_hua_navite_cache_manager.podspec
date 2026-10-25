Pod::Spec.new do |s|
  s.name             = 'xue_hua_navite_cache_manager'
  s.version          = '1.0.0'
  s.summary          = 'Cross-platform native network file cache manager for Flutter.'
  s.description      = <<-DESC
Cross-platform native network file cache manager for Flutter with HTTP 304 revalidation, LRU/LFU/FIFO/TTL eviction, MD5/SHA-256 verification, and progress streaming.
                       DESC
  s.homepage         = 'https://github.com/Matkurban/xue_hua_navite_cache_manager'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Matkurban' => '3496354336@qq.com' }
  s.source           = { :path => '.' }
  s.source_files = 'xue_hua_navite_cache_manager/Sources/xue_hua_navite_cache_manager/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
