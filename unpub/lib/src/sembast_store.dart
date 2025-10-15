import 'package:sembast/sembast.dart';
import 'package:intl/intl.dart';
import 'package:unpub/src/models.dart';
import 'meta_store.dart';

class SembastStore extends MetaStore {
  final Database _db;
  final StoreRef<String, Map<String, dynamic>> _packageStore;
  final StoreRef<String, Map<String, dynamic>> _statsStore;

  SembastStore(this._db)
      : _packageStore = StoreRef<String, Map<String, dynamic>>('packages'),
        _statsStore = StoreRef<String, Map<String, dynamic>>('stats');

  @override
  Future<UnpubPackage?> queryPackage(String name) async {
    final record = await _packageStore.record(name).get(_db);
    if (record == null) return null;
    return UnpubPackage.fromJson(record);
  }

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    await _db.transaction((txn) async {
      final record = _packageStore.record(name);
      var package = await record.get(txn) ??
          {
            'name': name,
            'versions': [],
            'uploaders': [],
            'private': true,
            'download': 0,
            'createdAt': version.createdAt.toIso8601String(),
          };

      // Create new lists with the added elements
      final newVersions = List<Map<String, dynamic>>.from(package['versions'])
        ..add(version.toJson());
      final newUploaders = List<String>.from(package['uploaders'])
        ..add(version.uploader ?? "");

      // Update package
      await record.put(txn, {
        ...package,
        'versions': newVersions,
        'uploaders': newUploaders,
        'updatedAt': version.createdAt.toIso8601String(),
      });
    });
  }

  @override
  Future<void> addUploader(String name, String email) async {
    await _db.transaction((txn) async {
      final record = _packageStore.record(name);
      var package = await record.get(txn);
      if (package == null) return;

      final newUploaders = List<String>.from(package['uploaders'])..add(email);

      await record.put(txn, {
        ...package,
        'uploaders': newUploaders,
      });
    });
  }

  @override
  Future<void> removeUploader(String name, String email) async {
    await _db.transaction((txn) async {
      final record = _packageStore.record(name);
      var package = await record.get(txn);
      if (package == null) return;

      final newUploaders = List<String>.from(package['uploaders'])
        ..remove(email);

      await record.put(txn, {
        ...package,
        'uploaders': newUploaders,
      });
    });
  }

  @override
  Future<void> increaseDownloads(String name, String version) async {
    final today = DateFormat('yyyyMMdd').format(DateTime.now());

    await _db.transaction((txn) async {
      // Update package download count
      final packageRecord = _packageStore.record(name);
      var package = await packageRecord.get(txn);
      if (package != null) {
        await packageRecord.put(txn, {
          ...package,
          'download': (package['download'] as int) + 1,
        });
      }

      // Update daily stats
      final statsRecord = _statsStore.record(name);
      var stats = await statsRecord.get(txn) ?? {};
      await statsRecord.put(txn, {
        ...stats,
        'd$today': (stats['d$today'] as int? ?? 0) + 1,
      });
    });
  }

  @override
  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
  }) async {
    // 构建基础Finder用于分页和排序
    final baseFinder = Finder(
      offset: page * size,
      limit: size,
      sortOrders: [SortOrder(sort, false)],
    );

    // 构建过滤器列表
    final filters = <Filter>[];

    if (keyword != null) {
      filters.add(Filter.matches('name', keyword));
    }

    if (uploader != null) {
      filters.add(Filter.equals('uploaders', uploader));
    }

    if (dependency != null) {
      filters.add(Filter.custom((record) {
        final versions = record['versions'] as List?;
        if (versions == null) return false;
        return versions.any((v) {
          final deps = (v['pubspec']?['dependencies'] as Map?) ?? {};
          return deps.containsKey(dependency);
        });
      }));
    }

    // 组合最终的Finder
    final finder = filters.isEmpty
        ? baseFinder
        : Finder(
            offset: page * size,
            limit: size,
            sortOrders: [SortOrder(sort, false)],
            filter: filters.length == 1 ? filters.first : Filter.and(filters),
          );

    // 使用查询计数和获取记录
    final query = _packageStore.query(
      finder: finder,
    );

    // 获取总数
    final count = await query.count(_db);

    // 获取记录
    final records = await query.getSnapshots(_db);

    // 转换为Package对象
    final packages = records.map((snapshot) {
      return UnpubPackage.fromJson(snapshot.value);
    }).toList();

    return UnpubQueryResult(count, packages);
  }
}
