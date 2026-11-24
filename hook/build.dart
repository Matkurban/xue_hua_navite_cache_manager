import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const String _assetName = 'xue_hua_navite_cache_manager_objc_gen.dylib';

void main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final CodeConfig codeConfig = input.config.code;
    final OS os = codeConfig.targetOS;
    if (os != OS.iOS && os != OS.macOS) {
      return;
    }

    if (codeConfig.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError('LinkModePreference.static is not supported.');
    }

    final String platformDir = os == OS.iOS ? 'ios' : 'macos';
    final Uri objcGenDirUri = input.packageRoot.resolve(
      '$platformDir/xue_hua_navite_cache_manager/Sources/'
      'xue_hua_navite_cache_manager_objc_gen/',
    );
    final File mFile = File.fromUri(objcGenDirUri.resolve('CacheMessages.g.m'));
    final File hFile = File.fromUri(
      objcGenDirUri.resolve('xue_hua_navite_cache_manager.h'),
    );
    if (!mFile.existsSync()) {
      throw StateError('Missing generated Objective-C file: ${mFile.path}');
    }
    if (!hFile.existsSync()) {
      throw StateError('Missing generated Objective-C header: ${hFile.path}');
    }

    final String compiler = _findCompiler(codeConfig);
    final String sysroot = _sdkPath(codeConfig);
    final String target = _toTargetTriple(codeConfig);
    final String minVersionFlag = _minOSVersionFlag(codeConfig);

    final Directory objDir = Directory.fromUri(
      input.outputDirectory.resolve('obj/'),
    );
    objDir.createSync(recursive: true);
    final String objPath = objDir.uri.resolve('CacheMessages.g.o').toFilePath();
    final Uri assetPath = input.outputDirectory.resolve(_assetName);

    final List<String> commonFlags = <String>[
      '-isysroot',
      sysroot,
      '-target',
      target,
      minVersionFlag,
    ];

    await _runCompiler(compiler, <String>[
      ...commonFlags,
      '-x',
      'objective-c',
      '-fobjc-arc',
      '-fpic',
      '-gline-tables-only',
      '-I',
      objcGenDirUri.toFilePath(),
      '-c',
      mFile.path,
      '-o',
      objPath,
    ]);

    await _runCompiler(compiler, <String>[
      '-shared',
      if (os == OS.iOS) '-Wl,-encryptable',
      ...commonFlags,
      '-framework',
      'Foundation',
      '-lobjc',
      objPath,
      '-o',
      assetPath.toFilePath(),
    ]);

    output.dependencies.addAll(<Uri>[mFile.uri, hFile.uri]);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        file: assetPath,
        linkMode: DynamicLoadingBundled(),
      ),
    );
  });
}

String _findCompiler(CodeConfig codeConfig) {
  final String? configured = codeConfig.cCompiler?.compiler.toFilePath();
  if (configured != null && configured.isNotEmpty) {
    return configured;
  }
  final ProcessResult xcrunResult = Process.runSync('xcrun', <String>[
    '--find',
    'clang',
  ]);
  if (xcrunResult.exitCode == 0) {
    final String resolved = (xcrunResult.stdout as String).trim();
    if (resolved.isNotEmpty) {
      return resolved;
    }
  }
  return 'clang';
}

Future<void> _runCompiler(String compiler, List<String> args) async {
  final ProcessResult result = await Process.run(compiler, args);
  if (result.exitCode != 0) {
    throw ProcessException(
      compiler,
      args,
      '${result.stdout}\n${result.stderr}'.trim(),
      result.exitCode,
    );
  }
}

String _sdkPath(CodeConfig codeConfig) {
  final String sdkName;
  if (codeConfig.targetOS == OS.iOS) {
    sdkName = codeConfig.iOS.targetSdk == IOSSdk.iPhoneOS
        ? 'iphoneos'
        : 'iphonesimulator';
  } else {
    sdkName = 'macosx';
  }
  final ProcessResult result = Process.runSync('xcrun', <String>[
    '--show-sdk-path',
    '--sdk',
    sdkName,
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      'xcrun',
      <String>['--show-sdk-path', '--sdk', sdkName],
      '${result.stderr}'.trim(),
      result.exitCode,
    );
  }
  return (result.stdout as String)
      .split('\n')
      .map((String line) => line.trim())
      .firstWhere((String line) => line.isNotEmpty);
}

String _minOSVersionFlag(CodeConfig codeConfig) {
  if (codeConfig.targetOS == OS.iOS) {
    final String version = _formatAppleVersion(
      codeConfig.iOS.deploymentVersion,
    );
    return codeConfig.iOS.targetSdk == IOSSdk.iPhoneSimulator
        ? '-mios-simulator-version-min=$version'
        : '-mios-version-min=$version';
  }
  final String version = _formatAppleVersion(
    codeConfig.macOS.deploymentVersion,
  );
  return '-mmacosx-version-min=$version';
}

String _toTargetTriple(CodeConfig codeConfig) {
  final Architecture arch = codeConfig.targetArchitecture;
  if (codeConfig.targetOS == OS.iOS) {
    final IOSSdk sdk = codeConfig.iOS.targetSdk;
    final String? triple = _iosTargetTriples[arch]?[sdk];
    if (triple == null) {
      throw UnsupportedError('Unsupported iOS target: $arch ($sdk)');
    }
    return triple;
  }
  final String? triple = _macosTargetTriples[arch];
  if (triple == null) {
    throw UnsupportedError('Unsupported macOS target: $arch');
  }
  return triple;
}

String _formatAppleVersion(AppleVersion version) {
  if (version.patch != 0) {
    return '${version.major}.${version.minor}.${version.patch}';
  }
  if (version.minor != 0) {
    return '${version.major}.${version.minor}';
  }
  return '${version.major}';
}

final Map<Architecture, String> _macosTargetTriples = <Architecture, String>{
  Architecture.arm64: 'arm64-apple-darwin',
  Architecture.arm64e: 'arm64e-apple-darwin',
  Architecture.x64: 'x86_64-apple-darwin',
};

final Map<Architecture, Map<IOSSdk, String>> _iosTargetTriples =
    <Architecture, Map<IOSSdk, String>>{
      Architecture.arm64: <IOSSdk, String>{
        IOSSdk.iPhoneOS: 'arm64-apple-ios',
        IOSSdk.iPhoneSimulator: 'arm64-apple-ios-simulator',
      },
      Architecture.arm64e: <IOSSdk, String>{
        IOSSdk.iPhoneOS: 'arm64e-apple-ios',
        IOSSdk.iPhoneSimulator: 'arm64e-apple-ios-simulator',
      },
      Architecture.x64: <IOSSdk, String>{
        IOSSdk.iPhoneSimulator: 'x86_64-apple-ios-simulator',
      },
    };
