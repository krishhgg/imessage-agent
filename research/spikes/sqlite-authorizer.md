# SQLite authorizer check for ATTACH

Date: 2026-11-06. Python 3 `sqlite3` module, SQLite 3.51.0, on a throwaway database in `/tmp/attach-test/` (not chat.db).

Steps:
1. Open `a.db` read-only (`mode=ro`).
2. Set an authorizer that returns SQLITE_DENY for SQLITE_ATTACH and SQLITE_OK for everything else.
3. Run `attach database 'file:/tmp/attach-test/b.db' as b`.
4. Run `select count(*) from t`.

Result:
- ATTACH raised `DatabaseError: not authorized`, and `b.db` was not created.
- The SELECT returned `(0,)`.

That `sqlite3_stmt_readonly` returns true for ATTACH comes from the SQLite documentation, not from this check.
