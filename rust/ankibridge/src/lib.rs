// Copyright: the ankios authors.
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

//! A minimal C ABI over Anki's Rust backend.
//!
//! The whole surface is "send protobuf bytes to (service, method), get protobuf
//! bytes back". Service/method indices come from rslib's own codegen (see the
//! `swiftgen` crate), so this layer never needs to change when Anki adds RPCs.
//!
//! Ownership rules:
//! - Every `AnkiBuffer` returned by this library must be released with
//!   `anki_buffer_free`, exactly once.
//! - Input pointers are only read for the duration of the call.
//! - A backend handle must be released with `anki_backend_free`. Calls may be
//!   made from any thread; rslib serialises collection access internally.

use std::ffi::c_char;
use std::ffi::CStr;
use std::panic::catch_unwind;
use std::panic::AssertUnwindSafe;
use std::ptr;
use std::slice;

use anki::backend::init_backend;
use anki::backend::Backend;
use anki_proto::backend::backend_error::Kind as ErrorKind;
use anki_proto::backend::BackendError;
use prost::Message;

/// Bytes owned by Rust. `data` is null iff `len` is 0.
#[repr(C)]
pub struct AnkiBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl AnkiBuffer {
    fn empty() -> Self {
        AnkiBuffer {
            data: ptr::null_mut(),
            len: 0,
        }
    }

    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::empty();
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        let data = Box::into_raw(boxed) as *mut u8;
        AnkiBuffer { data, len }
    }
}

/// Opaque handle handed to Swift.
pub struct AnkiBackendHandle {
    inner: Backend,
}

/// # Safety
/// `ptr` must be valid for `len` bytes, or `len` must be 0.
unsafe fn input_slice<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 || ptr.is_null() {
        &[]
    } else {
        slice::from_raw_parts(ptr, len)
    }
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".to_string()
    }
}

fn encode_panic_error(message: String) -> Vec<u8> {
    BackendError {
        message: format!("Anki backend panicked: {message}"),
        // Reuse the kind AnkiDroid uses for the same situation.
        kind: ErrorKind::AnkidroidPanicError as i32,
        ..Default::default()
    }
    .encode_to_vec()
}

/// Create a backend from an encoded `anki.backend.BackendInit`.
///
/// Returns null on failure, in which case `*out_error` (if non-null) receives a
/// UTF-8 error message that must be freed with `anki_buffer_free`.
///
/// # Safety
/// `init` must be valid for `init_len` bytes; `out_error` must be null or valid
/// for writes.
#[no_mangle]
pub unsafe extern "C" fn anki_backend_new(
    init: *const u8,
    init_len: usize,
    out_error: *mut AnkiBuffer,
) -> *mut AnkiBackendHandle {
    let input = input_slice(init, init_len);
    let result = catch_unwind(|| init_backend(input))
        .unwrap_or_else(|payload| Err(panic_message(payload.as_ref())));
    match result {
        Ok(inner) => Box::into_raw(Box::new(AnkiBackendHandle { inner })),
        Err(message) => {
            if !out_error.is_null() {
                *out_error = AnkiBuffer::from_vec(message.into_bytes());
            }
            ptr::null_mut()
        }
    }
}

/// Destroy a backend. Does not close the collection; call
/// `CloseCollection` first if one is open.
///
/// # Safety
/// `backend` must come from `anki_backend_new` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn anki_backend_free(backend: *mut AnkiBackendHandle) {
    if !backend.is_null() {
        drop(Box::from_raw(backend));
    }
}

/// Run one RPC.
///
/// On success returns true and `*out` holds the encoded response message.
/// On failure returns false and `*out` holds an encoded
/// `anki.backend.BackendError`. Either way `*out` must be freed.
///
/// Blocks until the operation completes (syncs can take minutes), so never
/// call it from the main thread.
///
/// # Safety
/// `backend` must be a live handle; `input` must be valid for `input_len`
/// bytes; `out` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn anki_backend_run(
    backend: *const AnkiBackendHandle,
    service: u32,
    method: u32,
    input: *const u8,
    input_len: usize,
    out: *mut AnkiBuffer,
) -> bool {
    let backend = &*backend;
    let input = input_slice(input, input_len);
    // Backend is internally synchronised; a panic leaves at worst a poisoned
    // mutex, which subsequent calls will surface as further (caught) panics.
    let result = catch_unwind(AssertUnwindSafe(|| {
        backend.inner.run_service_method(service, method, input)
    }))
    .unwrap_or_else(|payload| Err(encode_panic_error(panic_message(payload.as_ref()))));

    let (ok, bytes) = match result {
        Ok(bytes) => (true, bytes),
        Err(bytes) => (false, bytes),
    };
    *out = AnkiBuffer::from_vec(bytes);
    ok
}

/// Release a buffer returned by this library.
///
/// # Safety
/// `buffer` must have been produced by this library and not freed before.
#[no_mangle]
pub unsafe extern "C" fn anki_buffer_free(buffer: AnkiBuffer) {
    if !buffer.data.is_null() {
        let slice = ptr::slice_from_raw_parts_mut(buffer.data, buffer.len);
        drop(Box::from_raw(slice));
    }
}

/// Route rslib's logging to a file (or stdout when `path` is null).
/// Returns false if the logger could not be installed.
///
/// # Safety
/// `path` must be null or a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn anki_init_logging(path: *const c_char) -> bool {
    let path = if path.is_null() {
        None
    } else {
        match CStr::from_ptr(path).to_str() {
            Ok(p) => Some(p),
            Err(_) => return false,
        }
    };
    catch_unwind(|| anki::log::set_global_logger(path).is_ok()).unwrap_or(false)
}

/// The rslib build hash, for display in an About screen. Free the result.
#[no_mangle]
pub extern "C" fn anki_buildhash() -> AnkiBuffer {
    AnkiBuffer::from_vec(anki::version::buildhash().as_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buffer_roundtrip() {
        let buf = AnkiBuffer::from_vec(vec![1, 2, 3]);
        assert_eq!(buf.len, 3);
        unsafe { anki_buffer_free(buf) };
        let empty = AnkiBuffer::from_vec(vec![]);
        assert!(empty.data.is_null());
        unsafe { anki_buffer_free(empty) };
    }
}
