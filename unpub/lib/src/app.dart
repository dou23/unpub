import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:googleapis/oauth2/v2.dart';
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:archive/archive.dart';
import 'package:unpub/src/file_store.dart';
import 'package:unpub/src/models.dart';
import 'package:unpub/unpub_api/lib/models.dart';
import 'package:unpub/src/meta_store.dart';
import 'package:unpub/src/package_store.dart';
import 'utils.dart';
import 'static/index.html.dart' as index_html;
import 'static/main.dart.js.dart' as main_dart_js;

part 'app.g.dart';

class CachedResponse {
  final String body;
  final Map<String, String> headers;
  final int statusCode;
  final DateTime cachedAt;
  final Duration maxAge;

  CachedResponse({
    required this.body,
    required this.headers,
    this.statusCode = 200,
    required this.cachedAt,
    required this.maxAge,
  });

  bool get isExpired => DateTime.now().isAfter(cachedAt.add(maxAge));

  Map<String, dynamic> toJson() => {
        'body': body,
        'headers': headers,
        'statusCode': statusCode,
        'cachedAt': cachedAt.toIso8601String(),
        'maxAgeInSeconds': maxAge.inSeconds,
      };

  factory CachedResponse.fromJson(Map<String, dynamic> json) => CachedResponse(
        body: json['body'] as String,
        headers: Map<String, String>.from(json['headers'] as Map),
        statusCode: json['statusCode'] as int,
        cachedAt: DateTime.parse(json['cachedAt'] as String),
        maxAge: Duration(seconds: json['maxAgeInSeconds'] as int),
      );
}

class App {
  static const proxyOriginHeader = "proxy-origin";

  /// meta information store
  final MetaStore metaStore;

  /// package(tarball) store
  final PackageStore packageStore;

  /// upstream url, default: https://pub.flutter-io.cn
  final String upstream;

  /// http(s) proxy to call googleapis (to get uploader email)
  final String? googleapisProxy;
  final String? overrideUploaderEmail;

  /// A forward proxy uri
  final Uri? proxy_origin;

  /// Cache directory for offline support
  final Directory? cacheDirectory;

  /// validate if the package can be published
  ///
  /// for more details, see: https://github.com/bytedance/unpub#package-validator
  final Future<void> Function(
      Map<String, dynamic> pubspec, String uploaderEmail)? uploadValidator;

  // In-memory cache for responses
  final Map<String, CachedResponse> _responseCache = {};

  App({
    required this.metaStore,
    required this.packageStore,
    this.upstream = 'https://pub.dev/',
    this.googleapisProxy,
    this.overrideUploaderEmail,
    this.uploadValidator,
    this.proxy_origin,
    this.cacheDirectory,
  }) {
    // Ensure cache directory exists if provided
    if (cacheDirectory != null && !cacheDirectory!.existsSync()) {
      cacheDirectory!.createSync(recursive: true);
    }
  }

  static shelf.Response _okWithJson(Map<String, dynamic> data) =>
      shelf.Response.ok(
        json.encode(data),
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          'Access-Control-Allow-Origin': '*'
        },
      );

  static shelf.Response _successMessage(String message) => _okWithJson({
        'success': {'message': message}
      });

  static shelf.Response _badRequest(String message,
          {int status = HttpStatus.badRequest}) =>
      shelf.Response(
        status,
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
        body: json.encode({
          'error': {'message': message}
        }),
      );

  http.Client? _googleapisClient;

  String _resolveUrl(shelf.Request req, String reference) {
    if (proxy_origin != null) {
      return proxy_origin!.resolve(reference).toString();
    }
    String? proxyOriginInHeader = req.headers[proxyOriginHeader];
    if (proxyOriginInHeader != null) {
      return Uri.parse(proxyOriginInHeader).resolve(reference).toString();
    }
    return req.requestedUri.resolve(reference).toString();
  }

  Future<String> _getUploaderEmail(shelf.Request req) async {
    if (overrideUploaderEmail != null) return overrideUploaderEmail!;

    var authHeader = req.headers[HttpHeaders.authorizationHeader];
    if (authHeader == null) throw 'missing authorization header';

    var token = authHeader.split(' ').last;

    if (_googleapisClient == null) {
      if (googleapisProxy != null) {
        _googleapisClient = IOClient(HttpClient()
          ..findProxy = (url) => HttpClient.findProxyFromEnvironment(url,
              environment: {"https_proxy": googleapisProxy!}));
      } else {
        _googleapisClient = http.Client();
      }
    }

    var info =
        await Oauth2Api(_googleapisClient!).tokeninfo(accessToken: token);
    if (info.email == null) throw 'fail to get google account email';
    return info.email!;
  }

  Future<HttpServer> serve([String host = '0.0.0.0', int port = 4000]) async {
    var handler = const shelf.Pipeline()
        .addMiddleware(corsHeaders())
        .addMiddleware(shelf.logRequests())
        .addHandler((req) async {
      // Return 404 by default
      // https://github.com/google/dart-neats/issues/1
      var res = await router.call(req);
      return res;
    });
    var server = await shelf_io.serve(handler, host, port);
    return server;
  }

  Map<String, dynamic> _versionToJson(UnpubVersion item, shelf.Request req) {
    var name = item.pubspec['name'] as String;
    var version = item.version;
    return {
      'archive_url':
          _resolveUrl(req, '/packages/$name/versions/$version.tar.gz'),
      'pubspec': item.pubspec,
      'version': version,
    };
  }

  bool isPubClient(shelf.Request req) {
    var ua = req.headers[HttpHeaders.userAgentHeader];
    print(ua);
    return ua != null && ua.toLowerCase().contains('dart pub');
  }

  Router get router => _$AppRouter(this);

  // Cache helper methods
  String _generateCacheKey(shelf.Request req) {
    return '${req.method}:${req.requestedUri.path}?${req.requestedUri.query}';
  }

  Future<void> _saveToCache(String key, shelf.Response response) async {
    try {
      // Read response body
      final body = await response.readAsString();

      // If cache directory is provided, use file system caching
      if (cacheDirectory != null) {
        final file = File('${cacheDirectory!.path}/$key.json');
        final cachedResponse = CachedResponse(
          body: body,
          headers: response.headers,
          statusCode: response.statusCode,
          cachedAt: DateTime.now(),
          maxAge: const Duration(hours: 1),
        );

        await file.create(recursive: true);
        await file.writeAsString(jsonEncode(cachedResponse.toJson()));
      } else {
        // Use in-memory caching
        _responseCache[key] = CachedResponse(
          body: body,
          headers: response.headers,
          statusCode: response.statusCode,
          cachedAt: DateTime.now(),
          maxAge: const Duration(hours: 1),
        );
      }
    } catch (e) {
      print('Failed to save to cache: $e');
    }
  }

  Future<CachedResponse?> _getFromCache(String key) async {
    try {
      // If cache directory is provided, use file system caching
      if (cacheDirectory != null) {
        final file = File('${cacheDirectory!.path}/$key.json');
        if (await file.exists()) {
          final content = await file.readAsString();
          final json = jsonDecode(content);
          return CachedResponse.fromJson(json);
        }
        return null;
      } else {
        // Use in-memory caching
        return _responseCache[key];
      }
    } catch (e) {
      print('Failed to read from cache: $e');
      return null;
    }
  }

  // Wrapper method to handle requests with caching
  Future<shelf.Response> _handleRequestWithCaching(
    shelf.Request req,
    Future<shelf.Response> Function() handler,
  ) async {
    final cacheKey = _generateCacheKey(req);

    // Try to get from cache first
    final cachedResponse = await _getFromCache(cacheKey);
    if (cachedResponse != null && !cachedResponse.isExpired) {
      print('Serving from cache: $cacheKey');
      return shelf.Response(
        cachedResponse.statusCode,
        body: cachedResponse.body,
        headers: cachedResponse.headers,
      );
    }

    try {
      // Execute the actual handler
      final response = await handler();

      // Cache successful responses
      if (response.statusCode >= 200 && response.statusCode < 300) {
        // 使用 Future.microtask 替代 unawaited
        Future.microtask(() => _saveToCache(cacheKey, response));
      }

      return response;
    } catch (error) {
      // If we have a cached version, return it even if expired
      if (cachedResponse != null) {
        print('Network error, serving stale cache: $cacheKey');
        return shelf.Response(
          cachedResponse.statusCode,
          body: cachedResponse.body,
          headers: {
            ...cachedResponse.headers,
            'X-Unpub-Cache': 'stale',
          },
        );
      }

      // Re-throw if no cache available
      rethrow;
    }
  }

  @Route.get('/api/packages/<name>')
  Future<shelf.Response> getVersions(shelf.Request req, String name) async {
    return _handleRequestWithCaching(req, () async {
      var package = await metaStore.queryPackage(name);

      if (package == null) {
        // 从上游获取包信息
        final upstreamUri =
            Uri.parse(upstream).resolve('/api/packages/$name').toString();
        final client = http.Client();
        try {
          final response = await client.get(Uri.parse(upstreamUri));
          if (response.statusCode == 200) {
            // 解析上游响应
            final data = json.decode(response.body) as Map<String, dynamic>;
            // 提取版本信息并保存到本地数据库
            final versions = data['versions'] as List;
            if (versions.isNotEmpty) {
              // 为每个版本创建 UnpubVersion 对象并添加到数据库
              for (var versionData in versions) {
                final pubspec = versionData['pubspec'] as Map<String, dynamic>;
                final version = versionData['version'] as String;

                // 尝试从上游数据获取创建时间，如果没有则使用当前时间
                DateTime createdAt;
                try {
                  createdAt = DateTime.parse(
                      versionData['created'] as String? ??
                          versionData['published'] as String? ??
                          DateTime.now().toIso8601String());
                } catch (e) {
                  createdAt = DateTime.now();
                }

                final unpubVersion = UnpubVersion(
                  version,
                  pubspec,
                  versionData['pubspecYaml'] as String? ??
                      "", // 尝试使用上游的pubspecYaml
                  "", // uploader 不可用
                  versionData['readme'] as String? ?? "", // 尝试使用上游的readme
                  versionData['changelog'] as String? ?? "", // 尝试使用上游的changelog
                  createdAt, // 使用解析或当前的时间
                );

                // 将版本添加到本地数据库
                await metaStore.addVersion(name, unpubVersion);
              }
            }

            // 返回上游的原始响应
            return shelf.Response(
              response.statusCode,
              body: response.body,
              headers: {
                ...response.headers,
                HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
                'Access-Control-Allow-Origin': '*',
              },
            );
          } else {
            // 如果上游请求失败，则重定向（保持原有行为）
            return shelf.Response.found(upstreamUri);
          }
        } finally {
          client.close();
        }
      }

      package.versions.sort((a, b) {
        return semver.Version.prioritize(
            semver.Version.parse(a.version), semver.Version.parse(b.version));
      });

      var versionMaps =
          package.versions.map((item) => _versionToJson(item, req)).toList();

      return _okWithJson({
        'name': name,
        'latest': versionMaps.last, // TODO: Exclude pre release
        'versions': versionMaps,
      });
    });
  }
  // @Route.get('/api/packages/<name>')
  // Future<shelf.Response> getVersions(shelf.Request req, String name) async {
  //   return _handleRequestWithCaching(req, () async {
  //     var package = await metaStore.queryPackage(name);

  //     if (package == null) {
  //       return shelf.Response.found(
  //           Uri.parse(upstream).resolve('/api/packages/$name').toString());
  //     }

  //     package.versions.sort((a, b) {
  //       return semver.Version.prioritize(
  //           semver.Version.parse(a.version), semver.Version.parse(b.version));
  //     });

  //     var versionMaps = package.versions
  //         .map((item) => _versionToJson(item, req))
  //         .toList();

  //     return _okWithJson({
  //       'name': name,
  //       'latest': versionMaps.last, // TODO: Exclude pre release
  //       'versions': versionMaps,
  //     });
  //   });
  // }

  @Route.get('/api/packages/<name>/versions/<version>')
  Future<shelf.Response> getVersion(
      shelf.Request req, String name, String version) async {
    return _handleRequestWithCaching(req, () async {
      // Important: + -> %2B, should be decoded here
      try {
        version = Uri.decodeComponent(version);
      } catch (err) {
        print(err);
      }

      var package = await metaStore.queryPackage(name);
      if (package == null) {
        return shelf.Response.found(Uri.parse(upstream)
            .resolve('/api/packages/$name/versions/$version')
            .toString());
      }

      var packageVersion =
          package.versions.firstWhereOrNull((item) => item.version == version);
      if (packageVersion == null) {
        return shelf.Response.notFound('Not Found');
      }

      return _okWithJson(_versionToJson(packageVersion, req));
    });
  }

  @Route.get('/packages/<name>/versions/<version>.tar.gz')
  Future<shelf.Response> download(
      shelf.Request req, String name, String version) async {
    // Important: + -> %2B, should be decoded here
    try {
      version = Uri.decodeComponent(version);
    } catch (err) {
      print(err);
    }

    var package = await metaStore.queryPackage(name);

    // 如果本地没有包信息，尝试从上游获取
    if (package == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/packages/$name/versions/$version.tar.gz')
          .toString());
    }

    if (isPubClient(req)) {
      metaStore.increaseDownloads(name, version);
    }

    // 检查是否为 FileStore 并且支持缓存
    if (packageStore is FileStore) {
      final fileStore = packageStore as FileStore;

      // 检查是否有本地缓存文件
      bool hasCached = await fileStore.hasCachedFile(name, version);

      // 如果没有缓存，则从上游下载并缓存
      if (!hasCached) {
        bool downloadSuccess = await fileStore.downloadAndCache(name, version);
        // 如果下载失败且文件不存在，则尝试重定向到上游
        if (!downloadSuccess &&
            !(await fileStore.hasCachedFile(name, version))) {
          final upstreamUrl = Uri.parse(upstream)
              .resolve('/packages/$name/versions/$version.tar.gz')
              .toString();
          return shelf.Response.found(upstreamUrl);
        }
      }

      // 检查文件是否存在，如果存在则返回本地文件，否则重定向到上游
      if (await fileStore.hasCachedFile(name, version)) {
        return shelf.Response.ok(
          fileStore.download(name, version),
          headers: {HttpHeaders.contentTypeHeader: ContentType.binary.mimeType},
        );
      } else {
        final upstreamUrl = Uri.parse(upstream)
            .resolve('/packages/$name/versions/$version.tar.gz')
            .toString();
        return shelf.Response.found(upstreamUrl);
      }
    }

    // 非 FileStore 情况下的原有逻辑
    if (packageStore.supportsDownloadUrl) {
      return shelf.Response.found(
          await packageStore.downloadUrl(name, version));
    } else {
      return shelf.Response.ok(
        packageStore.download(name, version),
        headers: {HttpHeaders.contentTypeHeader: ContentType.binary.mimeType},
      );
    }
  }

  // @Route.get('/packages/<name>/versions/<version>.tar.gz')
  // Future<shelf.Response> download(
  //     shelf.Request req, String name, String version) async {
  //   // For binary files, we might want different caching strategy
  //   final cacheKey = _generateCacheKey(req);

  //   // Try to get from cache first
  //   final cachedResponse = await _getFromCache(cacheKey);
  //   if (cachedResponse != null && !cachedResponse.isExpired) {
  //     print('Serving download from cache: $cacheKey');
  //     return shelf.Response(
  //       cachedResponse.statusCode,
  //       body: cachedResponse.body,
  //       headers: {
  //         ...cachedResponse.headers,
  //         HttpHeaders.contentTypeHeader: ContentType.binary.mimeType,
  //       },
  //     );
  //   }

  //   var package = await metaStore.queryPackage(name);
  //   if (package == null) {
  //     return shelf.Response.found(Uri.parse(upstream)
  //         .resolve('/packages/$name/versions/$version.tar.gz')
  //         .toString());
  //   }

  //   if (isPubClient(req)) {
  //     metaStore.increaseDownloads(name, version);
  //   }

  //   shelf.Response response;
  //   if (packageStore.supportsDownloadUrl) {
  //     response =
  //         shelf.Response.found(await packageStore.downloadUrl(name, version));
  //   } else {
  //     response = shelf.Response.ok(
  //       packageStore.download(name, version),
  //       headers: {HttpHeaders.contentTypeHeader: ContentType.binary.mimeType},
  //     );
  //   }

  //   // Cache the response for future use
  //   Future.microtask(() => _saveToCache(cacheKey, response));

  //   return response;
  // }

  @Route.get('/api/packages/versions/new')
  Future<shelf.Response> getUploadUrl(shelf.Request req) async {
    return _okWithJson({
      'url': _resolveUrl(req, '/api/packages/versions/newUpload').toString(),
      'fields': {},
    });
  }

  @Route.post('/api/packages/versions/newUpload')
  Future<shelf.Response> upload(shelf.Request req) async {
    try {
      // var uploader = await _getUploaderEmail(req);
      var uploader = "";

      var contentType = req.headers['content-type'];
      if (contentType == null) throw 'invalid content type';

      var mediaType = MediaType.parse(contentType);
      var boundary = mediaType.parameters['boundary'];
      if (boundary == null) throw 'invalid boundary';

      var transformer = MimeMultipartTransformer(boundary);
      MimeMultipart? fileData;

      // The map below makes the runtime type checker happy.
      // https://github.com/dart-lang/pub-dev/blob/19033f8154ca1f597ef5495acbc84a2bb368f16d/app/lib/fake/server/fake_storage_server.dart#L74
      final stream = req.read().map((a) => a).transform(transformer);
      await for (var part in stream) {
        if (fileData != null) continue;
        fileData = part;
      }

      var bb = await fileData!.fold(
          BytesBuilder(), (BytesBuilder byteBuilder, d) => byteBuilder..add(d));
      var tarballBytes = bb.takeBytes();
      var tarBytes = GZipDecoder().decodeBytes(tarballBytes);
      var archive = TarDecoder().decodeBytes(tarBytes);
      ArchiveFile? pubspecArchiveFile;
      ArchiveFile? readmeFile;
      ArchiveFile? changelogFile;

      for (var file in archive.files) {
        if (file.name == 'pubspec.yaml') {
          pubspecArchiveFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'readme.md') {
          readmeFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'changelog.md') {
          changelogFile = file;
          continue;
        }
      }

      if (pubspecArchiveFile == null) {
        throw 'Did not find any pubspec.yaml file in upload. Aborting.';
      }

      var pubspecYaml = utf8.decode(pubspecArchiveFile.content);
      var pubspec = loadYamlAsMap(pubspecYaml)!;

      if (uploadValidator != null) {
        await uploadValidator!(pubspec, uploader);
      }

      // TODO: null
      var name = pubspec['name'] as String;
      var version = pubspec['version'] as String;

      var package = await metaStore.queryPackage(name);

      // Package already exists
      if (package != null) {
        if (package.private == false) {
          throw '$name is not a private package. Please upload it to https://pub.flutter-io.cn';
        }

        // Check uploaders
        if (package.uploaders?.contains(uploader) == false) {
          throw '$uploader is not an uploader of $name';
        }

        // Check duplicated version
        var duplicated = package.versions
            .firstWhereOrNull((item) => version == item.version);
        if (duplicated != null) {
          throw 'version invalid: $name@$version already exists.';
        }
      }

      // Upload package tarball to storage
      await packageStore.upload(name, version, tarballBytes);

      String? readme;
      String? changelog;
      if (readmeFile != null) {
        readme = utf8.decode(readmeFile.content);
      }
      if (changelogFile != null) {
        changelog = utf8.decode(changelogFile.content);
      }

      // Write package meta to database
      var unpubVersion = UnpubVersion(
        version,
        pubspec,
        pubspecYaml,
        uploader,
        readme,
        changelog,
        DateTime.now(),
      );
      await metaStore.addVersion(name, unpubVersion);

      // TODO: Upload docs
      return shelf.Response.found(
          _resolveUrl(req, '/api/packages/versions/newUploadFinish'));
    } catch (err) {
      return shelf.Response.found(_resolveUrl(
          req, '/api/packages/versions/newUploadFinish?error=$err'));
    }
  }

  @Route.get('/api/packages/versions/newUploadFinish')
  Future<shelf.Response> uploadFinish(shelf.Request req) async {
    var error = req.requestedUri.queryParameters['error'];
    if (error != null) {
      return _badRequest(error);
    }
    return _successMessage('Successfully uploaded package.');
  }

  @Route.post('/api/packages/<name>/uploaders')
  Future<shelf.Response> addUploader(shelf.Request req, String name) async {
    var body = await req.readAsString();
    var email = Uri.splitQueryString(body)['email']!; // TODO: null
    // var operatorEmail = await _getUploaderEmail(req);
    // var package = await metaStore.queryPackage(name);

    // if (package?.uploaders?.contains(operatorEmail) == false) {
    //   return _badRequest('no permission', status: HttpStatus.forbidden);
    // }
    // if (package?.uploaders?.contains(email) == true) {
    //   return _badRequest('email already exists');
    // }

    await metaStore.addUploader(name, email);
    return _successMessage('uploader added');
  }

  @Route.delete('/api/packages/<name>/uploaders/<email>')
  Future<shelf.Response> removeUploader(
      shelf.Request req, String name, String email) async {
    email = Uri.decodeComponent(email);
    // var operatorEmail = await _getUploaderEmail(req);
    // var package = await metaStore.queryPackage(name);

    // // TODO: null
    // if (package?.uploaders?.contains(operatorEmail) == false) {
    //   return _badRequest('no permission', status: HttpStatus.forbidden);
    // }
    // if (package?.uploaders?.contains(email) == false) {
    //   return _badRequest('email not uploader');
    // }

    await metaStore.removeUploader(name, email);
    return _successMessage('uploader removed');
  }

  @Route.get('/webapi/packages')
  Future<shelf.Response> getPackages(shelf.Request req) async {
    return _handleRequestWithCaching(req, () async {
      var params = req.requestedUri.queryParameters;
      var size = int.tryParse(params['size'] ?? '') ?? 10;
      var page = int.tryParse(params['page'] ?? '') ?? 0;
      var sort = params['sort'] ?? 'download';
      var q = params['q'];

      String? keyword;
      String? uploader;
      String? dependency;

      if (q == null) {
      } else if (q.startsWith('email:')) {
        uploader = q.substring(6).trim();
      } else if (q.startsWith('dependency:')) {
        dependency = q.substring(11).trim();
      } else {
        keyword = q;
      }

      final result = await metaStore.queryPackages(
        size: size,
        page: page,
        sort: sort,
        keyword: keyword,
        uploader: uploader,
        dependency: dependency,
      );

      var data = ListApi(result.count, [
        for (var package in result.packages)
          ListApiPackage(
            package.name,
            package.versions.last.pubspec['description'] as String?,
            getPackageTags(package.versions.last.pubspec),
            package.versions.last.version,
            package.updatedAt,
          )
      ]);

      return _okWithJson({'data': data.toJson()});
    });
  }

  @Route.get('/packages/<name>.json')
  Future<shelf.Response> getPackageVersions(
      shelf.Request req, String name) async {
    return _handleRequestWithCaching(req, () async {
      var package = await metaStore.queryPackage(name);
      if (package == null) {
        return _badRequest('package not exists', status: HttpStatus.notFound);
      }

      var versions = package.versions.map((v) => v.version).toList();
      versions.sort((a, b) {
        return semver.Version.prioritize(
            semver.Version.parse(b), semver.Version.parse(a));
      });

      return _okWithJson({
        'name': name,
        'versions': versions,
      });
    });
  }

  @Route.get('/webapi/package/<name>/<version>')
  Future<shelf.Response> getPackageDetail(
      shelf.Request req, String name, String version) async {
    return _handleRequestWithCaching(req, () async {
      var package = await metaStore.queryPackage(name);
      if (package == null) {
        return _okWithJson({'error': 'package not exists'});
      }

      UnpubVersion? packageVersion;
      if (version == 'latest') {
        packageVersion = package.versions.last;
      } else {
        packageVersion = package.versions
            .firstWhereOrNull((item) => item.version == version);
      }
      if (packageVersion == null) {
        return _okWithJson({'error': 'version not exists'});
      }

      var versions = package.versions
          .map((v) => DetailViewVersion(v.version, v.createdAt))
          .toList();
      versions.sort((a, b) {
        return semver.Version.prioritize(
            semver.Version.parse(b.version), semver.Version.parse(a.version));
      });

      var pubspec = packageVersion.pubspec;
      List<String?> authors;
      if (pubspec['author'] != null) {
        authors = RegExp(r'<(.*?)>')
            .allMatches(pubspec['author'])
            .map((match) => match.group(1))
            .toList();
      } else if (pubspec['authors'] != null) {
        authors = (pubspec['authors'] as List)
            .map((author) => RegExp(r'<(.*?)>').firstMatch(author)!.group(1))
            .toList();
      } else {
        authors = [];
      }

      var depMap =
          (pubspec['dependencies'] as Map? ?? {}).cast<String, String>();

      var data = WebapiDetailView(
        package.name,
        packageVersion.version,
        packageVersion.pubspec['description'] ?? '',
        packageVersion.pubspec['homepage'] ?? '',
        package.uploaders ?? [],
        packageVersion.createdAt,
        packageVersion.readme,
        packageVersion.changelog,
        versions,
        authors,
        depMap.keys.toList(),
        getPackageTags(packageVersion.pubspec),
      );

      return _okWithJson({'data': data.toJson()});
    });
  }

  @Route.get('/')
  @Route.get('/packages')
  @Route.get('/packages/<name>')
  @Route.get('/packages/<name>/versions/<version>')
  Future<shelf.Response> indexHtml(shelf.Request req) async {
    return shelf.Response.ok(index_html.content,
        headers: {HttpHeaders.contentTypeHeader: ContentType.html.mimeType});
  }

  @Route.get('/main.dart.js')
  Future<shelf.Response> mainDartJs(shelf.Request req) async {
    return shelf.Response.ok(main_dart_js.content,
        headers: {HttpHeaders.contentTypeHeader: 'text/javascript'});
  }

  String _getBadgeUrl(String label, String message, String color,
      Map<String, String> queryParameters) {
    var badgeUri = Uri.parse('https://img.shields.io/static/v1');
    return Uri(
        scheme: badgeUri.scheme,
        host: badgeUri.host,
        path: badgeUri.path,
        queryParameters: {
          'label': label,
          'message': message,
          'color': color,
          ...queryParameters,
        }).toString();
  }

  @Route.get('/badge/<type>/<name>')
  Future<shelf.Response> badge(
      shelf.Request req, String type, String name) async {
    var queryParameters = req.requestedUri.queryParameters;
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.notFound('Not found');
    }

    switch (type) {
      case 'v':
        var latest = semver.Version.primary(package.versions
            .map((pv) => semver.Version.parse(pv.version))
            .toList());

        var color = latest.major == 0 ? 'orange' : 'blue';

        return shelf.Response.found(
            _getBadgeUrl('unpub', latest.toString(), color, queryParameters));
      case 'd':
        return shelf.Response.found(_getBadgeUrl(
            'downloads', package.download.toString(), 'blue', queryParameters));
      default:
        return shelf.Response.notFound('Not found');
    }
  }
}
