/* shim.c -- the small, committed C surface between the Sqlite_Vec_Spark SPARK
 * wrappers and the two vendored amalgamations (sqlite3.c, sqlite-vec.c, both
 * .gitignore'd -- see scripts/fetch-deps.sh). Everything here is deliberately
 * kept in C rather than imported straight into Ada, because each item hides a
 * C-ism that has no clean Ada spelling:
 *
 *   1. sqlite-vec registration -- sqlite3_auto_extension takes a
 *      void(*)(void); the cast and the run-once guard live here.
 *   2. bind text/blob -- sqlite3_bind_text/blob need the SQLITE_TRANSIENT
 *      sentinel ((destructor)-1) so SQLite copies the bytes before returning.
 *      Passing that magic pointer from Ada is ugly; hide it.
 *   3. column text -- SQLite owns the column buffer and it is only valid until
 *      the next step/reset/finalize, and the byte length must be measured in
 *      the type-conversion-safe order (text THEN bytes). The two entry points
 *      below encapsulate that: _len probes, _copy fills a caller-owned buffer.
 *      This is the sqlite analogue of Spark_Mcp.Http's mcp_body_read: SQLite
 *      never frees anything of ours and we never free anything of SQLite's;
 *      the Ada side owns (and Unchecked_Deallocation-frees) the copy.
 *
 * SQLITE_CORE makes sqlite-vec.h pull in sqlite3.h (not sqlite3ext.h) and use
 * the core API directly -- the documented static-link path.
 */

#define SQLITE_CORE 1
#include "sqlite3.h"
#include "sqlite-vec.h"
#include <string.h>

/* Every mutating entry point below returns void and reports its SQLite result
 * code through an `int *out_rc`, rather than returning the code directly. This
 * is the same (return code, out param) split as memcp_sqlite_open/prepare, but
 * for a different SPARK reason: a void return lets the Ada side import each of
 * these as a *procedure*, and only a procedure may carry an In_Out effect on
 * the DBMS abstract state (a value-returning function may not). Modelling every
 * mutation as an In_Out on DBMS is what makes SPARK treat operations on one
 * statement as potentially influencing another through the shared connection --
 * the same honesty Ada.Text_IO takes with its File_System state. The read-only
 * entry points (column_*, changes, last_insert_rowid) keep returning their
 * value directly: they carry no DBMS effect. */

/* Register sqlite-vec as an auto-extension so every connection opened
 * afterwards gets the vec0 virtual table + vec_* functions. Idempotent: the
 * static guard means repeated Open calls do not grow SQLite's auto-extension
 * list. Single-threaded by design (see README), so the unguarded static is
 * safe. Reports an SQLite result code (SQLITE_OK == 0) through out_rc. */
void memcp_sqlite_register_vec(int *out_rc) {
  static int done = 0;
  if (done) {
    *out_rc = SQLITE_OK;
    return;
  }
  int rc = sqlite3_auto_extension((void (*)(void))sqlite3_vec_init);
  if (rc == SQLITE_OK) {
    done = 1;
  }
  *out_rc = rc;
}

/* Open (or create) the database at `path`, READWRITE|CREATE. Splits SQLite's
 * (return code, out handle) into two out-pointers with a void return, because
 * SPARK functions may not have out parameters -- so the Ada side imports this
 * as a procedure (the shape of candle_embed_load). On failure SQLite may still
 * set *out_db to a handle that must be closed; the Ada wrapper does so. */
void memcp_sqlite_open(const char *path, sqlite3 **out_db, int *out_rc) {
  *out_rc = sqlite3_open_v2(path, out_db,
                            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
}

/* Compile one statement (first `nbyte` bytes of `sql`, no NUL needed). Same
 * two-out-pointer split as memcp_sqlite_open, for the same SPARK reason. */
void memcp_sqlite_prepare(sqlite3 *db, const char *sql, int nbyte,
                          sqlite3_stmt **out_stmt, int *out_rc) {
  *out_rc = sqlite3_prepare_v2(db, sql, nbyte, out_stmt, NULL);
}

/* Run `sql` (NUL-terminated) with no result rows. The callback/arg/errmsg
 * arguments sqlite3_exec takes are always NULL here, so they are folded into
 * the shim rather than threaded through Ada. */
void memcp_sqlite_exec(sqlite3 *db, const char *sql, int *out_rc) {
  *out_rc = sqlite3_exec(db, sql, 0, 0, 0);
}

/* Bind parameter `idx` (1-based) to `len` bytes of text. SQLITE_TRANSIENT tells
 * SQLite to take its own copy, so the Ada String need not outlive the call. */
void memcp_sqlite_bind_text(sqlite3_stmt *stmt, int idx, const char *text,
                            int len, int *out_rc) {
  *out_rc = sqlite3_bind_text(stmt, idx, text, len, SQLITE_TRANSIENT);
}

/* Bind parameter `idx` (1-based) to `len` bytes of blob (a packed float[] for
 * the vec0 tables). SQLITE_TRANSIENT: SQLite copies before returning. */
void memcp_sqlite_bind_blob(sqlite3_stmt *stmt, int idx, const void *data,
                            int len, int *out_rc) {
  *out_rc = sqlite3_bind_blob(stmt, idx, data, len, SQLITE_TRANSIENT);
}

/* Bind parameter `idx` (1-based) to a 64-bit integer. */
void memcp_sqlite_bind_int64(sqlite3_stmt *stmt, int idx, sqlite3_int64 val,
                             int *out_rc) {
  *out_rc = sqlite3_bind_int64(stmt, idx, val);
}

/* Bind SQL NULL to parameter `idx` (1-based). */
void memcp_sqlite_bind_null(sqlite3_stmt *stmt, int idx, int *out_rc) {
  *out_rc = sqlite3_bind_null(stmt, idx);
}

/* Advance the statement one step (SQLITE_ROW / SQLITE_DONE / error). */
void memcp_sqlite_step(sqlite3_stmt *stmt, int *out_rc) {
  *out_rc = sqlite3_step(stmt);
}

/* Reset a stepped statement so it can be re-stepped (bindings preserved). */
void memcp_sqlite_reset(sqlite3_stmt *stmt, int *out_rc) {
  *out_rc = sqlite3_reset(stmt);
}

/* UTF-8 byte length of column `col` (0-based) of the current row. Calls
 * column_text FIRST to force any type conversion, THEN column_bytes -- the
 * order SQLite documents as safe (bytes-before-text can report a pre-conversion
 * size). Valid only while the current row is live (no step/reset/finalize since
 * the last SQLITE_ROW). Returns 0 for NULL or empty. */
size_t memcp_sqlite_column_text_len(sqlite3_stmt *stmt, int col) {
  (void)sqlite3_column_text(stmt, col);
  int n = sqlite3_column_bytes(stmt, col);
  return n < 0 ? (size_t)0 : (size_t)n;
}

/* Copy `len` bytes of column `col`'s text into the caller-owned `dst`. The
 * caller sized `dst` from memcp_sqlite_column_text_len with no intervening
 * step, so `len` is exact and this never truncates. column_text returns the
 * pointer conversion already cached by the _len probe. NULL columns yield a
 * zero-length copy (guarded by len == 0 on the Ada side). */
void memcp_sqlite_column_text_copy(sqlite3_stmt *stmt, int col, char *dst,
                                   size_t len) {
  const unsigned char *src = sqlite3_column_text(stmt, col);
  if (src != NULL && len > 0) {
    memcpy(dst, src, len);
  }
}
