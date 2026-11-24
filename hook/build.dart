import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _pluginName = 'xue_hua_navite_clipboard';
const _assetName = '${_pluginName}_objc_gen.dylib';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final codeConfig = input.config.code;
    final targetOS = codeConfig.targetOS;
    if (targetOS != OS.iOS && targetOS != OS.macOS) {
      return;
    }

    if (codeConfig.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError('LinkModePreference.static is not supported.');
    }

    final platformDir = targetOS == OS.iOS ? 'ios' : 'macos';
    final objcGenDir = Directory.fromUri(
      input.packageRoot.resolve(
        '$platformDir/$_pluginName/Sources/${_pluginName}_objc_gen/',
      ),
    );
    if (!objcGenDir.existsSync()) {
      throw StateError(
        'Expected Objective-C generated sources directory not found: '
        '${objcGenDir.path}',
      );
    }

    final mFiles = <File>[];
    final hFiles = <File>[];
    for (final entity in objcGenDir.listSync(recursive: true)) {
      if (entity is File) {
        if (entity.path.endsWith('.m')) {
          mFiles.add(entity);
        } else if (entity.path.endsWith('.h')) {
          hFiles.add(entity);
        }
      }
    }
    mFiles.sort((a, b) => a.path.compareTo(b.path));
    hFiles.sort((a, b) => a.path.compareTo(b.path));
    if (mFiles.isEmpty) {
      throw StateError(
        'No Objective-C .m trampoline files found in ${objcGenDir.path}',
      );
    }

    final compiler = _resolveCompiler(codeConfig);
    final sysroot = _resolveSdkPath(codeConfig);
    final targetTriple = _toTargetTriple(codeConfig);
    final minOSFlag = _minOSVersionFlag(codeConfig);

    final objOutDir = Directory.fromUri(input.outputDirectory.resolve('obj/'));
    objOutDir.createSync(recursive: true);

    final objcGenRootPath = objcGenDir.uri.toFilePath();
    final objectFiles = await Future.wait<String>([
      for (final mFile in mFiles)
        _compileObject(
          compiler: compiler,
          sourceFile: mFile,
          objcGenRootPath: objcGenRootPath,
          objOutDirUri: objOutDir.uri,
          sysroot: sysroot,
          targetTriple: targetTriple,
          minOSFlag: minOSFlag,
        ),
    ]);

    final assetPath = input.outputDirectory.resolve(_assetName);
    await _runClang(compiler, <String>[
      '-shared',
      if (targetOS == OS.iOS) '-Wl,-encryptable',
      '-isysroot',
      sysroot,
      '-target',
      targetTriple,
      minOSFlag,
      '-framework',
      'Foundation',
      '-lobjc',
      ...objectFiles,
      '-o',
      assetPath.toFilePath(),
    ]);

    output.dependencies.addAll(mFiles.map((file) => file.uri));
    output.dependencies.addAll(hFiles.map((file) => file.uri));

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

String _resolveCompiler(CodeConfig codeConfig) {
  final compiler = codeConfig.cCompiler?.compiler.toFilePath();
  if (compiler != null && File(compiler).existsSync()) {
    return compiler;
  }
  return 'clang';
}

String _resolveSdkPath(CodeConfig codeConfig) {
  final String sdkName;
  if (codeConfig.targetOS == OS.iOS) {
    sdkName = codeConfig.iOS.targetSdk == IOSSdk.iPhoneOS
        ? 'iphoneos'
        : 'iphonesimulator';
  } else {
    sdkName = 'macosx';
  }

  final result = Process.runSync('xcrun', <String>[
    '--show-sdk-path',
    '--sdk',
    sdkName,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'Failed to locate Apple SDK "$sdkName" via xcrun: ${result.stderr}',
    );
  }
  final lines = (result.stdout as String)
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  if (lines.isEmpty) {
    throw StateError('xcrun returned an empty SDK path for "$sdkName".');
  }
  return lines.first;
}

String _minOSVersionFlag(CodeConfig codeConfig) {
  if (codeConfig.targetOS == OS.iOS) {
    final version = _appleDeploymentTarget(codeConfig.iOS.deploymentVersion);
    if (codeConfig.iOS.targetSdk == IOSSdk.iPhoneOS) {
      return '-mios-version-min=$version';
    }
    return '-mios-simulator-version-min=$version';
  }
  final version = _appleDeploymentTarget(codeConfig.macOS.deploymentVersion);
  return '-mmacosx-version-min=$version';
}

String _appleDeploymentTarget(AppleVersion version) {
  final major = version.major;
  final minor = version.minor;
  final patch = version.patch;
  if (patch != 0) return '$major.$minor.$patch';
  if (minor != 0) return '$major.$minor';
  return '$major';
}

String _toTargetTriple(CodeConfig codeConfig) {
  final architecture = codeConfig.targetArchitecture;
  if (codeConfig.targetOS == OS.iOS) {
    final triple = _iOSTargetTriples[architecture]?[codeConfig.iOS.targetSdk];
    if (triple == null) {
      throw UnsupportedError(
        'Unsupported iOS target: $architecture (${codeConfig.iOS.targetSdk}).',
      );
    }
    return triple;
  }
  final triple = _macOSTargetTriples[architecture];
  if (triple == null) {
    throw UnsupportedError('Unsupported macOS target: $architecture.');
  }
  return triple;
}

final Map<Architecture, String> _macOSTargetTriples = {
  Architecture.arm64: 'arm64-apple-darwin',
  Architecture.arm64e: 'arm64e-apple-darwin',
  Architecture.x64: 'x86_64-apple-darwin',
};

final Map<Architecture, Map<IOSSdk, String>> _iOSTargetTriples = {
  Architecture.arm64: {
    IOSSdk.iPhoneOS: 'arm64-apple-ios',
    IOSSdk.iPhoneSimulator: 'arm64-apple-ios-simulator',
  },
  Architecture.arm64e: {
    IOSSdk.iPhoneOS: 'arm64e-apple-ios',
    IOSSdk.iPhoneSimulator: 'arm64e-apple-ios-simulator',
  },
  Architecture.x64: {IOSSdk.iPhoneSimulator: 'x86_64-apple-ios-simulator'},
};

Future<String> _compileObject({
  required String compiler,
  required File sourceFile,
  required String objcGenRootPath,
  required Uri objOutDirUri,
  required String sysroot,
  required String targetTriple,
  required String minOSFlag,
}) async {
  final sourcePath = sourceFile.uri.toFilePath();
  final relativePath = sourcePath.startsWith(objcGenRootPath)
      ? sourcePath.substring(objcGenRootPath.length)
      : sourceFile.uri.pathSegments.last;
  final objectPath = '${objOutDirUri.resolve(relativePath).toFilePath()}.o';
  File(objectPath).parent.createSync(recursive: true);

  await _runClang(compiler, <String>[
    '-isysroot',
    sysroot,
    '-target',
    targetTriple,
    minOSFlag,
    '-x',
    'objective-c',
    '-fobjc-arc',
    '-fpic',
    '-gline-tables-only',
    '-I',
    objcGenRootPath,
    '-c',
    sourcePath,
    '-o',
    objectPath,
  ]);
  return objectPath;
}

Future<void> _runClang(String compiler, List<String> args) async {
  final result = await Process.run(compiler, args);
  if (result.exitCode != 0) {
    throw ProcessException(
      compiler,
      args,
      'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      result.exitCode,
    );
  }
}
