//! 开发用自检：设置环境变量 BAUD_SELFTEST=<报告路径> 后启动，界面会通过真实的 Rust 层走一遍收发。
//! 用虚拟串口对扮演设备，所以只有 macOS 和 Linux 版里才有，Windows 版不包含这些代码。
//!
//! 可以同时有多个虚拟设备，名字决定它的行为：
//! - selftest://pair、selftest://other：普通设备
//! - selftest://slow：打开要 800 毫秒，用来测试慢 open
//! - selftest://chatty：打开后 30 毫秒发出启动信息，这时界面的连接动画还没结束
//! - selftest://dies：打开后 30 毫秒就消失
use crate::session::{Config, PortEntry, Session};
use serialport::{SerialPort, TTYPort};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

const PREFIX: &str = "selftest://";
const DEFAULT_PORT: &str = "selftest://pair";
pub const CHATTY_TEXT: &[u8] = b"early: boot banner\r\n";

static DEVICES: LazyLock<Mutex<HashMap<String, TTYPort>>> = LazyLock::new(Mutex::default);

fn active() -> bool {
    std::env::var("BAUD_SELFTEST").is_ok()
}

pub fn is_selftest_port(path: &str) -> bool {
    path.starts_with(PREFIX) && active()
}

/// 自检时这些虚拟设备也出现在端口列表里，和真实串口走同样的流程。
pub fn ports() -> Vec<PortEntry> {
    if !active() {
        return Vec::new();
    }
    ["pair", "other", "slow", "chatty", "dies"]
        .map(|name| PortEntry { path: format!("{PREFIX}{name}"), name: format!("虚拟 {name}"), detail: String::new(), kind: "other" })
        .into()
}

pub fn open(
    path: &str,
    config: &Config,
    on_data: impl FnMut(Vec<u8>) + Send + 'static,
    on_lost: impl FnOnce() + Send + 'static,
) -> Result<Session, String> {
    if path.ends_with("slow") {
        std::thread::sleep(Duration::from_millis(800));
    }
    let (mut device, mut port) = TTYPort::pair().map_err(|e| e.to_string())?;
    device.set_timeout(Duration::from_millis(20)).map_err(|e| e.to_string())?;
    port.set_timeout(Duration::from_millis(20)).map_err(|e| e.to_string())?;
    DEVICES.lock().unwrap().insert(path.to_string(), device);
    let session = Session::start(Box::new(port), config, on_data, on_lost)?;

    if path.ends_with("chatty") || path.ends_with("dies") {
        let name = path.to_string();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            let mut devices = DEVICES.lock().unwrap();
            if name.ends_with("dies") {
                devices.remove(&name);
            } else if let Some(device) = devices.get_mut(&name) {
                let _ = device.write_all(CHATTY_TEXT);
            }
        });
    }
    Ok(session)
}

fn key(port: Option<String>) -> String {
    port.unwrap_or_else(|| DEFAULT_PORT.to_string())
}

#[tauri::command]
pub fn selftest_path() -> Option<String> {
    std::env::var("BAUD_SELFTEST").ok()
}

#[tauri::command]
pub fn selftest_device_write(port: Option<String>, data: Vec<u8>) -> Result<(), String> {
    match DEVICES.lock().unwrap().get_mut(&key(port)) {
        Some(device) => device.write_all(&data).map_err(|e| e.to_string()),
        None => Err("虚拟设备没有打开".into()),
    }
}

#[tauri::command]
pub fn selftest_device_read(port: Option<String>) -> Vec<u8> {
    let mut out = Vec::new();
    if let Some(device) = DEVICES.lock().unwrap().get_mut(&key(port)) {
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
pub fn selftest_unplug(port: Option<String>) {
    DEVICES.lock().unwrap().remove(&key(port));
}

/// 虚拟串口的参数都在设备这一头也能读到，用来确认改参数真的生效了。
#[tauri::command]
pub fn selftest_device_data_bits(port: Option<String>) -> Option<u8> {
    let devices = DEVICES.lock().unwrap();
    devices.get(&key(port)).and_then(|device| device.data_bits().ok()).map(u8::from)
}

#[tauri::command]
pub fn selftest_finish(app: tauri::AppHandle, report: String, code: i32) {
    if let Ok(path) = std::env::var("BAUD_SELFTEST") {
        let _ = std::fs::write(path, report);
    }
    app.exit(code);
}
