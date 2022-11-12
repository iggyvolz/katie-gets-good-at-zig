const std = @import("std");
fn handle(connection: std.net.StreamServer.Connection, alloc: std.mem.Allocator) !void {
    defer connection.stream.close();
    const reader = connection.stream.reader();
    var request = HttpRequest.readAlloc(@TypeOf(reader), reader, alloc) catch |err| switch(err) {
        error.BrokenPipe, error.ConnectionResetByPeer, error.EndOfStream => {
            // Client disconnected - nothing we can do
            return;
        },
        error.StreamTooLong => {
            // Give a least common response of "you did HTTP wrong"
            _=connection.stream.write("HTTP/0.9 400 Bad Request\r\n\r\n") catch {};
            return;

        },
        else => return err
    };
    defer request.deinit();
    std.debug.print("You are doing a {s} request to {s} with version {s}\n", .{request.method, request.path, request.version});
    var it = request.headers.iterator();
    while(it.next()) |x| {
        std.debug.print("Header `{s}` is \"{s}\"\n", .{x.key_ptr.*, x.value_ptr.*});
    }
    if(request.body == null) {
        std.debug.print("No body was present\n", .{});
    } else {
        std.debug.print("Body of length {d} present: {?s}\n", .{request.body.?.len, request.body});
    }
}

const HttpRequest = struct {
    method: []u8,
    path: []u8,
    version: []u8,
    body: ?[]u8,
    headers: std.StringHashMap([]u8),
    alloc: std.mem.Allocator,
    pub fn deinit(self: *HttpRequest) void {
        self.alloc.free(self.method);
        self.alloc.free(self.path);
        self.alloc.free(self.version);
        // Free all the keys and values in the StringHashMap
        var it = self.headers.iterator();
        while(it.next()) |x| {
            self.alloc.free(x.key_ptr.*);
            self.alloc.free(x.value_ptr.*);
        }
        // Free the StringHashMap itself
        self.headers.deinit();
        if(self.body != null) self.alloc.free(self.body.?);
    }
    
    pub fn readAlloc(comptime ReaderType: type, reader: ReaderType, alloc: std.mem.Allocator) !HttpRequest {
        // const self = HttpRequest{.alloc = alloc};
        // Read request line
        const method = try reader.readUntilDelimiterAlloc(alloc, ' ', 10);
        errdefer alloc.free(method);
        const path = try reader.readUntilDelimiterAlloc(alloc, ' ', 1024);
        errdefer alloc.free(path);
        const version = try reader.readUntilDelimiterAlloc(alloc, '\r', 10);
        errdefer alloc.free(version);
        try reader.skipBytes(1, .{});

        var headers = std.StringHashMap([]u8).init(alloc);
        errdefer {
            // Free all the keys and values in the StringHashMap
            var it = headers.iterator();
            while(it.next()) |x| {
                alloc.free(x.key_ptr.*);
                alloc.free(x.value_ptr.*);
            }
            // Free the StringHashMap itself
            headers.deinit();
        }
        // Read header lines
        while(true) {
            const line: []u8 = try reader.readUntilDelimiterAlloc(alloc, '\n', 1024);
            defer alloc.free(line);
            const colonIndex = std.mem.indexOf(u8, line, ":") orelse break; // If there is no colon, then we are done handling headers
            const key = try std.ascii.allocLowerString(alloc, line[0..colonIndex]);
            defer alloc.free(key);
            const value = line[colonIndex+2..line.len-1]; // value goes from the colon plus space to the end of the string excluding the \r
            if(!headers.contains(key)) {
                // Create unmanaged versions of the key and value
                const key_um = try alloc.alloc(u8, key.len);
                errdefer alloc.free(key_um);
                std.mem.copy(u8, key_um, key);
                const value_um = try alloc.alloc(u8, value.len);
                errdefer alloc.free(value_um);
                std.mem.copy(u8, value_um, value);
                try headers.put(key_um, value_um);
            } else {
                const old = headers.get(key).?;
                const slices = [_][]const u8{old, ",", value};
                const new = try std.mem.concat(alloc, u8, &slices);
                try headers.put(headers.getKey(key).?, new);
                alloc.free(old);
            }
        }
        // Read body
        const contentLength: usize = if(headers.contains("content-length")) std.fmt.parseInt(usize, headers.get("content-length").?, 10) catch 0 else 0;
        const body = if(contentLength == 0) null else try alloc.alloc(u8, contentLength);
        errdefer if(body != null) alloc.free(body.?);
        var read:usize = 0;
        while(read < contentLength) {
            read += try reader.read(body.?[read..]);
        }
        return HttpRequest{
            .method=method,
            .path=path,
            .version=version,
            .headers=headers,
            .body=body,
            .alloc=alloc
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _=gpa.deinit();
    const alloc = gpa.allocator();
    var server: std.net.StreamServer = std.net.StreamServer.init(.{
        .reuse_address = true
    });
    defer server.deinit();
    try server.listen(try std.net.Address.resolveIp("0.0.0.0", 1234));
    while(true) {
        const connection: std.net.StreamServer.Connection = try server.accept();
        const thread: std.Thread = try std.Thread.spawn(.{}, handle, .{connection, alloc});
        thread.detach();
    }
}

fn testParseRequest(req: []u8) !HttpRequest {
    var alloc: std.mem.Allocator = std.testing.allocator;
    var buffer = alloc.alloc(u8, req.len);
    defer alloc.free(buffer);
    var fbs = std.io.fixedBufferStream(&buffer);
    fbs.write(req);
    fbs.seekTo(0);
    return HttpRequest.readAlloc(std.io.FixedBufferStream, fbs, alloc);
}

test "Basic HTTP Request parsing" {
    var fbs = std.io.fixedBufferStream("GET / HTTP/1.1\r\nFoo: bar\r\nFoO: bak\r\nabc: def\r\n\r\n");
    var read = fbs.reader();
    var request=try HttpRequest.readAlloc(@TypeOf(read), read, std.testing.allocator);
    defer request.deinit();
    try std.testing.expectEqualSlices(u8, "GET", request.method);
    try std.testing.expectEqualSlices(u8, "/", request.path);
    try std.testing.expectEqualSlices(u8, "HTTP/1.1", request.version);
    try std.testing.expectEqual(@as(u32, 2), request.headers.count());
    try std.testing.expect(request.headers.contains("foo"));
    try std.testing.expectEqualSlices(u8, "bar,bak", request.headers.get("foo").?);
    try std.testing.expect(request.headers.contains("abc"));
    try std.testing.expectEqualSlices(u8, "def", request.headers.get("abc").?);
    try std.testing.expect(null == request.body);
}

test "HTTP request with body" {
    var fbs = std.io.fixedBufferStream("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nabcde");
    var read = fbs.reader();
    var request=try HttpRequest.readAlloc(@TypeOf(read), read, std.testing.allocator);
    defer request.deinit();
    try std.testing.expectEqualSlices(u8, "POST", request.method);
    try std.testing.expectEqualSlices(u8, "/", request.path);
    try std.testing.expectEqualSlices(u8, "HTTP/1.1", request.version);
    try std.testing.expectEqual(@as(u32, 1), request.headers.count());
    try std.testing.expect(request.headers.contains("content-length"));
    try std.testing.expectEqualSlices(u8, "5", request.headers.get("content-length").?);
    try std.testing.expect(null != request.body);
    try std.testing.expectEqualSlices(u8, "abcde", request.body.?);
}