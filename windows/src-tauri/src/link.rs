//! 管理“当前连接”。界面的每次连接尝试都有自己的编号，编号只增不减：
//! 过期的 open 不能覆盖新连接，过期的 close、write、update 也碰不到新连接。
//! 关闭串口要等读写线程退出，所以析构和打开都不能在持有状态锁时进行。
//!
//! open、close、update 都可能等很久，命令要通过 off_thread 调用它们：`#[tauri::command(async)]`
//! 的同步函数是直接跑在异步运行时的工作线程上的，几个慢 open 就能占满工作线程，取消命令也就排不上队了。
use crate::session::{Config, Session};
use std::collections::HashSet;
use std::sync::{Arc, Condvar, Mutex};

/// open 发现自己已经被取消或被更新的连接取代。界面不会把它当作错误显示。
pub const SUPERSEDED: &str = "这次连接已被取消";
const CLOSED: &str = "连接已经关闭";

#[derive(Default)]
struct State {
    /// 还有效的最小编号。open 只有在编号恰好等于它时才能生效。
    floor: u64,
    current: Option<(u64, Arc<Held>)>,
    /// 正在打开或仍被占用的端口。Windows 的串口是独占的，要等上一个句柄关掉才能再打开。
    busy: HashSet<String>,
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

/// 占住一个端口，析构时放开。
struct Lease {
    shared: Arc<Shared>,
    path: String,
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.shared.state.lock().unwrap().busy.remove(&self.path);
        self.shared.changed.notify_all();
    }
}

/// 字段按声明顺序析构：串口完全关闭之后才放开占用。
struct Held {
    session: Session,
    _lease: Lease,
}

/// 复制出来的还是同一份状态，可以带到别的线程上。
#[derive(Clone, Default)]
pub struct Link {
    shared: Arc<Shared>,
}

/// 把会阻塞的工作放到专门的阻塞线程池，不占异步运行时的工作线程。
pub async fn off_thread<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(work).await.map_err(|error| error.to_string())
}

impl Link {
    /// 打开编号为 id 的连接。opener 可能很慢，运行时不持有任何锁。
    pub fn open(&self, id: u64, path: &str, opener: impl FnOnce() -> Result<Session, String>) -> Result<(), String> {
        let previous = {
            let mut state = self.shared.state.lock().unwrap();
            if id < state.floor {
                return Err(SUPERSEDED.into());
            }
            state.floor = id;
            self.shared.changed.notify_all();
            state.current.take()
        };
        drop(previous);

        let lease = self.lease(id, path)?;
        let held = Arc::new(Held { session: opener()?, _lease: lease });

        let mut state = self.shared.state.lock().unwrap();
        if state.floor != id {
            drop(state);
            drop(held);
            return Err(SUPERSEDED.into());
        }
        let replaced = state.current.replace((id, held));
        drop(state);
        drop(replaced);
        Ok(())
    }

    fn lease(&self, id: u64, path: &str) -> Result<Lease, String> {
        let mut state = self.shared.state.lock().unwrap();
        loop {
            if state.floor != id {
                return Err(SUPERSEDED.into());
            }
            if state.busy.insert(path.to_string()) {
                return Ok(Lease { shared: self.shared.clone(), path: path.to_string() });
            }
            state = self.shared.changed.wait(state).unwrap();
        }
    }

    /// 关闭编号不超过 id 的连接，还在打开途中的也算。可以重复调用，也可以早于对应的 open 到达。
    pub fn close(&self, id: u64) {
        let closing = {
            let mut state = self.shared.state.lock().unwrap();
            state.floor = state.floor.max(id.saturating_add(1));
            self.shared.changed.notify_all();
            match &state.current {
                Some((current, _)) if *current <= id => state.current.take(),
                _ => None,
            }
        };
        drop(closing);
    }

    fn held(&self, id: u64) -> Option<Arc<Held>> {
        match &self.shared.state.lock().unwrap().current {
            Some((current, held)) if *current == id => Some(held.clone()),
            _ => None,
        }
    }

    /// 只发给编号相同的连接，过期的数据直接丢弃。
    pub fn write(&self, id: u64, data: Vec<u8>) {
        if let Some(held) = self.held(id) {
            held.session.write(data);
        }
    }

    pub fn update(&self, id: u64, config: &Config) -> Result<(), String> {
        match self.held(id) {
            Some(held) => held.session.update(config),
            None => Err(CLOSED.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_port::FakePort;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc::{channel, Sender};
    use std::time::{Duration, Instant};

    const LONG: Duration = Duration::from_secs(5);

    fn config() -> Config {
        Config { baud: 115200, data_bits: 8, stop_bits: 1, parity: "none".into(), flow: "none".into() }
    }

    fn session(port: &FakePort) -> Result<Session, String> {
        Session::start(Box::new(port.clone()), &config(), |_| {}, || {})
    }

    /// 把一次慢 open 放到后台，等 release 收到消息才完成，返回结果的通道。
    fn slow_open(link: &Arc<Link>, id: u64, path: &str, port: &FakePort) -> (Sender<()>, std::sync::mpsc::Receiver<Result<(), String>>) {
        let (release, wait) = channel::<()>();
        let (done, result) = channel();
        let (link, path, port) = (link.clone(), path.to_string(), port.clone());
        std::thread::spawn(move || {
            let outcome = link.open(id, &path, || {
                wait.recv_timeout(LONG).unwrap();
                session(&port)
            });
            done.send(outcome).unwrap();
        });
        (release, result)
    }

    fn wait_for_floor(link: &Link, id: u64) {
        let end = Instant::now() + LONG;
        while link.shared.state.lock().unwrap().floor < id {
            assert!(Instant::now() < end, "open 一直没有开始");
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[test]
    fn 写入和改参数只作用于编号相同的连接() {
        let link = Link::default();
        let old = FakePort::new();
        let new = FakePort::new();
        link.open(1, "COM3", || session(&old)).unwrap();
        link.open(2, "COM4", || session(&new)).unwrap();

        link.write(1, b"stale".to_vec());
        link.write(2, b"fresh".to_vec());
        assert_eq!(new.wait_written(5), b"fresh");
        assert!(old.written().is_empty(), "过期的写入不能发到任何串口");
        assert!(link.update(1, &config()).is_err(), "过期的改参数要失败，不能假装成功");
        assert!(link.update(2, &config()).is_ok());
    }

    #[test]
    fn 过期的关闭碰不到新连接_重复关闭也没事() {
        let link = Link::default();
        let old = FakePort::new();
        let new = FakePort::new();
        link.open(1, "COM3", || session(&old)).unwrap();
        link.open(2, "COM3", || session(&new)).unwrap();
        link.close(1);
        link.close(1);
        link.write(2, b"still here".to_vec());
        assert_eq!(new.wait_written(10), b"still here");
        link.close(2);
        link.close(2);
        link.write(2, b"gone".to_vec());
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(new.written(), b"still here", "关闭后不能再写入");
    }

    #[test]
    fn 旧的慢open晚完成也不能覆盖新连接() {
        let link = Arc::new(Link::default());
        let slow = FakePort::new();
        let fast = FakePort::new();
        let (release, result) = slow_open(&link, 1, "COM3", &slow);
        wait_for_floor(&link, 1);

        link.open(2, "COM4", || session(&fast)).unwrap();
        release.send(()).unwrap();
        assert_eq!(result.recv_timeout(LONG).unwrap(), Err(SUPERSEDED.to_string()));
        assert!(slow.wait_closed(), "被取代的串口要关掉");

        link.write(2, b"to COM4".to_vec());
        assert_eq!(fast.wait_written(7), b"to COM4");
        assert!(slow.written().is_empty());
    }

    #[test]
    fn 取消还在打开的连接_晚到的结果被丢弃() {
        let link = Arc::new(Link::default());
        let port = FakePort::new();
        let (release, result) = slow_open(&link, 1, "COM3", &port);
        wait_for_floor(&link, 1);
        link.close(1);
        release.send(()).unwrap();
        assert_eq!(result.recv_timeout(LONG).unwrap(), Err(SUPERSEDED.to_string()));
        assert!(port.wait_closed());
        assert!(link.shared.state.lock().unwrap().current.is_none());
    }

    #[test]
    fn 同一端口连接取消再连接_等旧的打开结束后才打开新的() {
        let link = Arc::new(Link::default());
        let first = FakePort::new();
        let second = FakePort::new();
        let (release, first_result) = slow_open(&link, 1, "COM3", &first);
        wait_for_floor(&link, 1);
        link.close(1);

        // 模拟 Windows 的独占：旧句柄没关时打开同一个端口会失败
        let (done, second_result) = channel();
        {
            let (link, first, second) = (link.clone(), first.clone(), second.clone());
            std::thread::spawn(move || {
                let outcome = link.open(2, "COM3", || {
                    assert!(first.is_closed() || !first.was_opened(), "旧句柄还没关就重新打开了");
                    session(&second)
                });
                done.send(outcome).unwrap();
            });
        }
        std::thread::sleep(Duration::from_millis(30));
        assert!(second_result.try_recv().is_err(), "旧的打开还没结束，新的要等着");

        release.send(()).unwrap();
        assert_eq!(first_result.recv_timeout(LONG).unwrap(), Err(SUPERSEDED.to_string()));
        assert_eq!(second_result.recv_timeout(LONG).unwrap(), Ok(()));
        link.write(2, b"ok".to_vec());
        assert_eq!(second.wait_written(2), b"ok");
    }

    #[test]
    fn 等待端口时被取消会立刻返回() {
        let link = Arc::new(Link::default());
        let port = FakePort::new();
        let (release, first_result) = slow_open(&link, 1, "COM3", &port);
        wait_for_floor(&link, 1);

        let (done, second_result) = channel();
        {
            let link = link.clone();
            std::thread::spawn(move || {
                done.send(link.open(2, "COM3", || unreachable!("已经取消，不应该再打开"))).unwrap();
            });
        }
        wait_for_floor(&link, 2);
        link.close(2);
        assert_eq!(second_result.recv_timeout(LONG).unwrap(), Err(SUPERSEDED.to_string()));
        release.send(()).unwrap();
        assert_eq!(first_result.recv_timeout(LONG).unwrap(), Err(SUPERSEDED.to_string()));
    }

    #[test]
    fn 过期的open和晚到的close按编号处理_与到达顺序无关() {
        let link = Link::default();
        let new = FakePort::new();
        link.open(5, "COM3", || session(&new)).unwrap();
        // 编号更小的 open 晚到：直接拒绝，也不会关掉当前连接
        let stale = link.open(4, "COM3", || unreachable!("过期的 open 不应该打开串口"));
        assert_eq!(stale, Err(SUPERSEDED.to_string()));
        link.write(5, b"x".to_vec());
        assert_eq!(new.wait_written(1), b"x");

        // close 比对应的 open 先到：这次 open 不再生效
        link.close(6);
        let late = link.open(6, "COM3", || unreachable!("已经关闭的连接不应该打开串口"));
        assert_eq!(late, Err(SUPERSEDED.to_string()));
    }

    #[test]
    fn 打开失败后端口可以再次打开() {
        let link = Link::default();
        assert_eq!(link.open(1, "COM3", || Err("打不开".to_string())), Err("打不开".to_string()));
        let port = FakePort::new();
        link.open(2, "COM3", || session(&port)).unwrap();
        link.write(2, b"y".to_vec());
        assert_eq!(port.wait_written(1), b"y");
    }

    #[test]
    fn 改参数真的到达当前连接的串口() {
        let link = Link::default();
        let port = FakePort::new();
        link.open(1, "COM3", || session(&port)).unwrap();
        let mut changed = config();
        changed.data_bits = 7;
        link.update(1, &changed).unwrap();
        assert_eq!(port.data_bits(), 7);
    }

    /// 比任何机器的工作线程都多的慢 open。如果它们占着异步工作线程，后面的 open 和取消都排不上队。
    #[test]
    fn 大量慢open不会挡住取消() {
        const SLOW_OPENS: u64 = 64;
        let link = Link::default();
        let release = Arc::new(AtomicBool::new(false));
        let entered = Arc::new(AtomicUsize::new(0));
        let ports: Vec<FakePort> = (0..SLOW_OPENS).map(|_| FakePort::new()).collect();
        let mut tasks = Vec::new();
        for (index, port) in ports.iter().enumerate() {
            let (runner, port, gate, arrived) = (link.clone(), port.clone(), release.clone(), entered.clone());
            let id = index as u64 + 1;
            tasks.push(tauri::async_runtime::spawn(async move {
                off_thread(move || {
                    runner.open(id, &format!("COM{id}"), || {
                        arrived.fetch_add(1, Ordering::SeqCst);
                        while !gate.load(Ordering::SeqCst) {
                            std::thread::sleep(Duration::from_millis(2));
                        }
                        session(&port)
                    })
                })
                .await
            }));
            // 一个进了串口打开函数再开始下一个，否则编号小的会直接被判过期
            let end = Instant::now() + LONG;
            while entered.load(Ordering::SeqCst) <= index {
                assert!(Instant::now() < end, "第 {id} 个慢 open 排不上队");
                std::thread::sleep(Duration::from_millis(1));
            }
        }

        // 所有 open 都卡着的时候，取消必须马上生效
        let started = Instant::now();
        let closer = link.clone();
        tauri::async_runtime::block_on(tauri::async_runtime::spawn(async move {
            off_thread(move || closer.close(SLOW_OPENS)).await
        }))
        .unwrap()
        .unwrap();
        assert!(started.elapsed() < Duration::from_secs(1), "取消等了 {:?}", started.elapsed());

        release.store(true, Ordering::SeqCst);
        for task in tasks {
            let outcome = tauri::async_runtime::block_on(task).unwrap().unwrap();
            assert_eq!(outcome, Err(SUPERSEDED.to_string()));
        }
        for port in &ports {
            assert!(port.wait_closed(), "被取消的慢 open 打开的串口都要关掉");
        }
        assert!(link.shared.state.lock().unwrap().current.is_none());
        assert!(link.shared.state.lock().unwrap().busy.is_empty(), "端口占用都要放开");
    }

    #[test]
    fn 关闭等待线程时不持有状态锁() {
        let link = Arc::new(Link::default());
        let port = FakePort::new();
        link.open(1, "COM3", || session(&port)).unwrap();
        port.hold_reads(true);
        std::thread::sleep(Duration::from_millis(30));

        let (done, closed) = channel();
        {
            let link = link.clone();
            std::thread::spawn(move || {
                link.close(1);
                done.send(()).unwrap();
            });
        }
        std::thread::sleep(Duration::from_millis(50));
        assert!(closed.try_recv().is_err(), "读线程被卡住时，关闭还在等它退出");

        // 这时写入和改参数必须马上返回，否则主线程会跟着卡住
        let started = Instant::now();
        link.write(1, b"z".to_vec());
        assert!(link.update(1, &config()).is_err());
        assert!(started.elapsed() < Duration::from_millis(500), "状态锁被占住了");

        port.hold_reads(false);
        closed.recv_timeout(LONG).unwrap();
    }
}
