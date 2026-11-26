import 'dart:convert';
import 'dart:io';

/// 在真正执行编译的 Dart 进程中读取依赖，避免只检查路径存在而漏掉文件访问限制。
void main(List<String> arguments) {
  final failures = <Map<String, Object?>>[];
  var packageCount = 0;
  var readablePubspecCount = 0;
  var packageDirectoryCount = 0;
  var readableEntrypointCount = 0;
  var scannedSourceCount = 0;
  var checkedImportCount = 0;
  var readableImportCount = 0;
  final optionalMissingDirectories = <Map<String, String>>[];
  final optionalMissingEntrypoints = <Map<String, String>>[];
  final packageDirectories = <String, Directory>{};
  String? configPath;

  void recordFailure(
    String? package,
    String path,
    String operation,
    Object error,
  ) {
    failures.add({
      'package': package,
      'path': path,
      'operation': operation,
      'error': error.toString(),
    });
  }

  // stat/type 会把部分访问错误也折叠为 notFound，先解析实际路径以区分明确缺失和权限错误。
  FileSystemEntityType optionalEntityType(FileSystemEntity entity) {
    try {
      entity.resolveSymbolicLinksSync();
      final type = FileSystemEntity.typeSync(entity.path);
      if (type == FileSystemEntityType.notFound) {
        throw FileSystemException('路径已解析，但无法读取文件类型。', entity.path);
      }
      return type;
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code == 2 || (Platform.isWindows && code == 3)) {
        return FileSystemEntityType.notFound;
      }
      rethrow;
    }
  }

  try {
    if (arguments.length != 1 || !Directory(arguments.single).isAbsolute) {
      throw const FormatException('必须提供且仅提供项目绝对路径。');
    }
    final project = Directory(arguments.single);
    final config = File.fromUri(
      project.uri.resolve('.dart_tool/package_config.json'),
    );
    configPath = config.path;
    final decoded = jsonDecode(config.readAsStringSync());
    if (decoded is! Map<String, dynamic> || decoded['configVersion'] != 2) {
      throw const FormatException('依赖配置必须是 package_config v2 对象。');
    }
    final packages = decoded['packages'];
    if (packages is! List || packages.isEmpty) {
      throw const FormatException('依赖配置中的 packages 必须是非空数组。');
    }
    packageCount = packages.length;
    final names = <String>{};

    for (var index = 0; index < packages.length; index++) {
      String? name;
      var currentPath = config.path;
      var operation = '解析依赖记录';
      try {
        final package = packages[index];
        if (package is! Map<String, dynamic>) {
          throw FormatException('第 $index 条依赖记录不是对象。');
        }
        final packageName = package['name'];
        final rootUriText = package['rootUri'];
        if (packageName is! String ||
            !RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(packageName) ||
            rootUriText is! String ||
            rootUriText.isEmpty) {
          throw FormatException('第 $index 条依赖记录缺少有效的 name 或 rootUri。');
        }
        name = packageName;
        if (!names.add(name)) {
          throw FormatException('依赖名称重复：$name');
        }

        // rootUri 不一定以斜杠结尾，先转换目录再解析子路径，避免丢失最后一级目录。
        final root = Directory.fromUri(config.uri.resolve(rootUriText));
        final pubspec = File.fromUri(root.uri.resolve('pubspec.yaml'));
        currentPath = pubspec.path;
        operation = '读取 pubspec.yaml';
        pubspec.readAsBytesSync();
        readablePubspecCount++;

        final packageUriText = package['packageUri'];
        var packageDirectory = root;
        if (packageUriText != null) {
          operation = '检查 packageUri 目录';
          if (packageUriText is! String || packageUriText.isEmpty) {
            throw const FormatException('packageUri 必须是非空字符串。');
          }
          packageDirectory = Directory.fromUri(
            root.uri.resolve(packageUriText),
          );
          currentPath = packageDirectory.path;
          final directoryType = optionalEntityType(packageDirectory);
          if (directoryType == FileSystemEntityType.directory) {
            packageDirectoryCount++;
          } else if (directoryType == FileSystemEntityType.notFound) {
            // 纯资源包、原生插件可以合法没有 Dart lib 目录；实际被导入时仍在下方严格读取。
            optionalMissingDirectories.add({
              'package': name,
              'path': currentPath,
            });
          } else {
            throw FileSystemException('packageUri 路径存在但不是目录。', currentPath);
          }
        }
        packageDirectories[name] = packageDirectory;

        // 只读取约定的同名入口，不遍历缓存目录，也不输出依赖文件的内容。
        final entrypoint = File.fromUri(root.uri.resolve('lib/$name.dart'));
        currentPath = entrypoint.path;
        operation = '读取同名 Dart 入口';
        final entrypointType = optionalEntityType(entrypoint);
        if (entrypointType == FileSystemEntityType.file) {
          entrypoint.readAsBytesSync();
          readableEntrypointCount++;
        } else if (entrypointType == FileSystemEntityType.notFound) {
          optionalMissingEntrypoints.add({
            'package': name,
            'path': currentPath,
          });
        } else {
          throw FileSystemException('同名 Dart 入口不是普通文件。', currentPath);
        }
      } catch (error) {
        recordFailure(name, currentPath, operation, error);
      }
    }

    // 仅扫描项目 lib 源码的 import/export 主指令，不递归解析第三方包或条件导入分支。
    final importPattern = RegExp(
      r'''^\s*(?:import|export)\s+['"](package:[^'"\r\n]+)['"]''',
      multiLine: true,
    );
    final requiredImports = <String>{};
    final sourceDirectory = Directory.fromUri(project.uri.resolve('lib/'));
    for (final source in sourceDirectory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (source is! File || !source.path.endsWith('.dart')) {
        continue;
      }
      try {
        final contents = source.readAsStringSync();
        scannedSourceCount++;
        for (final match in importPattern.allMatches(contents)) {
          final importText = match.group(1)!;
          if (!requiredImports.add(importText)) {
            continue;
          }
          checkedImportCount++;
          String? importPackage;
          var importPath = importText;
          try {
            final importUri = Uri.parse(importText);
            final segments = importUri.pathSegments;
            if (segments.length < 2 ||
                importUri.hasQuery ||
                importUri.hasFragment) {
              throw FormatException('package 导入路径无效：$importText');
            }
            importPackage = segments.first;
            final packageDirectory = packageDirectories[importPackage];
            if (packageDirectory == null) {
              throw FormatException('导入的包缺少有效依赖记录：$importPackage');
            }
            final relativeUri = Uri(pathSegments: segments.skip(1));
            final importedFile = File.fromUri(
              packageDirectory.uri.resolveUri(relativeUri),
            );
            importPath = importedFile.path;
            importedFile.readAsBytesSync();
            readableImportCount++;
          } catch (error) {
            recordFailure(
              importPackage,
              importPath,
              '读取必需导入（${source.path}）',
              error,
            );
          }
        }
      } catch (error) {
        recordFailure(null, source.path, '读取项目 Dart 源码', error);
      }
    }
  } catch (error) {
    recordFailure(null, configPath ?? '', '读取依赖配置', error);
  }

  // 标准输出保持为单个 JSON；调用者可以直接归档、解析并据此阻止后续构建。
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'status': failures.isEmpty ? 'readable' : 'failed',
      'package_config': configPath,
      'package_count': packageCount,
      'readable_pubspec_count': readablePubspecCount,
      'package_directory_count': packageDirectoryCount,
      'readable_entrypoint_count': readableEntrypointCount,
      'optional_missing_directories': optionalMissingDirectories,
      'optional_missing_entrypoints': optionalMissingEntrypoints,
      'scanned_source_count': scannedSourceCount,
      'checked_import_count': checkedImportCount,
      'readable_import_count': readableImportCount,
      'failure_count': failures.length,
      'failures': failures,
    }),
  );
  if (failures.isNotEmpty) {
    exitCode = 1;
  }
}
