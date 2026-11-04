//! 开发用自检：设置环境变量 BAUD_SELFTEST=<报告路径> 后启动，界面会通过真实的 Rust 层走一遍收发。
//! 用虚拟串口对扮演设备，所以只有 macOS 和 Linux 版里才有，Windows 版不包含这些代码。
use crate::session::{Config, Session};
use serialport::{SerialPort, TTYPort};
use std::io::{Read, Write};
use std::sync::Mutex;
use std::time::Duration;

pub const PORT: &str = "selftest://pair";

pub static DEVICE: Mutex<Option<TTYPort>> = Mutex::new(None);

pub fn open(
    config: &Config,
    on_data: impl FnMut(Vec<u8>) + Send + 'static,
    on_lost: impl FnOnce() + Send + 'static,
) -> Result<Session, String> {
    let (mut device, mut port) = TTYPort::pair().map_err(|e| e.to_string())?;
    device.set_timeout(Duration::from_millis(20)).map_err(|e| e.to_string())?;
    port.set_timeout(Duration::from_millis(20)).map_err(|e| e.to_string())?;
    *DEVICE.lock().unwrap() = Some(device);
    Session::start(Box::new(port), config, on_data, on_lost)
}

#[tauri::command]
pub fn selftest_path() -> Option<String> {
    std::env::var("BAUD_SELFTEST").ok()
}

#[tauri::command]
pub fn selftest_device_write(data: Vec<u8>) -> Result<(), String> {
    match DEVICE.lock().unwrap().as_mut() {
        Some(device) => device.write_all(&data).map_err(|e| e.to_string()),
        None => Err("虚拟设备没有打开".into()),
    }
}

#[tauri::command]
pub fn selftest_device_read() -> Vec<u8> {
    let mut out = Vec::new();
    if let Some(device) = DEVICE.lock().unwrap().as_mut() {
        let mut buffer = [0u8; 4096];
        while let Ok(n) = device.read(&mut buffer) {
            if n == 0 {
                break;
            }
            out.extend_from_slice(&buffer[..n]);
        }
    }
    out
}

#[tauri::command]
pub fn selftest_unplug() {
    *DEVICE.lock().unwrap() = None;
}

#[tauri::command]
pub fn selftest_finish(app: tauri::AppHandle, report: String, code: i32) {
    if let Ok(path) = std::env::var("BAUD_SELFTEST") {
        let _ = std::fs::write(path, report);
    }
    app.exit(code);
}
