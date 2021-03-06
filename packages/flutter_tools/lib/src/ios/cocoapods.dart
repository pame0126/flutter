// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';

import '../base/common.dart';
import '../base/context.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../base/process_manager.dart';
import '../base/version.dart';
import '../cache.dart';
import '../globals.dart';
import 'xcodeproj.dart';

const String noCocoaPodsConsequence = '''
  CocoaPods is used to retrieve the iOS platform side's plugin code that responds to your plugin usage on the Dart side.
  Without resolving iOS dependencies with CocoaPods, plugins will not work on iOS.
  For more info, see https://flutter.io/platform-plugins''';

const String cocoaPodsInstallInstructions = '''
  brew install cocoapods
  pod setup''';

const String cocoaPodsUpgradeInstructions = '''
  brew upgrade cocoapods
  pod setup''';

CocoaPods get cocoaPods => context[CocoaPods];

/// Result of evaluating the CocoaPods installation.
enum CocoaPodsStatus {
  /// iOS plugins will not work, installation required.
  notInstalled,
  /// iOS plugins will not work, upgrade required.
  belowMinimumVersion,
  /// iOS plugins may not work in certain situations (Swift, static libraries),
  /// upgrade recommended.
  belowRecommendedVersion,
  /// Everything should be fine.
  recommended,
}

class CocoaPods {
  Future<String> _versionText;

  String get cocoaPodsMinimumVersion => '1.0.0';
  String get cocoaPodsRecommendedVersion => '1.5.0';

  Future<String> get cocoaPodsVersionText {
    _versionText ??= runAsync(<String>['pod', '--version']).then<String>((RunResult result) {
      return result.exitCode == 0 ? result.stdout.trim() : null;
    }, onError: (dynamic _) => null);
    return _versionText;
  }

  Future<CocoaPodsStatus> get evaluateCocoaPodsInstallation async {
    final String versionText = await cocoaPodsVersionText;
    if (versionText == null)
      return CocoaPodsStatus.notInstalled;
    try {
      final Version installedVersion = new Version.parse(versionText);
      if (installedVersion < new Version.parse(cocoaPodsMinimumVersion))
        return CocoaPodsStatus.belowMinimumVersion;
      else if (installedVersion < new Version.parse(cocoaPodsRecommendedVersion))
        return CocoaPodsStatus.belowRecommendedVersion;
      else
        return CocoaPodsStatus.recommended;
    } on FormatException {
      return CocoaPodsStatus.notInstalled;
    }
  }

  /// Whether CocoaPods ran 'pod setup' once where the costly pods' specs are cloned.
  Future<bool> get isCocoaPodsInitialized => fs.isDirectory(fs.path.join(homeDirPath, '.cocoapods', 'repos', 'master'));

  Future<bool> processPods({
    @required Directory appIosDirectory,
    // For backward compatibility with previously created Podfile only.
    @required String iosEngineDir,
    bool isSwift: false,
    bool dependenciesChanged: true,
  }) async {
    if (!(await appIosDirectory.childFile('Podfile').exists())) {
      throwToolExit('Podfile missing');
    }
    if (await _checkPodCondition()) {
      if (_shouldRunPodInstall(appIosDirectory, dependenciesChanged)) {
        await _runPodInstall(appIosDirectory, iosEngineDir);
        return true;
      }
    }
    return false;
  }

  /// Make sure the CocoaPods tools are in the right states.
  Future<bool> _checkPodCondition() async {
    final CocoaPodsStatus installation = await evaluateCocoaPodsInstallation;
    switch (installation) {
      case CocoaPodsStatus.notInstalled:
        printError(
          'Warning: CocoaPods not installed. Skipping pod install.\n'
          '$noCocoaPodsConsequence\n'
          'To install:\n'
          '$cocoaPodsInstallInstructions\n',
          emphasis: true,
        );
        return false;
      case CocoaPodsStatus.belowMinimumVersion:
        printError(
          'Warning: CocoaPods minimum required version $cocoaPodsMinimumVersion or greater not installed. Skipping pod install.\n'
          '$noCocoaPodsConsequence\n'
          'To upgrade:\n'
          '$cocoaPodsUpgradeInstructions\n',
          emphasis: true,
        );
        return false;
      case CocoaPodsStatus.belowRecommendedVersion:
        printError(
          'Warning: CocoaPods recommended version $cocoaPodsRecommendedVersion or greater not installed.\n'
          'Pods handling may fail on some projects involving plugins.\n'
          'To upgrade:\n'
          '$cocoaPodsUpgradeInstructions\n',
          emphasis: true,
        );
        break;
      default:
        break;
    }
    if (!await isCocoaPodsInitialized) {
      printError(
        'Warning: CocoaPods installed but not initialized. Skipping pod install.\n'
        '$noCocoaPodsConsequence\n'
        'To initialize CocoaPods, run:\n'
        '  pod setup\n'
        'once to finalize CocoaPods\' installation.',
        emphasis: true,
      );
      return false;
    }

    return true;
  }

  /// Ensures the `ios` sub-project of the Flutter project at [appDirectory]
  /// contains a suitable `Podfile` and that its `Flutter/Xxx.xcconfig` files
  /// include pods configuration.
  void setupPodfile(String appDirectory) {
    if (!xcodeProjectInterpreter.isInstalled) {
      // Don't do anything for iOS when host platform doesn't support it.
      return;
    }
    final String podfilePath = fs.path.join(appDirectory, 'ios', 'Podfile');
    if (!fs.file(podfilePath).existsSync()) {
      final bool isSwift = xcodeProjectInterpreter.getBuildSettings(
        fs.path.join(appDirectory, 'ios', 'Runner.xcodeproj'),
        'Runner',
      ).containsKey('SWIFT_VERSION');
      final File podfileTemplate = fs.file(fs.path.join(
        Cache.flutterRoot,
        'packages',
        'flutter_tools',
        'templates',
        'cocoapods',
        isSwift ? 'Podfile-swift' : 'Podfile-objc',
      ));
      podfileTemplate.copySync(podfilePath);
    }
    _addPodsDependencyToFlutterXcconfig(appDirectory, 'Debug');
    _addPodsDependencyToFlutterXcconfig(appDirectory, 'Release');
  }

  void _addPodsDependencyToFlutterXcconfig(String appDirectory, String mode) {
    final File file = fs.file(fs.path.join(appDirectory, 'ios', 'Flutter', '$mode.xcconfig'));
    if (file.existsSync()) {
      final String content = file.readAsStringSync();
      final String include = '#include "Pods/Target Support Files/Pods-Runner/Pods-Runner.${mode
          .toLowerCase()}.xcconfig"';
      if (!content.contains(include))
        file.writeAsStringSync('$include\n$content', flush: true);
    }
  }

  /// Ensures that pod install is deemed needed on next check.
  void invalidatePodInstallOutput(String appDirectory) {
    final File manifest = fs.file(
      fs.path.join(appDirectory, 'ios', 'Pods', 'Manifest.lock'),
    );
    if (manifest.existsSync())
      manifest.deleteSync();
  }

  // Check if you need to run pod install.
  // The pod install will run if any of below is true.
  // 1. Flutter dependencies have changed
  // 2. Podfile.lock doesn't exist or is older than Podfile
  // 3. Pods/Manifest.lock doesn't exist (It is deleted when plugins change)
  // 4. Podfile.lock doesn't match Pods/Manifest.lock.
  bool _shouldRunPodInstall(Directory appIosDirectory, bool dependenciesChanged) {
    if (dependenciesChanged)
      return true;
    final File podfileFile = appIosDirectory.childFile('Podfile');
    final File podfileLockFile = appIosDirectory.childFile('Podfile.lock');
    final File manifestLockFile =
        appIosDirectory.childFile(fs.path.join('Pods', 'Manifest.lock'));
    return !podfileLockFile.existsSync()
        || !manifestLockFile.existsSync()
        || podfileLockFile.statSync().modified.isBefore(podfileFile.statSync().modified)
        || podfileLockFile.readAsStringSync() != manifestLockFile.readAsStringSync();
  }

  Future<Null> _runPodInstall(Directory appIosDirectory, String engineDirectory) async {
    final Status status = logger.startProgress('Running pod install...', expectSlowOperation: true);
    final ProcessResult result = await processManager.run(
      <String>['pod', 'install', '--verbose'],
      workingDirectory: appIosDirectory.path,
      environment: <String, String>{
        // For backward compatibility with previously created Podfile only.
        'FLUTTER_FRAMEWORK_DIR': engineDirectory,
        // See https://github.com/flutter/flutter/issues/10873.
        // CocoaPods analytics adds a lot of latency.
        'COCOAPODS_DISABLE_STATS': 'true',
      },
    );
    status.stop();
    if (logger.isVerbose || result.exitCode != 0) {
      if (result.stdout.isNotEmpty) {
        printStatus('CocoaPods\' output:\n↳');
        printStatus(result.stdout, indent: 4);
      }
      if (result.stderr.isNotEmpty) {
        printStatus('Error output from CocoaPods:\n↳');
        printStatus(result.stderr, indent: 4);
      }
    }
    if (result.exitCode != 0) {
      invalidatePodInstallOutput(appIosDirectory.parent.path);
      _diagnosePodInstallFailure(result);
      throwToolExit('Error running pod install');
    }
  }

  void _diagnosePodInstallFailure(ProcessResult result) {
    if (result.stdout is String && result.stdout.contains('out-of-date source repos')) {
      printError(
        "Error: CocoaPods's specs repository is too out-of-date to satisfy dependencies.\n"
        'To update the CocoaPods specs, run:\n'
        '  pod repo update\n',
        emphasis: true,
      );
    }
  }
}
