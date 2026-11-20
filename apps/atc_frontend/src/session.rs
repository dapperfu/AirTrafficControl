//! One background thread owns the TCP socket. The window sends lines and
//! reads parsed tower messages.

use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::net::TcpStream;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::protocol::{self, Incoming};

pub enum WorkerCmd {
    Line(String),
    Stop,
}

pub enum ServerEvent {
    Message(Incoming),
    Failed(String),
}

pub struct Worker {
    pub tx: Sender<WorkerCmd>,
    pub rx: Receiver<ServerEvent>,
    pub handle: JoinHandle<()>,
}

pub fn spawn(addr: String) -> Worker {
    let (cmd_tx, cmd_rx) = mpsc::channel();
    let (event_tx, event_rx) = mpsc::channel();
    let handle = thread::spawn(move || drive(addr, cmd_rx, event_tx));
    Worker {
        tx: cmd_tx,
        rx: event_rx,
        handle,
    }
}

fn drive(addr: String, cmds: Receiver<WorkerCmd>, events: Sender<ServerEvent>) {
    let stream = match connect(&addr) {
        Ok(stream) => stream,
        Err(err) => {
            let _ = events.send(ServerEvent::Failed(err));
            return;
        }
    };
    if let Err(err) = prepare(&stream) {
        let _ = events.send(ServerEvent::Failed(err.to_string()));
        return;
    }
    let mut writer = match stream.try_clone() {
        Ok(writer) => writer,
        Err(err) => {
            let _ = events.send(ServerEvent::Failed(err.to_string()));
            return;
        }
    };
    let mut reader = BufReader::new(stream);
    match read_greeting(&mut reader) {
        Ok(line) => match protocol::parse_line(&line) {
            Ok(incoming) => {
                if events.send(ServerEvent::Message(incoming)).is_err() {
                    return;
                }
            }
            Err(err) => {
                let _ = events.send(ServerEvent::Failed(err));
                return;
            }
        },
        Err(err) => {
            let _ = events.send(ServerEvent::Failed(err));
            return;
        }
    }

    let mut next_poll = Instant::now();
    let mut waiting = false;
    loop {
        loop {
            match cmds.try_recv() {
                Ok(WorkerCmd::Stop) => return,
                Ok(WorkerCmd::Line(line)) => {
                    if writeln!(writer, "{line}").is_err() {
                        let _ = events.send(ServerEvent::Failed("tower connection failed".into()));
                        return;
                    }
                }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => return,
            }
        }

        if !waiting && Instant::now() >= next_poll {
            if writeln!(writer, "{}", protocol::snapshot()).is_err() {
                let _ = events.send(ServerEvent::Failed("tower connection failed".into()));
                return;
            }
            waiting = true;
            next_poll = Instant::now() + Duration::from_millis(500);
        }

        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => {
                let _ = events.send(ServerEvent::Failed("tower closed the connection".into()));
                return;
            }
            Ok(_) => {
                waiting = false;
                match protocol::parse_line(&line) {
                    Ok(incoming) => {
                        if events.send(ServerEvent::Message(incoming)).is_err() {
                            return;
                        }
                    }
                    Err(err) => {
                        if events
                            .send(ServerEvent::Message(Incoming::Problem(err)))
                            .is_err()
                        {
                            return;
                        }
                    }
                }
            }
            Err(err) if paused(&err) => {}
            Err(err) => {
                let _ = events.send(ServerEvent::Failed(err.to_string()));
                return;
            }
        }
    }
}

fn connect(addr: &str) -> Result<TcpStream, String> {
    use std::net::ToSocketAddrs;
    let sockets: Vec<_> = addr
        .to_socket_addrs()
        .map_err(|err| format!("{addr}: {err}"))?
        .collect();
    if sockets.is_empty() {
        return Err(format!("{addr}: no address"));
    }
    let mut last = format!("could not attach to {addr}");
    for socket in sockets {
        match TcpStream::connect_timeout(&socket, Duration::from_secs(3)) {
            Ok(stream) => return Ok(stream),
            Err(err) => last = format!("{addr}: {err}"),
        }
    }
    Err(last)
}

fn prepare(stream: &TcpStream) -> std::io::Result<()> {
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(Duration::from_millis(200)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    Ok(())
}

fn read_greeting(reader: &mut BufReader<TcpStream>) -> Result<String, String> {
    for _ in 0..15 {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => return Err("tower closed the greeting".into()),
            Ok(_) => return Ok(line),
            Err(err) if paused(&err) => continue,
            Err(err) => return Err(err.to_string()),
        }
    }
    Err("tower did not greet".into())
}

fn paused(err: &std::io::Error) -> bool {
    matches!(err.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock)
}
