// VMQStore.m
// SQLite 队列 + 日志实现。使用 libsqlite3 C API，预编译语句，避免注入。

#import "VMQStore.h"
#import "VMQProtocol.h"
#import <sqlite3.h>

@implementation VMQStore {
    sqlite3 *_db;
    NSString *_dbPath;
}

+ (instancetype)sharedStore {
    static VMQStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VMQStore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _db = NULL;
        _dbPath = @VMQ_QUEUE_DB; // 队列与日志同库不同表，简化事务
    }
    return self;
}

- (BOOL)open {
    if (_db) return YES;

    // 确保数据目录存在且 0700
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = @VMQ_DATA_DIR;
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @(0700)}
                            error:nil];
    }

    if (sqlite3_open([_dbPath fileSystemRepresentation], &_db) != SQLITE_OK) {
        _db = NULL;
        return NO;
    }
    sqlite3_exec(_db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);
    sqlite3_exec(_db, "PRAGMA busy_timeout=3000;", NULL, NULL, NULL);

    const char *schema =
        "CREATE TABLE IF NOT EXISTS queue ("
        " rowid INTEGER PRIMARY KEY AUTOINCREMENT,"
        " eventId TEXT UNIQUE NOT NULL,"
        " channelType INTEGER NOT NULL,"
        " amount TEXT NOT NULL,"
        " eventTime INTEGER NOT NULL,"
        " state INTEGER NOT NULL DEFAULT 0,"
        " attempts INTEGER NOT NULL DEFAULT 0,"
        " lastError TEXT,"
        " createdAt INTEGER NOT NULL,"
        " updatedAt INTEGER NOT NULL);"
        "CREATE TABLE IF NOT EXISTS logs ("
        " rowid INTEGER PRIMARY KEY AUTOINCREMENT,"
        " ts INTEGER NOT NULL,"
        " level INTEGER NOT NULL,"
        " category INTEGER NOT NULL,"
        " message TEXT NOT NULL);";
    char *err = NULL;
    if (sqlite3_exec(_db, schema, NULL, NULL, &err) != SQLITE_OK) {
        if (err) sqlite3_free(err);
        return NO;
    }

    // 权限 0600
    [fm setAttributes:@{NSFilePosixPermissions: @(0600)}
         ofItemAtPath:_dbPath error:nil];
    return YES;
}

- (void)close {
    if (_db) { sqlite3_close(_db); _db = NULL; }
}

static int64_t nowSec(void) { return (int64_t)[[NSDate date] timeIntervalSince1970]; }

#pragma mark - 队列

- (BOOL)enqueueEvent:(VMQEvent *)event {
    if (!_db || event.eventId.length == 0 || event.normalizedAmount.length == 0) return NO;
    const char *sql =
        "INSERT OR IGNORE INTO queue"
        "(eventId,channelType,amount,eventTime,state,attempts,createdAt,updatedAt)"
        " VALUES(?,?,?,?,0,0,?,?);";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &st, NULL) != SQLITE_OK) return NO;
    int64_t t = nowSec();
    sqlite3_bind_text(st, 1, event.eventId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, (int)event.channelType);
    sqlite3_bind_text(st, 3, event.normalizedAmount.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 4, (int64_t)event.eventTime);
    sqlite3_bind_int64(st, 5, t);
    sqlite3_bind_int64(st, 6, t);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return NO;
    return sqlite3_changes(_db) > 0; // 0 表示被去重忽略
}

- (NSArray<NSDictionary *> *)claimPendingBatch:(NSInteger)limit {
    if (!_db) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    const char *sel =
        "SELECT rowid,eventId,channelType,amount,eventTime,attempts"
        " FROM queue WHERE state=0 ORDER BY rowid ASC LIMIT ?;";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(_db, sel, -1, &st, NULL) != SQLITE_OK) return @[];
    sqlite3_bind_int(st, 1, (int)limit);
    while (sqlite3_step(st) == SQLITE_ROW) {
        int64_t rowid = sqlite3_column_int64(st, 0);
        const unsigned char *eid = sqlite3_column_text(st, 1);
        int ch = sqlite3_column_int(st, 2);
        const unsigned char *amt = sqlite3_column_text(st, 3);
        int64_t et = sqlite3_column_int64(st, 4);
        int attempts = sqlite3_column_int(st, 5);
        [rows addObject:@{
            @"rowid": @(rowid),
            @"eventId": eid ? @((const char *)eid) : @"",
            @"channelType": @(ch),
            @"amount": amt ? @((const char *)amt) : @"",
            @"eventTime": @(et),
            @"attempts": @(attempts),
        }];
    }
    sqlite3_finalize(st);

    // 置为 sending
    for (NSDictionary *r in rows) {
        const char *upd = "UPDATE queue SET state=1,updatedAt=? WHERE rowid=?;";
        sqlite3_stmt *u = NULL;
        if (sqlite3_prepare_v2(_db, upd, -1, &u, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(u, 1, nowSec());
            sqlite3_bind_int64(u, 2, [r[@"rowid"] longLongValue]);
            sqlite3_step(u);
            sqlite3_finalize(u);
        }
    }
    return rows;
}

- (void)updateState:(int64_t)rowid to:(int)state error:(NSString *)err bumpAttempt:(BOOL)bump {
    if (!_db) return;
    NSString *sql = bump
        ? @"UPDATE queue SET state=?,attempts=attempts+1,lastError=?,updatedAt=? WHERE rowid=?;"
        : @"UPDATE queue SET state=?,lastError=?,updatedAt=? WHERE rowid=?;";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(_db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) return;
    sqlite3_bind_int(st, 1, state);
    sqlite3_bind_text(st, 2, (err ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, nowSec());
    sqlite3_bind_int64(st, 4, rowid);
    sqlite3_step(st);
    sqlite3_finalize(st);
}

- (void)markDone:(int64_t)rowid { [self updateState:rowid to:2 error:nil bumpAttempt:NO]; }
- (void)markPending:(int64_t)rowid { [self updateState:rowid to:0 error:nil bumpAttempt:YES]; }
- (void)markPaused:(int64_t)rowid reason:(NSString *)reason { [self updateState:rowid to:3 error:reason bumpAttempt:NO]; }

- (void)recoverSending {
    if (!_db) return;
    sqlite3_exec(_db, "UPDATE queue SET state=0 WHERE state=1;", NULL, NULL, NULL);
}

- (NSInteger)pendingCount {
    if (!_db) return 0;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(_db, "SELECT COUNT(*) FROM queue WHERE state IN (0,1);", -1, &st, NULL) != SQLITE_OK)
        return 0;
    NSInteger n = 0;
    if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
    return n;
}

- (void)pruneDoneOlderThanDays:(NSInteger)days {
    if (!_db) return;
    int64_t cutoff = nowSec() - (int64_t)days * 86400;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(_db, "DELETE FROM queue WHERE state=2 AND updatedAt<?;", -1, &st, NULL) != SQLITE_OK)
        return;
    sqlite3_bind_int64(st, 1, cutoff);
    sqlite3_step(st);
    sqlite3_finalize(st);
}

#pragma mark - 日志

- (void)log:(VMQLogLevel)level category:(VMQLogCategory)category message:(NSString *)message {
    if (!_db || message.length == 0) return;
    const char *sql = "INSERT INTO logs(ts,level,category,message) VALUES(?,?,?,?);";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &st, NULL) != SQLITE_OK) return;
    sqlite3_bind_int64(st, 1, nowSec());
    sqlite3_bind_int(st, 2, (int)level);
    sqlite3_bind_int(st, 3, (int)category);
    sqlite3_bind_text(st, 4, message.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(st);
    sqlite3_finalize(st);
}

- (NSArray<NSDictionary *> *)readLogsCategory:(NSInteger)category limit:(NSInteger)limit {
    if (!_db) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    NSString *sql = category < 0
        ? @"SELECT ts,level,category,message FROM logs ORDER BY rowid DESC LIMIT ?;"
        : @"SELECT ts,level,category,message FROM logs WHERE category=? ORDER BY rowid DESC LIMIT ?;";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(_db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) return @[];
    if (category < 0) {
        sqlite3_bind_int(st, 1, (int)limit);
    } else {
        sqlite3_bind_int(st, 1, (int)category);
        sqlite3_bind_int(st, 2, (int)limit);
    }
    while (sqlite3_step(st) == SQLITE_ROW) {
        [rows addObject:@{
            @"ts": @(sqlite3_column_int64(st, 0)),
            @"level": @(sqlite3_column_int(st, 1)),
            @"category": @(sqlite3_column_int(st, 2)),
            @"message": @((const char *)sqlite3_column_text(st, 3) ?: ""),
        }];
    }
    sqlite3_finalize(st);
    return rows;
}

- (void)pruneLogsKeepDays:(NSInteger)days maxBytes:(NSInteger)maxBytes {
    if (!_db) return;
    // 时间维度
    int64_t cutoff = nowSec() - (int64_t)days * 86400;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(_db, "DELETE FROM logs WHERE ts<?;", -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(st, 1, cutoff);
        sqlite3_step(st);
        sqlite3_finalize(st);
    }
    // 容量维度：估算总字节，超限则按最旧批量删除
    sqlite3_stmt *sz = NULL;
    if (sqlite3_prepare_v2(_db, "SELECT COALESCE(SUM(LENGTH(message))+COUNT(*)*24,0) FROM logs;", -1, &sz, NULL) == SQLITE_OK) {
        int64_t bytes = 0;
        if (sqlite3_step(sz) == SQLITE_ROW) bytes = sqlite3_column_int64(sz, 0);
        sqlite3_finalize(sz);
        if (bytes > maxBytes) {
            // 删除最旧的 20%
            sqlite3_exec(_db,
                "DELETE FROM logs WHERE rowid IN (SELECT rowid FROM logs ORDER BY rowid ASC "
                "LIMIT (SELECT MAX(1,COUNT(*)/5) FROM logs));",
                NULL, NULL, NULL);
        }
    }
}

- (void)clearLogs {
    if (!_db) return;
    sqlite3_exec(_db, "DELETE FROM logs;", NULL, NULL, NULL);
}

@end
