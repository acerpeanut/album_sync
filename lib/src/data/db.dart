import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

enum TaskStatus { queued, running, paused, failed, done }

class UploadTask {
  final int? id;
  final String assetId;
  final String albumTitle;
  final String remotePath; // path under base URL, starts with '/'
  final int bytesTotal;
  final int bytesSent;
  final TaskStatus status;
  final int retries;
  final String? lastError;
  final int priority;

  const UploadTask({
    this.id,
    required this.assetId,
    required this.albumTitle,
    required this.remotePath,
    required this.bytesTotal,
    this.bytesSent = 0,
    this.status = TaskStatus.queued,
    this.retries = 0,
    this.lastError,
    this.priority = 0,
  });

  UploadTask copyWith({
    int? id,
    String? assetId,
    String? albumTitle,
    String? remotePath,
    int? bytesTotal,
    int? bytesSent,
    TaskStatus? status,
    int? retries,
    String? lastError,
    int? priority,
  }) {
    return UploadTask(
      id: id ?? this.id,
      assetId: assetId ?? this.assetId,
      albumTitle: albumTitle ?? this.albumTitle,
      remotePath: remotePath ?? this.remotePath,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      bytesSent: bytesSent ?? this.bytesSent,
      status: status ?? this.status,
      retries: retries ?? this.retries,
      lastError: lastError ?? this.lastError,
      priority: priority ?? this.priority,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'assetId': assetId,
        'albumTitle': albumTitle,
        'remotePath': remotePath,
        'bytesTotal': bytesTotal,
        'bytesSent': bytesSent,
        'status': status.name,
        'retries': retries,
        'lastError': lastError,
        'priority': priority,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };

  static UploadTask fromMap(Map<String, Object?> m) {
    return UploadTask(
      id: m['id'] as int?,
      assetId: m['assetId'] as String,
      albumTitle: m['albumTitle'] as String,
      remotePath: m['remotePath'] as String,
      bytesTotal: m['bytesTotal'] as int,
      bytesSent: m['bytesSent'] as int,
      status: TaskStatus.values.firstWhere(
          (e) => e.name == (m['status'] as String? ?? 'queued')),
      retries: m['retries'] as int? ?? 0,
      lastError: m['lastError'] as String?,
      priority: m['priority'] as int? ?? 0,
    );
  }
}

class AppDatabase {
  static Database? _db;

  static Future<Database> instance() async {
    if (_db != null) return _db!;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'album_sync.db');
    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE upload_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  assetId TEXT NOT NULL,
  albumTitle TEXT NOT NULL,
  remotePath TEXT NOT NULL,
  bytesTotal INTEGER NOT NULL,
  bytesSent INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  retries INTEGER NOT NULL DEFAULT 0,
  lastError TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  updatedAt INTEGER
);
CREATE INDEX idx_tasks_status ON upload_tasks(status);
CREATE INDEX idx_tasks_asset ON upload_tasks(assetId);
CREATE UNIQUE INDEX idx_tasks_unique ON upload_tasks(assetId, remotePath);
CREATE INDEX idx_tasks_updatedAt ON upload_tasks(updatedAt);
''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Remove duplicates before adding unique index to avoid constraint failure
          await db.execute(
              'DELETE FROM upload_tasks WHERE id NOT IN (SELECT MIN(id) FROM upload_tasks GROUP BY assetId, remotePath)');
          await db.execute(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_unique ON upload_tasks(assetId, remotePath)');
          // Reset any stale running tasks to queued
          await db.update('upload_tasks', {'status': TaskStatus.queued.name},
              where: 'status = ?', whereArgs: [TaskStatus.running.name]);
        }
        if (oldVersion < 3) {
          try { await db.execute('ALTER TABLE upload_tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0'); } catch (_) {}
          await db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_updatedAt ON upload_tasks(updatedAt)');
        }
      },
    );
    return _db!;
  }

  static Future<void> clearAll() async {
    final db = await instance();
    await db.delete('upload_tasks');
  }

  static Future<int> insertTask(UploadTask t) async {
    final db = await instance();
    return db.insert('upload_tasks', t.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> insertTasks(List<UploadTask> items) async {
    final db = await instance();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final t in items) {
        batch.insert('upload_tasks', t.toMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<List<UploadTask>> nextQueued(int limit) async {
    final db = await instance();
    final rows = await db.query('upload_tasks',
        where: 'status = ?',
        whereArgs: [TaskStatus.queued.name],
        orderBy: 'priority DESC, id ASC',
        limit: limit);
    return rows.map(UploadTask.fromMap).toList();
  }

  static Future<UploadTask?> claimNextQueued() async {
    final db = await instance();
    return await db.transaction<UploadTask?>((txn) async {
      final rows = await txn.query('upload_tasks',
          where: 'status = ?',
          whereArgs: [TaskStatus.queued.name],
          orderBy: 'priority DESC, id ASC',
          limit: 1);
      if (rows.isEmpty) return null;
      final id = rows.first['id'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      final updated = await txn.update(
        'upload_tasks',
        {'status': TaskStatus.running.name, 'updatedAt': now},
        where: 'id = ? AND status = ?',
        whereArgs: [id, TaskStatus.queued.name],
      );
      if (updated == 1) {
        final claimed = Map<String, Object?>.from(rows.first);
        claimed['status'] = TaskStatus.running.name;
        claimed['updatedAt'] = now;
        return UploadTask.fromMap(claimed);
      }
      return null;
    });
  }

  static Future<void> updateProgress(int id, int bytesSent, TaskStatus status,
      {String? lastError}) async {
    final db = await instance();
    await db.update(
      'upload_tasks',
      {
        'bytesSent': bytesSent,
        'status': status.name,
        'lastError': lastError,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateStatus(int id, TaskStatus status,
      {int? retries, String? lastError, int? priority}) async {
    final db = await instance();
    await db.update(
      'upload_tasks',
      {
        'status': status.name,
        if (retries != null) 'retries': retries,
        if (lastError != null) 'lastError': lastError,
        if (priority != null) 'priority': priority,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateTotalBytes(int id, int bytesTotal) async {
    final db = await instance();
    await db.update(
      'upload_tasks',
      {
        'bytesTotal': bytesTotal,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<Map<String, int>> stats() async {
    final db = await instance();
    Future<int> cnt(TaskStatus s) async {
      final x = Sqflite.firstIntValue(await db.rawQuery(
              'SELECT COUNT(*) FROM upload_tasks WHERE status = ?',
              [s.name])) ??
          0;
      return x;
    }

    final done = await cnt(TaskStatus.done);
    final failed = await cnt(TaskStatus.failed);
    final running = await cnt(TaskStatus.running);
    final queued = await cnt(TaskStatus.queued);
    return {
      'done': done,
      'failed': failed,
      'running': running,
      'queued': queued,
    };
  }

  static Future<int> cleanupQueuedDuplicates() async {
    final db = await instance();
    return await db.delete(
      'upload_tasks',
      where:
          "status = ? AND id NOT IN (SELECT MIN(id) FROM upload_tasks WHERE status = ? GROUP BY assetId, remotePath)",
      whereArgs: [TaskStatus.queued.name, TaskStatus.queued.name],
    );
  }

  static Future<void> resetRunningToQueued() async {
    final db = await instance();
    await db.update('upload_tasks', {'status': TaskStatus.queued.name},
        where: 'status = ?', whereArgs: [TaskStatus.running.name]);
  }

  static Future<Set<String>> existingAssetIds({
    bool includeQueued = true,
    bool includeRunning = true,
    bool includeDone = true,
  }) async {
    final db = await instance();
    final statuses = <String>[];
    if (includeQueued) statuses.add(TaskStatus.queued.name);
    if (includeRunning) statuses.add(TaskStatus.running.name);
    if (includeDone) statuses.add(TaskStatus.done.name);
    if (statuses.isEmpty) return <String>{};
    final placeholders = List.filled(statuses.length, '?').join(',');
    final rows = await db.query('upload_tasks',
        columns: ['assetId'],
        where: 'status IN ($placeholders)',
        whereArgs: statuses);
    return rows.map((e) => e['assetId'] as String).toSet();
  }

  // Return existing pairs as composite keys: "assetId|remotePath" for selected statuses.
  static Future<Set<String>> existingAssetRemotePairs({
    bool includeQueued = true,
    bool includeRunning = true,
    bool includeDone = true,
  }) async {
    final db = await instance();
    final statuses = <String>[];
    if (includeQueued) statuses.add(TaskStatus.queued.name);
    if (includeRunning) statuses.add(TaskStatus.running.name);
    if (includeDone) statuses.add(TaskStatus.done.name);
    if (statuses.isEmpty) return <String>{};
    final placeholders = List.filled(statuses.length, '?').join(',');
    final rows = await db.query('upload_tasks',
        columns: ['assetId', 'remotePath'],
        where: 'status IN ($placeholders)',
        whereArgs: statuses);
    return rows
        .map((e) => '${e['assetId'] as String}|${e['remotePath'] as String}')
        .toSet();
  }

  // --- Failures & queue management ---
  static Future<List<UploadTask>> listFailed({int limit = 200}) async {
    final db = await instance();
    final rows = await db.query('upload_tasks',
        where: 'status = ?',
        whereArgs: [TaskStatus.failed.name],
        orderBy: 'updatedAt DESC',
        limit: limit);
    return rows.map(UploadTask.fromMap).toList();
  }

  static Future<void> requeueTask(int id) async {
    final db = await instance();
    await db.update('upload_tasks',
        {
          'status': TaskStatus.queued.name,
          'bytesSent': 0,
          'lastError': null,
          'retries': 0,
          'priority': 0,
          'updatedAt': DateTime.now().millisecondsSinceEpoch
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  static Future<void> deleteTask(int id) async {
    final db = await instance();
    await db.delete('upload_tasks', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> updateRemotePath(int id, String newRemotePath) async {
    final db = await instance();
    await db.update(
      'upload_tasks',
      {
        'remotePath': newRemotePath,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<List<UploadTask>> listByStatus(TaskStatus status, {int limit = 200}) async {
    final db = await instance();
    final rows = await db.query('upload_tasks',
        where: 'status = ?',
        whereArgs: [status.name],
        orderBy: 'id ASC',
        limit: limit);
    return rows.map(UploadTask.fromMap).toList();
  }

  // Repair remotePath that mistakenly encodes '/' as %2F within a segment.
  // Only touches queued/running/failed tasks to avoid breaking done links.
  static Future<int> repairRemotePaths() async {
    final db = await instance();
    final rows = await db.query(
      'upload_tasks',
      columns: ['id', 'remotePath', 'status'],
      where:
          "(status IN (?, ?, ?)) AND remotePath LIKE ?",
      whereArgs: [
        TaskStatus.queued.name,
        TaskStatus.running.name,
        TaskStatus.failed.name,
        '%25%2F%', // contains %2F
      ],
      orderBy: 'id ASC',
    );
    int updated = 0;
    await db.transaction((txn) async {
      for (final m in rows) {
        final id = m['id'] as int;
        final rp = m['remotePath'] as String;
        final fixed = _reencodePath(rp);
        if (fixed != rp) {
          await txn.update('upload_tasks', {'remotePath': fixed}, where: 'id = ?', whereArgs: [id]);
          updated++;
        }
      }
    });
    return updated;
  }

  static String _reencodePath(String remotePath) {
    // Decode whole then split and re-encode by segment
    final decoded = Uri.decodeComponent(remotePath);
    final segs = decoded.split('/').where((e) => e.isNotEmpty).toList();
    final re = segs.map(Uri.encodeComponent).join('/');
    return '/$re';
  }
}
