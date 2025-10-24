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
  
  /// 检查本地是否有缓存文件并且文件是完整的
  Future<bool> hasCachedFile(String name, String version) async {
    final file = _getTarballFile(name, version);
    if (!await file.exists()) {
      return false;
    }
    
    // 检查文件是否完整，通过验证 gzip 文件头
    try {
      final fileStream = file.openRead();
      final firstBytes = await fileStream.take(3).toList();
      await fileStream.drain(); // 消耗剩余的数据
      
      // 检查是否是有效的 gzip 文件头 (前两个字节应该是 0x1f 和 0x8b)
      if (firstBytes.isNotEmpty && firstBytes.length >= 2) {
        final List<int> bytes = firstBytes[0];
        if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
          return true;
        }
      }
      
      print('检测到可能不完整的缓存文件: ${file.path}');
      return false;
    } catch (e) {
      print('检查文件完整性时出错: $e');
      return false;
    }
  }
  
  /// 从上游下载并缓存文件
  Future<bool> downloadAndCache(String name, String version) async {
    final file = _getTarballFile(name, version);
    final tempFile = File('${file.path}.tmp');
    
    // 如果正式文件已存在且完整，直接返回
    if (await file.exists() && await _isFileValid(file)) {
      return true;
    }
    
    // 从上游下载到临时文件
    final upstreamUrl = Uri.parse(upstream)
        .resolve('/packages/$name/versions/$version.tar.gz')
        .toString();
        
    print('从上游下载: $upstreamUrl');
    
    try {
      final response = await http.get(Uri.parse(upstreamUrl)).timeout(Duration(minutes: 5));
      if (response.statusCode == 200) {
        // 先写入临时文件
        await tempFile.writeAsBytes(response.bodyBytes);
        
        // 验证临时文件是否完整
        if (!await _isFileValid(tempFile)) {
          await tempFile.delete();
          print('下载的文件似乎不完整');
          return false;
        }
        
        // 原子性地移动临时文件到正式位置
        await tempFile.rename(file.path);
        print('成功缓存文件: ${file.path}');
        return true;
      } else {
        print('下载失败: ${response.statusCode}');
        // 清理可能存在的临时文件
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        return false;
      }
    } catch (e) {
      print('下载异常: $e');
      // 清理可能存在的临时文件
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      return false;
    }
  }
  
  /// 验证文件是否有效（检查 gzip 头部）
  Future<bool> _isFileValid(File file) async {
    try {
      if (!await file.exists()) {
        return false;
      }
      
      final stat = await file.stat();
      if (stat.size == 0) {
        return false;
      }
      
      // 读取文件前几个字节检查 gzip 头部
      final fileStream = file.openRead();
      final firstBytes = await fileStream.take(10).toList();
      await fileStream.drain();
      
      if (firstBytes.isNotEmpty) {
        final List<int> bytes = firstBytes[0];
        // 检查 gzip 文件头: 0x1f 0x8b
        if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
          return true;
        }
      }
      
      return false;
    } catch (e) {
      print('验证文件有效性时出错: $e');
      return false;
    }
  }
}