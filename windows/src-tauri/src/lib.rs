mod session;
#[cfg(unix)]
mod selftest;

use session::{list_ports, Config, PortEntry, Session};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::ipc::{Channel, Response};
use tauri::{AppHandle, Emitter, State};

#[derive(Default)]
struct Link {
    session: Mutex<Option<Session>>,
    next_id: AtomicU64,
}

#[tauri::command]
fn serial_ports() -> Vec<PortEntry> {
    list_ports()
}

/// 打开串口，返回这次连接的编号。收到的数据从 on_data 送回；设备消失时发 serial-lost 事件。
#[tauri::command(async)]
fn serial_open(
    app: AppHandle,
    link: State<'_, Link>,
    path: String,
    config: Config,
    on_data: Channel<Response>,
) -> Result<u64, String> {
    // 先关掉上一个，同一个端口不能重复打开
    let previous = link.session.lock().unwrap().take();
    drop(previous);
    let id = link.next_id.fetch_add(1, Ordering::Relaxed) + 1;
    let deliver = move |data| {
        let _ = on_data.send(Response::new(data));
    };
    let lost = move || {
        let _ = app.emit("serial-lost", id);
    };
    #[cfg(unix)]
    let session = if path == selftest::PORT && selftest::selftest_path().is_some() {
        selftest::open(&config, deliver, lost)?
    } else {
        Session::open(&path, &config, deliver, lost)?
    };
    #[cfg(not(unix))]
    let session = Session::open(&path, &config, deliver, lost)?;
    *link.session.lock().unwrap() = Some(session);
    Ok(id)
}

#[tauri::command]
fn serial_write(link: State<'_, Link>, data: Vec<u8>) {
    if let Some(session) = link.session.lock().unwrap().as_ref() {
        session.write(data);
    }
}

#[tauri::command(async)]
fn serial_update(link: State<'_, Link>, config: Config) -> Result<(), String> {
    match link.session.lock().unwrap().as_ref() {
        Some(session) => session.update(&config),
        None => Ok(()),
    }
}

#[tauri::command(async)]
fn serial_close(link: State<'_, Link>) {
    let session = link.session.lock().unwrap().take();
    drop(session);
}

#[tauri::command(async)]
fn write_text_file(path: String, text: String) -> Result<(), String> {
    std::fs::write(&path, text).map_err(|e| e.to_string())
}

#[cfg(unix)]
macro_rules! handlers {
    () => {
        tauri::generate_handler![
            serial_ports,
            serial_open,
            serial_write,
            serial_update,
            serial_close,
            write_text_file,
            selftest::selftest_path,
            selftest::selftest_device_write,
            selftest::selftest_device_read,
            selftest::selftest_unplug,
            selftest::selftest_finish
        ]
    };
}

#[cfg(not(unix))]
macro_rules! handlers {
    () => {
        tauri::generate_handler![serial_ports, serial_open, serial_write, serial_update, serial_close, write_text_file]
    };
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Link::default())
        .setup(|app| {
            // 每秒看一次端口列表，有变化才通知。这样插拔设备时界面能跟着更新
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                let mut known = list_ports();
                loop {
                    std::thread::sleep(Duration::from_secs(1));
                    let now = list_ports();
                    if now != known {
                        known = now.clone();
                        let _ = handle.emit("ports-changed", now);
                    }
                }
            });
            Ok(())
        })
        .invoke_handler(handlers!())
        .run(tauri::generate_context!())
        .expect("启动失败");
}
