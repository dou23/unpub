import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:args/args.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:sembast/sembast_io.dart';
import 'package:unpub/unpub.dart' as unpub;

main(List<String> args) async {
  var parser = ArgParser();
  parser.addOption('host', abbr: 'h', defaultsTo: '0.0.0.0');
  parser.addOption('port', abbr: 'p', defaultsTo: '9090');
  parser.addOption('upstreamUrl', abbr: 'u', defaultsTo: 'https://mirrors.tuna.tsinghua.edu.cn/dart-pub/');
  parser.addOption('cache_path', abbr: 'c', defaultsTo: '');
  parser.addOption('database',
      abbr: 'd', defaultsTo: 'mongodb://localhost:27017/dart_pub');
  parser.addOption('proxy-origin', abbr: 'o', defaultsTo: '');

  var results = parser.parse(args);

  var host = results['host'] as String;
  var port = int.parse(results['port'] as String);
  var dbUri = results['database'] as String;
  var proxy_origin = results['proxy-origin'] as String;
  var upstreamUrl = results['upstreamUrl'] as String;

  if (results.rest.isNotEmpty) {
    print('Got unexpected arguments: "${results.rest.join(' ')}".\n\nUsage:\n');
    print(parser.usage);
    exit(1);
  }

  // final db = Db(dbUri);
  // await db.open();
  var cachePath = results['cache_path'] as String;
  var baseDir;
  if (cachePath.isNotEmpty) {
    baseDir = cachePath;
  } else {
    baseDir = path.absolute('unpub-packages');
  }
  // var dbStore = unpub.MongoStore(db);
  final db = await databaseFactoryIo.openDatabase(
    path.join(baseDir,'.db', 'sembast', 'unpub.db'),
  );
  var dbStore = unpub.SembastStore(db);
  // var dbStore = unpub.SqliteStore(baseDir);
  var app = unpub.App(
    metaStore: dbStore,
    packageStore: unpub.FileStore(baseDir, upstream: upstreamUrl),
    upstream: upstreamUrl,
    proxy_origin: proxy_origin.trim().isEmpty ? null : Uri.parse(proxy_origin),
    cacheDirectory: Directory(baseDir + '/unpub_cache'),
  );

  var server = await app.serve(host, port);
  print('Serving at http://${server.address.host}:${server.port}');
}
