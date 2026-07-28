//! candle_ffi -- the trusted foreign body behind the `Candle_Spark` SPARK
//! wrapper. Runs all-MiniLM-L6-v2 (a BERT encoder) with candle + tokenizers and
//! reproduces the sentence-transformers pipeline: encode -> BERT ->
//! mean-pool over tokens -> L2 normalize. That normalization is why every
//! output component lands in -1.0 ..= 1.0, which is the `Post` the Ada side
//! proves against and `-gnata` checks at runtime.
//!
//! The whole C ABI is caller-allocates (the caller owns the 384-float output
//! buffer) so no allocation crosses the boundary except the opaque model handle,
//! which `candle_embed_free` reclaims. Every entry point wraps its work in
//! `catch_unwind`: a candle/tokenizer panic must become a negative status code,
//! never unwind across the FFI (that is undefined behavior).

use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

use candle_core::{DType, Device, Tensor};
use candle_nn::VarBuilder;
use candle_transformers::models::bert::{BertModel, Config, DTYPE};
use tokenizers::{Tokenizer, TruncationParams};

/// Embedding dimension -- must match store.py EMBEDDING_DIM and the Ada
/// `Dimension`.
const DIM: usize = 384;

type Err = Box<dyn std::error::Error>;

/// The loaded engine, owned behind the opaque handle the Ada side holds.
struct EmbedModel {
    model: BertModel,
    tokenizer: Tokenizer,
    device: Device,
}

/// Load model.safetensors + config.json + tokenizer.json from a pre-provisioned
/// directory (see scripts/install-model.sh). No network access.
fn load_impl(path: &str) -> Result<EmbedModel, Err> {
    let device = Device::Cpu;

    let config: Config =
        serde_json::from_str(&std::fs::read_to_string(format!("{path}/config.json"))?)?;

    let mut tokenizer =
        Tokenizer::from_file(format!("{path}/tokenizer.json")).map_err(|e| e.to_string())?;

    // The provisioned tokenizer.json bakes in a Fixed(128) padding strategy and
    // a 128-token truncation. The raw `tokenizers` crate honours both in
    // `encode`, which breaks `embed_impl`'s "single text => no padding"
    // invariant: pad tokens would flow through the maskless forward and dominate
    // the plain mean-pool (worst for short text). Disable padding so every
    // pooled token is real, and truncate at 256 to match the Python side's
    // sentence-transformers `max_seq_length` for embedding parity.
    tokenizer.with_padding(None);
    tokenizer
        .with_truncation(Some(TruncationParams { max_length: 256, ..Default::default() }))
        .map_err(|e| e.to_string())?;

    // Safe use of mmap: the file outlives the borrow and is not mutated.
    let vb = unsafe {
        VarBuilder::from_mmaped_safetensors(&[format!("{path}/model.safetensors")], DTYPE, &device)?
    };
    let model = BertModel::load(vb, &config)?;

    Ok(EmbedModel { model, tokenizer, device })
}

/// Embed one text into `out` (length DIM). Single text => no padding, so every
/// token is real and a plain mean over the sequence is the masked mean.
fn embed_impl(m: &EmbedModel, text: &str, out: &mut [f32]) -> Result<(), Err> {
    let enc = m.tokenizer.encode(text, true).map_err(|e| e.to_string())?;
    let ids: Vec<u32> = enc.get_ids().to_vec();
    let n = ids.len();
    if n == 0 {
        return Err("tokenizer produced no tokens".into());
    }

    let token_ids = Tensor::from_vec(ids, (1, n), &m.device)?;
    let token_type_ids = token_ids.zeros_like()?;

    // [1, n, DIM]
    let hidden = m.model.forward(&token_ids, &token_type_ids, None)?;

    // Mean pool over the token axis, then L2 normalize -> [1, DIM].
    let mean = hidden.sum(1)?.affine(1.0 / n as f64, 0.0)?;
    let norm = mean.sqr()?.sum_keepdim(1)?.sqrt()?;
    let normalized = mean.broadcast_div(&norm)?;

    let v: Vec<f32> = normalized.squeeze(0)?.to_dtype(DType::F32)?.to_vec1::<f32>()?;
    if v.len() != DIM {
        return Err(format!("model returned {}-dim vector, expected {DIM}", v.len()).into());
    }
    out.copy_from_slice(&v);
    Ok(())
}

/// int32 status via `*status`: 0 ok; <0 error. On ok, `*out_handle` owns the
/// engine and must be released with `candle_embed_free`.
///
/// `*out_handle` is written on every path -- NULL first, then the engine on
/// success -- because the Ada import declares it an `out` parameter of an
/// ownership type, which promises the caller a fully initialized handle to
/// reclaim whatever the status says.
///
/// # Safety
/// `path` must point to `len` valid bytes; `out_handle` and `status` must be
/// valid, writable pointers (or null, which is reported as an error / ignored).
#[no_mangle]
pub extern "C" fn candle_embed_load(
    path: *const u8,
    len: usize,
    out_handle: *mut *mut c_void,
    status: *mut i32,
) {
    let code = catch_unwind(AssertUnwindSafe(|| {
        if out_handle.is_null() {
            return -1;
        }
        // Before anything that can fail, so the caller's handle is initialized
        // on every path out of here (see the doc comment).
        unsafe { *out_handle = ptr::null_mut() };
        if path.is_null() {
            return -1;
        }
        let bytes = unsafe { slice::from_raw_parts(path, len) };
        let path_str = match std::str::from_utf8(bytes) {
            Ok(s) => s,
            Err(_) => return -2,
        };
        match load_impl(path_str) {
            Ok(m) => {
                unsafe { *out_handle = Box::into_raw(Box::new(m)) as *mut c_void };
                0
            }
            Err(_) => -3,
        }
    }))
    .unwrap_or(-100);

    if !status.is_null() {
        unsafe { *status = code };
    }
}

/// Fill `out` (DIM floats) with the L2-normalized embedding of `text`. Status
/// via `*status`: 0 ok; <0 error.
///
/// # Safety
/// `handle` must be a live pointer from `candle_embed_load`; `text` must point
/// to `len` valid bytes; `out` must be writable for DIM `f32`s.
#[no_mangle]
pub extern "C" fn candle_embed(
    handle: *const c_void,
    text: *const u8,
    len: usize,
    out: *mut f32,
    status: *mut i32,
) {
    let code = catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() || out.is_null() {
            return -1;
        }
        let m = unsafe { &*(handle as *const EmbedModel) };
        let text_str = if text.is_null() || len == 0 {
            ""
        } else {
            match std::str::from_utf8(unsafe { slice::from_raw_parts(text, len) }) {
                Ok(s) => s,
                Err(_) => return -2,
            }
        };
        let out_slice = unsafe { slice::from_raw_parts_mut(out, DIM) };
        match embed_impl(m, text_str, out_slice) {
            Ok(()) => 0,
            Err(_) => -3,
        }
    }))
    .unwrap_or(-100);

    if !status.is_null() {
        unsafe { *status = code };
    }
}

/// Release the engine behind `*handle` and null the caller's pointer.
///
/// Takes `void **` rather than `void *`, and nulls it, for the Ada ownership
/// model: the Ada handle type is a SPARK ownership type, so its release
/// operation is an `in out` parameter whose postcondition says the handle is
/// left in the reclaimed (null) state. Passing the handle by reference is what
/// makes that postcondition *executable* -- in a build with assertions on
/// (`ADAFLAGS=-gnata`) every `Unload` checks at run time that the pointer really
/// was released, rather than the Ada side merely asserting it. Deleting the
/// `*handle = null` below is therefore a caught mutation, not a silent leak. It
/// also makes the release idempotent and use-after-free impossible through this
/// handle: a second call sees NULL and does nothing.
///
/// # Safety
/// `handle` must be a valid, writable `*mut *mut c_void` (or null, a no-op),
/// and `*handle` must be a live pointer from `candle_embed_load` or null.
#[no_mangle]
pub extern "C" fn candle_embed_free(handle: *mut *mut c_void) {
    if handle.is_null() {
        return;
    }
    let engine = unsafe { *handle };
    if !engine.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            drop(unsafe { Box::from_raw(engine as *mut EmbedModel) });
        }));
    }
    // Unconditionally after the drop, panic or not: the pointer is dead either
    // way, and the Ada postcondition promises the caller a reclaimed handle.
    unsafe { *handle = ptr::null_mut() };
}
