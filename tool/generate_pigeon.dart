// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:pigeon/pigeon.dart';

const String _inputPath = 'pigeons/cache_messages.dart';
const String _ffigenConfigPath =
    'tool/pigeon/cache_messages_ffigen_config.dart';
const String _darwinObjcGenAssetId =
    'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_objc_gen.dylib';
const String _iosObjcGenDir =
    'ios/xue_hua_navite_cache_manager/Sources/xue_hua_navite_cache_manager_objc_gen';
const String _macosObjcGenDir =
    'macos/xue_hua_navite_cache_manager/Sources/xue_hua_navite_cache_manager_objc_gen';

Future<void> main(List<String> args) async {
  final bool verifyDiff = args.contains('--verify-darwin-ffi-diff');

  stdout.writeln(
    '[pigeon] Running Pass 1 (Dart, iOS FFI, Android JNI, Windows C++, Linux GObject)...',
  );
  final int pass1Exit = await Pigeon.runWithOptions(
    const PigeonOptions(input: _inputPath),
  );
  _cleanupObjectFiles(_iosObjcGenDir);
  if (pass1Exit != 0) {
    exitCode = pass1Exit;
    return;
  }

  if (Platform.isMacOS) {
    stdout.writeln(
      '[pigeon] Injecting native assetId into $_ffigenConfigPath and regenerating FFI bindings...',
    );
    _injectAssetIdIntoFfigenConfig(_ffigenConfigPath, _darwinObjcGenAssetId);
    final ProcessResult ffigenResult = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', _ffigenConfigPath],
    );
    if (ffigenResult.stdout.toString().isNotEmpty) {
      stdout.write(ffigenResult.stdout);
    }
    if (ffigenResult.stderr.toString().isNotEmpty) {
      stderr.write(ffigenResult.stderr);
    }
    _cleanupObjectFiles(_iosObjcGenDir);
    if (ffigenResult.exitCode != 0) {
      exitCode = ffigenResult.exitCode;
      return;
    }

    stdout.writeln(
      '[pigeon] Running Pass 2 (independent macOS Swift FFI + _objc_gen)...',
    );
    final String? macosSdkPath = _resolveMacosSdkPath();
    final String macosTriple = _resolveMacosTriple();

    const String tempDartDir = '.dart_tool/pigeon_macos';
    const String tempConfigDir = '.dart_tool/pigeon_macos_cfg';
    try {
      final int pass2Exit = await Pigeon.runWithOptions(
        PigeonOptions(
          input: _inputPath,
          appDirectory: 'example',
          configDirectory: tempConfigDir,
          dartOut: '$tempDartDir/cache_messages.g.dart',
          dartOptions: const DartOptions(),
          swiftOut: 'macos/xue_hua_navite_cache_manager/Sources/xue_hua_navite_cache_manager/CacheMessages.g.swift',
          swiftOptions: SwiftOptions(
            useFfi: true,
            ffiModuleName: 'xue_hua_navite_cache_manager',
            appleSdkPath: macosSdkPath,
            appleSdkTriple: macosTriple,
          ),
        ),
        mergeDefinitionFileOptions: false,
      );
      _cleanupObjectFiles(_macosObjcGenDir);
      if (pass2Exit != 0) {
        exitCode = pass2Exit;
        return;
      }

      if (verifyDiff) {
        final File iosFfi = File('lib/src/pigeon/cache_messages.g.ffi.dart');
        final File macosFfi = File('$tempDartDir/cache_messages.g.ffi.dart');
        if (iosFfi.existsSync() && macosFfi.existsSync()) {
          final String iosContent = iosFfi.readAsStringSync();
          final RegExp defaultAssetPattern = RegExp(
            "@ffi\\.DefaultAsset\\(\\s*'${RegExp.escape(_darwinObjcGenAssetId)}',?\\s*\\)\\r?\\nlibrary;\\r?\\n\\r?\\n",
          );
          final bool hasDefaultAsset = defaultAssetPattern.hasMatch(iosContent);
          final String iosWithoutDefaultAsset = iosContent.replaceFirst(
            defaultAssetPattern,
            '',
          );
          final bool identicalFfi =
              iosWithoutDefaultAsset == macosFfi.readAsStringSync();
          final bool identicalObjcM =
              File('$_iosObjcGenDir/CacheMessages.g.m').readAsStringSync() ==
              File('$_macosObjcGenDir/CacheMessages.g.m').readAsStringSync();
          stdout.writeln(
            '[pigeon] iOS .g.ffi.dart has @ffi.DefaultAsset: $hasDefaultAsset',
          );
          stdout.writeln(
            '[pigeon] iOS vs macOS .g.ffi.dart body identical: $identicalFfi',
          );
          stdout.writeln(
            '[pigeon] iOS vs macOS CacheMessages.g.m identical: $identicalObjcM',
          );
          if (!hasDefaultAsset || !identicalFfi || !identicalObjcM) {
            exitCode = 1;
            return;
          }
        }
      }
    } finally {
      _deleteDirectoryIfExists(tempDartDir);
      _deleteDirectoryIfExists(tempConfigDir);
    }
  } else {
    stdout.writeln('[pigeon] Skipping Pass 2 (macOS FFI) on non-macOS host.');
  }

  stdout.writeln('[pigeon] Code generation complete.');
}

void _injectAssetIdIntoFfigenConfig(String configPath, String assetId) {
  final File file = File(configPath);
  final String content = file.readAsStringSync();
  if (content.contains("assetId: '$assetId'")) {
    return;
  }
  final RegExp modulePattern = RegExp(
    r"([ \t]*)module: 'xue_hua_navite_cache_manager',\r?\n",
  );
  final Match? match = modulePattern.firstMatch(content);
  if (match == null) {
    throw StateError(
      'Unable to locate Output(module: ...) anchor in $configPath',
    );
  }
  final String indent = match.group(1)!;
  final String updated = content.replaceFirst(
    modulePattern,
    "${match.group(0)}${indent}assetId: '$assetId',\n",
  );
  file.writeAsStringSync(updated);
}

String? _resolveMacosSdkPath() {
  final ProcessResult result = Process.runSync('xcrun', <String>[
    '--sdk',
    'macosx',
    '--show-sdk-path',
  ]);
  if (result.exitCode != 0) {
    return null;
  }
  final String output = result.stdout.toString().trim();
  return output.isEmpty ? null : output;
}

String _resolveMacosTriple() {
  final ProcessResult result = Process.runSync('uname', <String>['-m']);
  final String arch = result.stdout.toString().trim();
  if (arch == 'x86_64') {
    return 'x86_64-apple-macosx12.0';
  }
  return 'arm64-apple-macosx12.0';
}

void _cleanupObjectFiles(String dirPath) {
  final Directory dir = Directory(dirPath);
  if (!dir.existsSync()) {
    return;
  }
  for (final FileSystemEntity entity in dir.listSync()) {
    if (entity is File && entity.path.endsWith('.o')) {
      entity.deleteSync();
    }
  }
}

void _deleteDirectoryIfExists(String dirPath) {
  final Directory dir = Directory(dirPath);
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
}
