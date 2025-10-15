import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as path;
import 'package:intl/intl.dart';
import 'package:unpub/src/models.dart';
import 'meta_store.dart';

class SqliteStore extends MetaStore {
  static const _packageTable = 'packages';
  static const _versionTable = 'package_versions';
  static const _uploaderTable = 'package_uploaders';
  static const _dailyStatsTable = 'daily_stats';
  
  final Database _db;

  SqliteStore(String dbPath) : _db = sqlite3.open(path.join(dbPath, 'unpub.db')) {
    _initializeDatabase();
  }

  void _initializeDatabase() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS $_packageTable (
        name TEXT PRIMARY KEY,
        private INTEGER DEFAULT 1,
        download_count INTEGER DEFAULT 0,
        created_at TEXT,
        updated_at TEXT
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS $_versionTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        package_name TEXT,
        version_json TEXT,
        created_at TEXT,
        FOREIGN KEY (package_name) REFERENCES $_packageTable(name) ON DELETE CASCADE
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS $_uploaderTable (
        package_name TEXT,
        email TEXT,
        PRIMARY KEY (package_name, email),
        FOREIGN KEY (package_name) REFERENCES $_packageTable(name) ON DELETE CASCADE
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS $_dailyStatsTable (
        package_name TEXT,
        date TEXT,
        count INTEGER DEFAULT 0,
        PRIMARY KEY (package_name, date),
        FOREIGN KEY (package_name) REFERENCES $_packageTable(name) ON DELETE CASCADE
      )
    ''');
  }

  @override
  Future<UnpubPackage?> queryPackage(String name) async {
  // Get package info
  final packageStmt = _db.prepare('''
    SELECT * FROM $_packageTable WHERE name = ?
  ''');
  final packageRow = packageStmt.select([name]).firstOrNull;
  packageStmt.dispose();
  
  if (packageRow == null) return null;
  
  // Get versions
  final versionStmt = _db.prepare('''
    SELECT version_json FROM $_versionTable 
    WHERE package_name = ? 
    ORDER BY created_at DESC
  ''');
  final versions = versionStmt.select([name])
    .map((row) => UnpubVersion.fromJson(row['version_json']))
    .toList();
  versionStmt.dispose();
  
  // Get uploaders
  final uploaderStmt = _db.prepare('''
    SELECT email FROM $_uploaderTable WHERE package_name = ?
  ''');
  final uploaders = uploaderStmt.select([name])
    .map((row) => row['email'] as String)
    .toList();
  uploaderStmt.dispose();
  
  return UnpubPackage(
    name,
    versions,
    packageRow['private'] == 1,
    uploaders,
    DateTime.parse(packageRow['created_at'] as String),
    DateTime.parse(packageRow['updated_at'] as String),
    packageRow['download_count'] as int,
  );
  }

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    _db.execute('BEGIN TRANSACTION');
    try {
      // Insert or ignore package
      _db.execute('''
        INSERT OR IGNORE INTO $_packageTable 
        (name, private, download_count, created_at, updated_at)
        VALUES (?, 1, 0, ?, ?)
      ''', [name, version.createdAt.toIso8601String(), version.createdAt.toIso8601String()]);
      
      // Update package timestamp
      _db.execute('''
        UPDATE $_packageTable 
        SET updated_at = ? 
        WHERE name = ?
      ''', [version.createdAt.toIso8601String(), name]);
      
      // Add version
      _db.execute('''
        INSERT INTO $_versionTable 
        (package_name, version_json, created_at)
        VALUES (?, ?, ?)
      ''', [name, version.toJson(), version.createdAt.toIso8601String()]);
      
      // Add uploader
      _db.execute('''
        INSERT OR IGNORE INTO $_uploaderTable 
        (package_name, email)
        VALUES (?, ?)
      ''', [name, version.uploader]);
      
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> addUploader(String name, String email) async {
    _db.execute('''
      INSERT OR IGNORE INTO $_uploaderTable (package_name, email)
      VALUES (?, ?)
    ''', [name, email]);
  }

  @override
  Future<void> removeUploader(String name, String email) async {
    _db.execute('''
      DELETE FROM $_uploaderTable 
      WHERE package_name = ? AND email = ?
    ''', [name, email]);
  }

  @override
  Future<void> increaseDownloads(String name, String version) async {
    final today = DateFormat('yyyyMMdd').format(DateTime.now());
    
    _db.execute('BEGIN TRANSACTION');
    try {
      // Update total download count
      _db.execute('''
        UPDATE $_packageTable 
        SET download_count = download_count + 1 
        WHERE name = ?
      ''', [name]);
      
      // Update daily stats
      _db.execute('''
        INSERT INTO $_dailyStatsTable (package_name, date, count)
        VALUES (?, ?, 1)
        ON CONFLICT(package_name, date) DO UPDATE SET count = count + 1
      ''', [name, today]);
      
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
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
    // Build query
    var query = 'SELECT p.* FROM $_packageTable p';
    final whereClauses = <String>[];
    final params = <dynamic>[];
    
    if (keyword != null) {
      whereClauses.add('p.name LIKE ?');
      params.add('%$keyword%');
    }
    
    if (uploader != null) {
      query += ' JOIN $_uploaderTable u ON p.name = u.package_name';
      whereClauses.add('u.email = ?');
      params.add(uploader);
    }
    
    if (dependency != null) {
      query += ' JOIN $_versionTable v ON p.name = v.package_name';
      whereClauses.add('v.version_json LIKE ?');
      params.add('%$dependency%');
    }
    
    if (whereClauses.isNotEmpty) {
      query += ' WHERE ${whereClauses.join(' AND ')}';
    }
    
    // Get count
    final countStmt = _db.prepare('SELECT COUNT(*) as count FROM ($query)');
    final count = countStmt.select(params).first['count'] as int;
    countStmt.dispose();
    
    // Add sorting and pagination
    query += ' ORDER BY p.$sort DESC LIMIT ? OFFSET ?';
    params.addAll([size, page * size]);
    
    // Execute query
    final stmt = _db.prepare(query);
    final packageRows = stmt.select(params);
    final packages = <UnpubPackage>[];
    
    for (final row in packageRows) {
      final package = await queryPackage(row['name'] as String);
      if (package != null) {
        packages.add(package);
      }
    }
    
    stmt.dispose();
    return UnpubQueryResult(count, packages);
  }

  void close() {
    _db.dispose();
  }
}