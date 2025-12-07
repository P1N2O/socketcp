# SOCKETCP
```
███████╗ ██████╗  ██████╗██╗  ██╗███████╗████████╗ ██████╗██████╗
██╔════╝██╔═══██╗██╔════╝██║ ██╔╝██╔════╝╚══██╔══╝██╔════╝██╔══██╗
███████╗██║   ██║██║     █████╔╝ █████╗     ██║   ██║     ██████╔╝
╚════██║██║   ██║██║     ██╔═██╗ ██╔══╝     ██║   ██║     ██╔═══╝
███████║╚██████╔╝╚██████╗██║  ██╗███████╗   ██║   ╚██████╗██║
╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝    ╚═════╝╚═╝
```
**Ultra-fast Unix Socket → TCP Proxy** written in Zig.  

`socketcp` exposes **Unix domain sockets** (e.g. `/var/run/docker.sock`) to **TCP ports** using a zero-copy, multi-threaded proxy.
Ideal for containers, tooling, debugging, or securely exposing local services.

---

## ✨ Features

- ⚡ **Blazing fast** – written in Zig, tiny & optimized (~50–100 KB binaries)
- 🔁 **Bidirectional streaming** (supports REST, WebSockets, SSE, gRPC-over-HTTP)
- 🧵 **Fully multi-threaded** – each connection is handled in its own worker thread
- 🧷 **Multiple socket mappings** using `--map`
- 🪶 **Tiny memory and CPU footprint**

---

## 🚀 Usage

Single socket mapping:

```bash
socketcp --map /var/run/docker.sock=0.0.0.0:8080
```
Multi socket mappings:

```bash
socketcp --map /var/run/docker.sock=0.0.0.0:8080 --map /var/run/redis.sock=0.0.0.0:6379
```

---

License: [GPLv3](LICENSE)