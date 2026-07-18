//! Rust half of the `Spark_Mcp.Http` binding: a synchronous `tiny_http`
//! server exposed to Ada as a PULL API over a C ABI.
//!
//! Ada owns `main` and the request loop; Rust is only ever the callee:
//! `mcp_server_new` binds, `mcp_next` blocks until a real `POST /mcp`
//! arrives (answering 404/400/413 traffic itself), `mcp_body_len` /
//! `mcp_body_read` expose the body, and `mcp_respond` sends the reply and
//! frees the request. No Ada subprogram is ever called from Rust, so no
//! unwind can cross the boundary in either direction and the Ada side of
//! the seam stays inside SPARK.
//!
//! Rust never inspects the JSON — defense in depth: the un-SPARK-able socket
//! and HTTP-framing code stays in memory-safe Rust, the JSON stays in Ada.
//!
//! # The contract trusted by the Ada specs (spark_mcp-http-bridge.ads)
//!
//! * A non-null request handle stays valid until `mcp_respond`; its body is
//!   stable and exactly `mcp_body_len` bytes, capped at [`MAX_BODY_BYTES`].
//! * `mcp_respond` copies `(data, len)` before returning and frees the
//!   request; `len == 0` answers 204 (JSON-RPC notification).
//! * What Rust trusts of Ada — handles are the ones it handed out, used
//!   single-threaded, responded exactly once; `mcp_body_read`'s `dst` has
//!   `mcp_body_len` bytes of room — is discharged BY PROOF on the Ada side
//!   (handle-lifecycle and length contracts in the Bridge spec).

use std::io::Read;
use std::os::raw::c_ushort;

use tiny_http::{Header, Method, Response, Server, StatusCode};

/// Reject request bodies larger than this (HTTP 413). Bounds memory per
/// request and mirrors `Max_Message` in spark_mcp-http.ads, keeping lengths
/// far below Ada's `Natural'Last`.
const MAX_BODY_BYTES: usize = 64 * 1024 * 1024;

/// A request pulled by [`mcp_next`], with its body already buffered.
pub struct McpRequest {
    request: tiny_http::Request,
    body: Vec<u8>,
}

/// Bind `127.0.0.1:port`. Returns an opaque server handle, or null if the
/// socket could not be bound. The handle lives for the process lifetime.
#[no_mangle]
pub extern "C" fn mcp_server_new(port: c_ushort) -> *mut Server {
    let addr = format!("127.0.0.1:{port}");
    match Server::http(&addr) {
        Ok(s) => Box::into_raw(Box::new(s)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Block until the next `POST /mcp` request arrives and return it; anything
/// else on the socket (wrong path/method → 404, unreadable body → 400,
/// oversize body → 413) is answered internally and never surfaces. Returns
/// null only if the accept loop is dead (no further request will arrive).
#[no_mangle]
pub extern "C" fn mcp_next(server: *mut Server) -> *mut McpRequest {
    let server = unsafe { &mut *server };
    loop {
        let mut request = match server.recv() {
            Ok(r) => r,
            Err(_) => return std::ptr::null_mut(),
        };

        let path = request.url().split('?').next().unwrap_or("");
        if *request.method() != Method::Post || path != "/mcp" {
            let _ = request.respond(Response::empty(404));
            continue;
        }

        let mut body = Vec::new();
        let read_ok = request
            .as_reader()
            .take(MAX_BODY_BYTES as u64 + 1)
            .read_to_end(&mut body)
            .is_ok();
        if !read_ok {
            let _ = request.respond(Response::empty(400));
            continue;
        }
        if body.len() > MAX_BODY_BYTES {
            let _ = request.respond(Response::empty(413));
            continue;
        }

        return Box::into_raw(Box::new(McpRequest { request, body }));
    }
}

/// Body length in bytes of a live request. Always <= [`MAX_BODY_BYTES`].
#[no_mangle]
pub extern "C" fn mcp_body_len(req: *const McpRequest) -> usize {
    unsafe { &*req }.body.len()
}

/// Copy the body of a live request into `dst`, which must have room for
/// exactly `mcp_body_len` bytes (proven on the Ada side; Ada skips the call
/// entirely for empty bodies).
#[no_mangle]
pub extern "C" fn mcp_body_read(req: *const McpRequest, dst: *mut u8) {
    let r = unsafe { &*req };
    if !dst.is_null() && !r.body.is_empty() {
        unsafe { std::ptr::copy_nonoverlapping(r.body.as_ptr(), dst, r.body.len()) };
    }
}

/// Send the response and free the request (must not be used afterwards —
/// enforced by `Post => not Is_Live` on the Ada side). `(data, len)` is
/// borrowed only for the duration of this call; `len == 0` answers 204
/// (JSON-RPC notification), otherwise 200 with an application/json body.
#[no_mangle]
pub extern "C" fn mcp_respond(req: *mut McpRequest, data: *const u8, len: usize) {
    let boxed = unsafe { Box::from_raw(req) };
    let outcome = if len == 0 || data.is_null() {
        boxed.request.respond(Response::empty(204))
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
        let resp = Response::from_data(bytes).with_status_code(StatusCode(200));
        match Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]) {
            Ok(h) => boxed.request.respond(resp.with_header(h)),
            Err(_) => boxed.request.respond(resp),
        }
    };
    let _ = outcome;
}
