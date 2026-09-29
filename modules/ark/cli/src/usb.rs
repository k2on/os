//! Waiting for a USB device to be plugged in, without polling: inotify on
//! /dev/bus/usb, where the kernel creates a node for every new device.
//! Three libc calls, no crate; std links libc already.
#![cfg(target_os = "linux")]

use std::ffi::CString;
use std::fs;
use std::os::raw::{c_char, c_int, c_void};

extern "C" {
    fn inotify_init1(flags: c_int) -> c_int;
    fn inotify_add_watch(fd: c_int, path: *const c_char, mask: u32) -> c_int;
    fn read(fd: c_int, buf: *mut c_void, count: usize) -> isize;
    fn close(fd: c_int) -> c_int;
}

const IN_CREATE: u32 = 0x0000_0100;

/// A watch on every USB bus directory (and on /dev/bus/usb itself, for buses
/// that appear later). None if that is not possible here.
pub struct Watch(c_int);

impl Watch {
    pub fn new() -> Option<Watch> {
        let fd = unsafe { inotify_init1(0) };
        if fd < 0 {
            return None;
        }
        let watch = Watch(fd);
        let mut watched = 0;
        for dir in std::iter::once("/dev/bus/usb".to_string())
            .chain(fs::read_dir("/dev/bus/usb").ok()?.flatten().map(|e| e.path().display().to_string()))
        {
            let path = CString::new(dir).ok()?;
            if unsafe { inotify_add_watch(fd, path.as_ptr(), IN_CREATE) } >= 0 {
                watched += 1;
            }
        }
        (watched > 0).then_some(watch)
    }

    /// Blocks until a device (or bus) node is created. The device may still be
    /// initialising when this returns; callers retry what they wanted for a moment.
    pub fn wait_for_device(&self) {
        let mut buf = [0u8; 4096];
        unsafe {
            read(self.0, buf.as_mut_ptr() as *mut c_void, buf.len());
        }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        unsafe {
            close(self.0);
        }
    }
}
