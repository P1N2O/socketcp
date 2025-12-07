const std = @import("std");
const net = std.net;
const posix = std.posix;
const mem = std.mem;

const ArgError = error{
    MissingMap,
    UnknownArgument,
    MissingValue,
    InvalidMap,
    InvalidPort,
};

const ListenerConfig = struct {
    socket_path: []const u8,
    host: []const u8,
    port: u16,
};

const Config = struct {
    mappings: []ListenerConfig,
};

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  socketcp --map /path/to.sock=HOST:PORT [--map /other.sock=HOST:PORT ...]
        \\
        \\Examples:
        \\  socketcp --map /var/run/docker.sock=0.0.0.0:8080
        \\  socketcp \\
        \\    --map /var/run/docker.sock=0.0.0.0:8080 \\
        \\    --map /var/run/docker2.sock=0.0.0.0:8081
        \\
        \\Options:
        \\  --map <unix_path>=<host:port>   Add a Unix<->TCP mapping
        \\  -h, --help                      Show this help
        \\
    ,
        .{},
    );
}

fn printBanner() void {
    std.debug.print(
        \\
        \\███████╗ ██████╗  ██████╗██╗  ██╗███████╗████████╗ ██████╗██████╗ 
        \\██╔════╝██╔═══██╗██╔════╝██║ ██╔╝██╔════╝╚══██╔══╝██╔════╝██╔══██╗
        \\███████╗██║   ██║██║     █████╔╝ █████╗     ██║   ██║     ██████╔╝
        \\╚════██║██║   ██║██║     ██╔═██╗ ██╔══╝     ██║   ██║     ██╔═══╝ 
        \\███████║╚██████╔╝╚██████╗██║  ██╗███████╗   ██║   ╚██████╗██║     
        \\╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝    ╚═════╝╚═╝     
        \\
        \\socketcp - Ultra-fast Unix Socket → TCP Proxy
        \\
        \\
    ,
        .{},
    );
}

fn parseHostPort(allocator: mem.Allocator, input: []const u8) !struct {
    host: []const u8,
    port: u16,
} {
    const idx_opt = mem.lastIndexOfScalar(u8, input, ':') orelse {
        std.debug.print("Invalid host:port (missing colon): {s}\n", .{input});
        return ArgError.InvalidMap;
    };

    const host_part = input[0..idx_opt];
    const port_str = input[idx_opt + 1 ..];

    if (host_part.len == 0 or port_str.len == 0) {
        std.debug.print("Invalid host:port: {s}\n", .{input});
        return ArgError.InvalidMap;
    }

    const host = try allocator.dupe(u8, host_part);

    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch |err| {
        std.debug.print("Invalid port in host:port '{s}': {s}\n", .{ input, @errorName(err) });
        return ArgError.InvalidPort;
    };

    if (port == 0) return ArgError.InvalidPort;

    return .{
        .host = host,
        .port = port,
    };
}

fn parseArgs(allocator: mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name.
    _ = args.next() orelse return ArgError.MissingMap;

    var mappings_list = std.ArrayListUnmanaged(ListenerConfig){};

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--map")) {
            const spec = args.next() orelse return ArgError.MissingValue;
            const eq_idx = mem.indexOfScalar(u8, spec, '=') orelse {
                std.debug.print("Invalid --map spec (missing '='): {s}\n", .{spec});
                return ArgError.InvalidMap;
            };

            const socket_path_slice = spec[0..eq_idx];
            const host_port_slice = spec[eq_idx + 1 ..];

            if (socket_path_slice.len == 0 or host_port_slice.len == 0) {
                std.debug.print("Invalid --map spec: {s}\n", .{spec});
                return ArgError.InvalidMap;
            }

            const socket_path = try allocator.dupe(u8, socket_path_slice);
            const parsed = try parseHostPort(allocator, host_port_slice);

            try mappings_list.append(allocator, .{
                .socket_path = socket_path,
                .host = parsed.host,
                .port = parsed.port,
            });
        } else if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return ArgError.UnknownArgument;
        }
    }

    if (mappings_list.items.len == 0) {
        std.debug.print("At least one --map is required\n", .{});
        return ArgError.MissingMap;
    }

    const mappings_slice = try mappings_list.toOwnedSlice(allocator);
    return Config{
        .mappings = mappings_slice,
    };
}

/// Write entire buffer to fd, handling short writes.
fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const wrote = try posix.write(fd, data[offset..]);
        if (wrote == 0) return error.UnexpectedWriteZero;
        offset += wrote;
    }
}

/// Bi-directional copy between two fds until one side closes.
///
/// fd_a <-> fd_b
fn pumpDuplex(fd_a: posix.fd_t, fd_b: posix.fd_t) !void {
    var fds = [_]posix.pollfd{
        .{ .fd = fd_a, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = fd_b, .events = posix.POLL.IN, .revents = 0 },
    };

    var buf: [4096]u8 = undefined;

    while (true) {
        for (&fds) |*p| p.revents = 0;

        const n_ready = try posix.poll(&fds, -1);
        if (n_ready == 0) continue;

        // a -> b
        if (fds[0].revents & posix.POLL.IN == posix.POLL.IN) {
            const n = try posix.read(fd_a, &buf);
            if (n == 0) break; // EOF
            try writeAll(fd_b, buf[0..n]);
        } else if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
            break;
        }

        // b -> a
        if (fds[1].revents & posix.POLL.IN == posix.POLL.IN) {
            const n2 = try posix.read(fd_b, &buf);
            if (n2 == 0) break; // EOF
            try writeAll(fd_a, buf[0..n2]);
        } else if (fds[1].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
            break;
        }
    }
}

const ListenerContext = struct {
    allocator: mem.Allocator,
    config: ListenerConfig,
};

const ConnContext = struct {
    allocator: mem.Allocator,
    socket_path: []const u8,
    host: []const u8,
    port: u16,
    stream: net.Stream, // TCP side
};

fn connectionThreadMain(ctx: *ConnContext) void {
    std.debug.print(
        "[{s}:{d}] Connection start\n",
        .{ ctx.host, ctx.port },
    );

    // Always clean up on exit.
    defer {
        ctx.stream.close();
        std.debug.print(
            "[{s}:{d}] Connection closed\n",
            .{ ctx.host, ctx.port },
        );
        ctx.allocator.destroy(ctx);
    }

    var unix_stream = net.connectUnixSocket(ctx.socket_path) catch |err| {
        std.debug.print(
            "[{s}:{d}] Failed to connect Unix socket {s}: {s}\n",
            .{ ctx.host, ctx.port, ctx.socket_path, @errorName(err) },
        );
        return;
    };
    defer unix_stream.close();

    const tcp_fd: posix.fd_t = ctx.stream.handle;
    const unix_fd: posix.fd_t = unix_stream.handle;

    pumpDuplex(tcp_fd, unix_fd) catch |err| {
        std.debug.print(
            "[{s}:{d}] Pump error: {s}\n",
            .{ ctx.host, ctx.port, @errorName(err) },
        );
    };
}

fn spawnConnectionHandler(
    allocator: mem.Allocator,
    mapping: ListenerConfig,
    tcp_stream: net.Stream,
) !void {
    const ctx = try allocator.create(ConnContext);
    ctx.* = ConnContext{
        .allocator = allocator,
        .socket_path = mapping.socket_path,
        .host = mapping.host,
        .port = mapping.port,
        .stream = tcp_stream,
    };

    var thread = try std.Thread.spawn(.{}, connectionThreadMain, .{ctx});
    thread.detach();
}

fn listenerThreadMain(ctx: *ListenerContext) void {
    defer {
        ctx.allocator.destroy(ctx);
    }

    const address = net.Address.parseIp(ctx.config.host, ctx.config.port) catch |err| {
        std.debug.print(
            "Failed to parse address {s}:{d}: {s}\n",
            .{ ctx.config.host, ctx.config.port, @errorName(err) },
        );
        return;
    };

    var server = address.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print(
            "Failed to listen on {s}:{d}: {s}\n",
            .{ ctx.config.host, ctx.config.port, @errorName(err) },
        );
        return;
    };
    defer server.deinit();

    std.debug.print(
        "Listening on {s}:{d}, forwarding to Unix socket {s}\n",
        .{ ctx.config.host, ctx.config.port, ctx.config.socket_path },
    );

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print(
                "Accept error on {s}:{d}: {s}\n",
                .{ ctx.config.host, ctx.config.port, @errorName(err) },
            );
            continue;
        };

        const stream = conn.stream;

        spawnConnectionHandler(ctx.allocator, ctx.config, stream) catch |err| {
            std.debug.print(
                "Failed to spawn handler on {s}:{d}: {s}\n",
                .{ ctx.config.host, ctx.config.port, @errorName(err) },
            );
            stream.close();
        };
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    const cfg = parseArgs(allocator) catch |err| {
        switch (err) {
            error.MissingMap,
            error.UnknownArgument,
            error.MissingValue,
            error.InvalidMap,
            error.InvalidPort,
            => {
                printUsage();
                return;
            },
            else => {
                std.debug.print("Fatal error parsing args: {s}\n", .{@errorName(err)});
                return;
            },
        }
    };

    // Print banner once args are valid
    printBanner();

    // One listener thread per mapping; then join (they never exit, so this keeps main alive).
    var threads = try allocator.alloc(std.Thread, cfg.mappings.len);

    var i: usize = 0;
    while (i < cfg.mappings.len) : (i += 1) {
        const mapping = cfg.mappings[i];

        const ctx = try allocator.create(ListenerContext);
        ctx.* = ListenerContext{
            .allocator = allocator,
            .config = mapping,
        };

        threads[i] = try std.Thread.spawn(.{}, listenerThreadMain, .{ctx});
    }

    std.debug.print("Started {d} listener(s)\n", .{cfg.mappings.len});

    // Block forever (join on listeners; first one will never return in normal operation).
    for (threads) |*t| {
        t.join();
    }
}
