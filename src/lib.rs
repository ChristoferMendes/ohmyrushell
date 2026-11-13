pub mod git;
mod service;
pub mod theme;

use std::sync::OnceLock;

pub fn render_cached(path: &str, success: bool) -> String {
    render_with_refresh(path, success, true)
}

/// Read the last repository snapshot without another native Git query.
pub fn render_snapshot(path: &str, success: bool) -> String {
    render_with_refresh(path, success, false)
}

fn render_with_refresh(path: &str, success: bool, refresh: bool) -> String {
    static HOME: OnceLock<Option<String>> = OnceLock::new();
    let home = HOME.get_or_init(|| {
        #[cfg(windows)]
        let value = std::env::var("USERPROFILE").ok();
        #[cfg(not(windows))]
        let value = std::env::var("HOME").ok();
        value
    });
    let status = service::cached_status(path, refresh);
    theme::render(
        path,
        home.as_deref(),
        status.as_ref(),
        success,
        std::env::var_os("NO_COLOR").is_none(),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn ohmyrushell_revision() -> u64 {
    service::revision()
}

/// Render UTF-8 into a caller-owned buffer, without transferring allocation ownership.
/// Flags: bit 0 = command succeeded; bit 1 = snapshot only (no filesystem/Git query).
/// Returns the required byte count. If capacity is insufficient, writes nothing.
///
/// # Safety
/// `path` must point to `path_len` readable bytes and `output` to `capacity`
/// writable bytes. The two regions must not overlap and must remain valid for
/// the duration of the call. No references or pointers are retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ohmyrushell_render(
    path: *const u8,
    path_len: usize,
    flags: i32,
    output: *mut u8,
    capacity: usize,
) -> usize {
    if path.is_null() || output.is_null() || path_len > 1_048_576 {
        return 0;
    }
    std::panic::catch_unwind(|| {
        // SAFETY: Validity of the input/output buffers is the caller's contract.
        let bytes = unsafe { std::slice::from_raw_parts(path, path_len) };
        let Ok(path) = std::str::from_utf8(bytes) else {
            return 0;
        };
        let rendered = render_with_refresh(path, flags & 1 != 0, flags & 2 == 0);
        if rendered.len() <= capacity {
            unsafe {
                std::ptr::copy_nonoverlapping(rendered.as_ptr(), output, rendered.len());
            }
        }
        rendered.len()
    })
    .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_checks_capacity_and_utf8() {
        let path = b"/example";
        let mut small = [0x7f; 1];
        let size = unsafe {
            ohmyrushell_render(
                path.as_ptr(),
                path.len(),
                1,
                small.as_mut_ptr(),
                small.len(),
            )
        };
        assert!(size > small.len());
        assert_eq!(small, [0x7f]);
        let mut buffer = vec![0; size + 1024];
        let size = unsafe {
            ohmyrushell_render(
                path.as_ptr(),
                path.len(),
                1,
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        assert!(std::str::from_utf8(&buffer[..size]).unwrap().ends_with(" "));
        assert_eq!(
            unsafe { ohmyrushell_render([0xff].as_ptr(), 1, 1, buffer.as_mut_ptr(), buffer.len()) },
            0
        );
        assert_eq!(
            unsafe {
                ohmyrushell_render(std::ptr::null(), 0, 1, buffer.as_mut_ptr(), buffer.len())
            },
            0
        );
    }
}
