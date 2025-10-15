import 'dart:io';
import 'package:path/path.dart' as path;
import 'package_store.dart';
import 'package:http/http.dart' as http;

class FileStore extends PackageStore {
  String baseDir;
  String upstream;
  String Function(String name, String version)? getFilePath;

  FileStore(this.baseDir, {this.getFilePath, this.upstream = 'https://pub.dev/'}) {
    // 确保基础目录存在
    final dir = Directory(baseDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  File _getTarballFile(String name, String version) {
    final filePath =
        getFilePath?.call(name, version) ?? '$name-$version.tar.gz';
    final fullPath = path.join(baseDir, filePath);
    
    // 确保文件的父目录存在
    final file = File(fullPath);
    final directory = file.parent;
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    
    return file;
  }

  @override
  Future<void> upload(String name, String version, List<int> content) async {
    var file = _getTarballFile(name, version);
    await file.writeAsBytes(content);
  }

  @override
  Stream<List<int>> download(String name, String version) {
    print('下载仓库: $name-$version');
    return _getTarballFile(name, version).openRead();
  }
  
  /// 检查本地是否有缓存文件
  Future<bool> hasCachedFile(String name, String version) async {
    return await _getTarballFile(name, version).exists();
  }
  
  /// 从上游下载并缓存文件
  Future<bool> downloadAndCache(String name, String version) async {
    final file = _getTarballFile(name, version);
    
    // 如果文件已存在，直接返回
    if (await file.exists()) {
      return true;
    }
    
    // 从上游下载
    final upstreamUrl = Uri.parse(upstream)
        .resolve('/packages/$name/versions/$version.tar.gz')
        .toString();
        
    print('从上游下载: $upstreamUrl');
    
    try {
      final response = await http.get(Uri.parse(upstreamUrl)).timeout(Duration(minutes: 3));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        return true;
      } else {
        print('下载失败: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('下载异常: $e');
      return false;
    }
  }
}