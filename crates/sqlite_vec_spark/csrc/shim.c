/* shim.c -- the committed C surface between the Sqlite_Vec_Spark wrappers and
 * the vendored amalgamations (sqlite3.c, sqlite-vec.c, both .gitignore'd -- see
 * scripts/fetch-deps.sh). Each entry point hides a C-ism with no clean Ada
 * spelling: the void(*)(void) cast for sqlite3_auto_extension, the
 * SQLITE_TRANSIENT sentinel ((destructor)-1), SQLite-owned column buffers.
 *
 * SQLITE_CORE makes sqlite-vec.h pull in sqlite3.h (not sqlite3ext.h) -- the
 * documented static-link path.
 */

#define SQLITE_CORE 1
#include "sqlite3.h"
#include "sqlite-vec.h"
#include <string.h>

/* Every mutating entry point returns void and reports its SQLite result code
 * (SQLITE_OK == 0) through `int *out_rc`, so Ada imports it as a procedure with
 * an In_Out effect on DBMS. The column_* readers return their value directly. */

/* Register sqlite-vec as an auto-extension: connections opened afterwards get
 * the vec0 virtual table and vec_* functions. The static guard keeps repeat
 * calls from growing SQLite's auto-extension list; it is unsynchronized -- the
 * crate is single-threaded by design. */
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

/* Open (or create) the database at `path`, READWRITE|CREATE. On failure
 * sqlite3_open_v2 may still leave a handle in *out_db that must be closed. */
void memcp_sqlite_open(const char *path, sqlite3 **out_db, int *out_rc) {
  *out_rc = sqlite3_open_v2(path, out_db,
                            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
}

/* Close the connection and null the caller's handle. Nulling through sqlite3**
 * is what the Ada release postcondition checks at run time under -gnata, and it
 * makes Close idempotent: sqlite3_close_v2 (NULL) is a documented no-op.
 * close_v2, not close: it tolerates statements not yet finalized, deferring the
 * real close until the last one goes. The result code is dropped -- nothing a
 * caller could do about it. */
void memcp_sqlite_close(sqlite3 **db) {
  sqlite3_close_v2(*db);
  *db = NULL;
}

/* Compile one statement from the first `nbyte` bytes of `sql` (no NUL needed).
 * The resulting statement points into `db`, which must outlive it. */
void memcp_sqlite_prepare(sqlite3 *db, const char *sql, int nbyte,
                          sqlite3_stmt **out_stmt, int *out_rc) {
  *out_rc = sqlite3_prepare_v2(db, sql, nbyte, out_stmt, NULL);
}

/* Run `sql` (NUL-terminated) with no result rows. sqlite3_exec's
 * callback/arg/errmsg are always NULL here, so they are not threaded to Ada. */
void memcp_sqlite_exec(sqlite3 *db, const char *sql, int *out_rc) {
  *out_rc = sqlite3_exec(db, sql, 0, 0, 0);
}

/* Bind parameter `idx` (1-based) to `len` bytes of text. SQLITE_TRANSIENT:
 * SQLite copies, so the Ada String need not outlive the call. */
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

/* Destroy the statement and null the caller's handle, as memcp_sqlite_close
 * does, and likewise idempotent: sqlite3_finalize (NULL) is a documented no-op.
 * The result code is dropped: it repeats the last step's deferred error, which
 * Step/Reset already surfaced. */
void memcp_sqlite_finalize(sqlite3_stmt **stmt) {
  sqlite3_finalize(*stmt);
  *stmt = NULL;
}

/* UTF-8 byte length of column `col` (0-based) of the current row. column_text
 * before column_bytes: the reverse order can report a pre-conversion size.
 * Valid only after SQLITE_ROW and before the next step/reset/finalize. Returns
 * 0 for NULL or empty. */
size_t memcp_sqlite_column_text_len(sqlite3_stmt *stmt, int col) {
  (void)sqlite3_column_text(stmt, col);
  int n = sqlite3_column_bytes(stmt, col);
  return n < 0 ? (size_t)0 : (size_t)n;
}

/* Copy `len` bytes of column `col` (0-based) into caller-owned `dst`, sized from
 * memcp_sqlite_column_text_len with no intervening step, so `len` is exact and
 * this never truncates. Neither side frees the other's buffer. */
void memcp_sqlite_column_text_copy(sqlite3_stmt *stmt, int col, char *dst,
                                   size_t len) {
  const unsigned char *src = sqlite3_column_text(stmt, col);
  if (src != NULL && len > 0) {
    memcpy(dst, src, len);
  }
}
