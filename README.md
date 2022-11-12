## Goal
Discord bot (using Application Commands) that remembers and retrieve text per-user:

```
/katiebot remember foo bin bar
/katiebot recall
foo bin bar
```

Choosing this task because it's a combination of things I've done before in other languages, and it's a fairly straightforward problem without getting into the weeks.  I'd like to use this for [Polish Engine](https://github.com/iggyvolz/PolishEngine) but that's an insanely bigger task.

### Stack
* Zig 0.10.0 + Zig standard library
* Custom HTTP server (built on Zig TCP library)
* Ngrok port forwarding/TLS termination (because I couldn't find a good Zig TLS library for 0.10.0)
* Lightning Memory-mapped Database

As stretch goals:
* Zig standard library
* Some HTTP server package imported
* Running on an actual cloud server (probably OVH managed kubernetes)
* [lmdb-zig](https://github.com/lithdew/lmdb-zig)

I'd like to try doing things myself first just to get a handle on the language, and then trying to learn the package management system(s?) for Zig.

### Milestones
1. Basic HTTP server
1. Process Discord requests
1. Memory in LMDB
1. Use libraries
1. Integrate TLS (???)
1. Run on cloud

## Log
### Milestone 1: Basic HTTP server
Starting from a brand new project, running a:
```sh
$ git init
Initialized empty Git repository in /home/katie/katie-gets-good-at-zig/.git/
```

Copy-pasting a basic hello world from [ziglearn.org](https://ziglearn.org) because my zig isn't good enough to get this from scratch:
```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("Hello, {s}!\n", .{"World"});
}
```
And...
```sh
$ zig run main.zig 
Hello, World!
```

Woo progress!

Paging throught the manual and with a bit of trial-and-error I can get one set up pretty quickly:
```zig
const std = @import("std");

pub fn main() !void {
    var server: std.net.StreamServer = std.net.StreamServer.init(.{});
    defer server.deinit();
    try server.listen(try std.net.Address.resolveIp("0.0.0.0", 1234));
    var connection: std.net.StreamServer.Connection = try server.accept();
    _=connection;
}
```
A few notes here:
* The `@import` brings in the [standard library](https://ziglang.org/documentation/0.10.0/std).  One of the things I appreciate about the language is there's very few keywords and no predefined functions - everything you want is in the standard library and you can name it whatever you want locally.
* There's no `new` keyword in Zig - instead the standard is to have a static `init` function on a class.  Additionally, there is a `deinit` function called immediately after with a `defer` - this deinitializes memory at the end of this scope (no matter if the function exits normally, through an error, through control-C...).  It's a bit scary having to manually manage memory but being able to do an init and deinit right next to each other cleans that up.
* Zig doesn't have exceptions - instead you return Error objects to signal an error.  `try` is syntax sugar for propagating up the error to the parent, and I set the return type of main to `!void` (auto-detected error types or void) out of laziness and not wanting to fix it every time I make a new function call.
* Unused variables are an error in Zig.  Makes sense for finished code (why make a variable if you're not gonna use it?) but a bit annoying for in-progress code (I know I'm going to use that connection variable at some point).  You can set the variable `_` to your variable to tell the compiler to not error - it would be nice to see some sort of a `--unused-local-variable=warn` flag (very possible one exists) to speed up the process a bit in development.
* I like to explicitly type all my variables - not necessary in Zig but it helps looking up documentation.  Especially because the tooling I'm using (Zig extension for VS code and the Zig standard library manual) isn't doing a great job figuring out the namespace of types but just the name itself.

This code listens on `0.0.0.0` (any incoming connection) port 1234, accepts a connection, and immediately exits (because there is nothing else in `main`).  I can test this by running the code:
```sh
$ zig run main.zig
```
And in a separate window:
```sh
$ telnet 127.0.0.1 1234
Connected to 127.0.0.1
Connection closed by foreign host
```

One nice thing is because I'm doing `defer server.deinit()` the port will *always* get released - I usually find writing HTTP servers that if my code crashes the port doesn't get released and I have to restart (or be lazy and change the port number) in order to get it released.  Points for Zig's error handling being predictable here since I know that `defer` is always going to run, barring compiler bugs, kernel panics, or blue screens (let's hope none of which happen today).

Zig does have asynchronous capabilities, but it is [currently broken/incomplete in 0.10.0](https://ziglang.org/download/0.10.0/release-notes.html#Falling-short-of-stage1) and I don't really want to pile on too much anyways.  Luckily, Zig has [threading capabilities](https://ziglang.org/documentation/0.10.0/std/#root;Thread), so we can just make a new thread for each client as they come in:
```zig
const std = @import("std");
fn handle(connection: std.net.StreamServer.Connection) !void {
    defer connection.stream.close();
}

pub fn main() !void {
    var server: std.net.StreamServer = std.net.StreamServer.init(.{});
    defer server.deinit();
    try server.listen(try std.net.Address.resolveIp("0.0.0.0", 1234));
    while(true) {
        var connection: std.net.StreamServer.Connection = try server.accept();
        var thread: std.Thread = try std.Thread.spawn(.{}, handle, .{connection});
        thread.detach();
    }
}
```
One issue here is the threads aren't `join`ed - I tried to do that on `defer` within the `while` but that triggers at the end of the `while` block, not the method (so the thread would immediately block incoming connections - defeating the purpose we want here!).  Since we're writing our own threads, this is fine - as long as we know our `handle` function must clean up after itself.

Note another use of `defer` in the `handle` function - we can leave that as the first line, and we know no matter what happens the thread will close the stream.  However, this looks no different than what we had before, so let's add some output:
```zig
const std = @import("std");
fn handle(connection: std.net.StreamServer.Connection) !void {
    defer connection.stream.close();
    while(true) {
        try connection.stream.writer().writeAll("Hello!\n");
        std.time.sleep(std.time.ns_per_s);
    }
}

pub fn main() !void {
    var server: std.net.StreamServer = std.net.StreamServer.init(.{});
    defer server.deinit();
    try server.listen(try std.net.Address.resolveIp("0.0.0.0", 1234));
    while(true) {
        var connection: std.net.StreamServer.Connection = try server.accept();
        var thread: std.Thread = try std.Thread.spawn(.{}, handle, .{connection});
        thread.detach();
    }
}
```

Running from two different terminals at the same time:
```sh
$ telnet 127.0.0.1 1234
Connected to 127.0.0.1
Hello!
Hello!
Hello!
Hello!
Hello!
```
```sh
$ telnet 127.0.0.1 1234
Connected to 127.0.0.1
Hello!
Hello!
Hello!
Hello!
Hello!
```

Success!  However, when I control-c the telnet window, I get an error in my zig console:
```
error: ConnectionResetByPeer
/home/katie/zig/lib/std/os.zig:1100:27: 0x2375ea in write (main)
            .CONNRESET => return error.ConnectionResetByPeer,
                          ^
/home/katie/zig/lib/std/net.zig:1673:13: 0x238f7b in write (main)
            return os.write(self.handle, buffer);
            ^
/home/katie/zig/lib/std/io/writer.zig:17:13: 0x238fe2 in write (main)
            return writeFn(self.context, bytes);
            ^
/home/katie/zig/lib/std/io/writer.zig:23:26: 0x219e6a in writeAll (main)
                index += try self.write(bytes[index..]);
                         ^
./main.zig:5:9: 0x219ce2 in handle (main)
        try connection.stream.writer().writeAll("Hello!\n");
        ^
error: ConnectionResetByPeer
```
This makes sense - the connection has, in fact, been reset by the peer.  We should be gracefully handling this:
```
const std = @import("std");
fn handle(connection: std.net.StreamServer.Connection) !void {
    defer connection.stream.close();
    while(true) {
        connection.stream.writer().writeAll("Hello!\n") catch |err| {
            if(err == error.ConnectionResetByPeer) {
                break;
            } else {
                return err;
            }
        };
        std.time.sleep(std.time.ns_per_s);
    }
    std.debug.print("Closing down the thread normally\n", .{});
}

pub fn main() !void {
    var server: std.net.StreamServer = std.net.StreamServer.init(.{});
    defer server.deinit();
    try server.listen(try std.net.Address.resolveIp("0.0.0.0", 1234));
    while(true) {
        var connection: std.net.StreamServer.Connection = try server.accept();
        var thread: std.Thread = try std.Thread.spawn(.{}, handle, .{connection});
        thread.detach();
    }
}
```
There, now any threads being reset will be gracefully exited instead of printing an error.  Note that [try](https://ziglang.org/documentation/0.10.0/#try) on the `writeAll` statement was just syntax sugar for `catch |err| return err;` - we just filter out the ConnectionResetByPeer as an expected error.

Plain TCP is no fun - time to start digging into the [HTTP RFC](https://datatracker.ietf.org/doc/html/rfc2616) - okay maybe not all of it, just a limited subset that we need.

For our purposes, an HTTP request consists of (separated by \r\n):
* An initial request line (GET / HTTP/1.1)
* A list of headers (X: Y)
* An empty line
* The body of the message (with the length controlled by the Content-Length field)

In Zig, we have [std.io.Reader.readUntilDelimeterAlloc](https://ziglang.org/documentation/0.10.0/std/#root;io.Reader.readUntilDelimiterAlloc) to read as many bytes as possible until a delimeter.  Note that the function only supports a one-byte (u8) delimeter, but we can cheat by just using `\n` and ignoring the last byte (after all, nobody *should* be putting random `\n`'s in their headers, right...?).

```zig
fn handle(connection: std.net.StreamServer.Connection) !void {
    defer connection.stream.close();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _=gpa.deinit();
    const allocator = gpa.allocator();
    const reader = connection.stream.reader();
    const writer = connection.stream.writer();
    while(true) {
        const line: []u8 = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024) orelse break;
        defer allocator.free(line);
        writer.writeAll(line) catch |err| if(err == error.ConnectionResetByPeer) break else return err;
        writer.writeAll("\n") catch |err| if(err == error.ConnectionResetByPeer) break else return err;
        std.debug.print("{s}\n", .{line});
    }
    std.debug.print("Closing down the thread normally\n", .{});
}
```
A few things here:
* We need to define an allocator so we can allocate memory.  We could use a fixed buffer here, but we'll need an allocator for the body anyways.  We also need to free the bytes we've allocated - note that we're doing that immediately so as not to forget.
* Switched to readUntilDelimeterOrEofAlloc for reading so we don't have to catch the error and check it.  `orelse break` breaks us out of the while loop if `readUntilDelimiterOrEofAlloc` returns null (the remote disconnected).  For writing I condensed the error handling a little bit.

Okay - so we're reading output from the client and spitting it back at them - this still isn't HTTP (and it's still far from useful).  Time to parse out the first line - this is of the structure "<method> <path> HTTP/<version>".  Valid HTTP versions for our use case are 0.9, 1.0, and 1.1, and for our use case there is no difference between the three (HTTP/2.0 is a binary format, and HTTP/3.0 uses UDP instead of TCP).  For our use case - we can just read in the method and version and ignore them except for spitting them back:
```zig
fn handle(connection: std.net.StreamServer.Connection) !void {
    defer connection.stream.close();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _=gpa.deinit();
    const allocator = gpa.allocator();
    const reader = connection.stream.reader();
    const writer = connection.stream.writer();
    const method: []u8 = try reader.readUntilDelimiterOrEofAlloc(allocator, ' ', 10) orelse return;
    defer allocator.free(method);
    const path: []u8 = try reader.readUntilDelimiterOrEofAlloc(allocator, ' ', 1024) orelse return;
    defer allocator.free(path);
    const version: []u8 = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 10) orelse return;
    defer allocator.free(version);
    const temp = try std.fmt.allocPrint(allocator, "You are doing a {s} request to {s} with version {s}\n", .{method, path, version});
    defer allocator.free(temp);
    writer.writeAll(temp) catch |err| if(err == error.ConnectionResetByPeer) return else return err;
    std.debug.print("Closing down the thread normally\n", .{});
}
```

```
$ telnet 127.0.0.1 1234
Connected to 127.0.0.1
GET /foo HTTP/1.1
You are doing a GET request to /foo with version HTTP/1.1
```

All of this error handling is getting a little repetitive when really we want to do the same thing on every type of error - let's box this whole thing up and handle errors in one place:
```zig
fn handle(connection: std.net.StreamServer.Connection) !void {
    defer connection.stream.close();
    handleInner(connection) catch |err| switch(err) {
        error.BrokenPipe, error.ConnectionResetByPeer, error.NotOpenForReading, error.NotOpenForWriting => {
            // Client disconnected - nothing we can do
        },
        error.StreamTooLong => {
            // Give a least common response of "you did HTTP wrong"
            _=connection.stream.write("HTTP/0.9 400 Bad Request\r\n\r\n") catch {};
        },
        else => return err
    };
}

fn handleInner(connection: std.net.StreamServer.Connection) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _=gpa.deinit();
    const allocator = gpa.allocator();
    const reader = connection.stream.reader();
    const writer = connection.stream.writer();
    const method: []u8 = try reader.readUntilDelimiterAlloc(allocator, ' ', 10);
    defer allocator.free(method);
    const path: []u8 = try reader.readUntilDelimiterAlloc(allocator, ' ', 1024);
    defer allocator.free(path);
    const version: []u8 = try reader.readUntilDelimiterAlloc(allocator, '\n', 10);
    defer allocator.free(version);
    const temp = try std.fmt.allocPrint(allocator, "You are doing a {s} request to {s} with version {s}\n", .{method, path, version});
    defer allocator.free(temp);
    try writer.writeAll(temp);
    std.debug.print("Closing down the thread normally\n", .{});
}
```

Onto the second part of the HTTP request, the headers.  Each header consists of a key and a value - and the keys are unique [except when they aren't](https://www.rfc-editor.org/rfc/rfc2616#section-4.2) - so if multiple headers with the same key come up, we should combine them comma-separated (gah HTTP you almost made things simple!!!).

This one took me a while, quite a bit of memory debugging and stupid things I forgot:
```zig
var headers = std.StringHashMap([]u8).init(gpa.allocator());
defer {
    // Free all the keys and values in the StringHashMap
    var it = headers.iterator();
    while(it.next()) |x| {
        allocator.free(x.key_ptr.*);
        allocator.free(x.value_ptr.*);
    }
    // Free the StringHashMap itself
    headers.deinit();
}
// Read header lines
while(true) {
    const line: []u8 = try reader.readUntilDelimiterAlloc(allocator, '\n', 1024);
    defer allocator.free(line);
    const colonIndex = std.mem.indexOf(u8, line, ":") orelse break; // If there is no colon, then we are done handling headers
    const key = std.ascii.allocLowerString(line[0..colonIndex]);
    defer allocator.free(key);
    const value = line[colonIndex+2..line.len-1]; // value goes from the colon plus space to the end of the string excluding the \r
    if(!headers.contains(key)) {
        // Create unmanaged versions of the key and value
        const key_um = try allocator.alloc(u8, key.len);
        errdefer allocator.free(key_um);
        std.mem.copy(u8, key_um, key);
        const value_um = try allocator.alloc(u8, value.len);
        errdefer allocator.free(value_um);
        std.mem.copy(u8, value_um, value);
        try headers.put(key_um, value_um);
    } else {
        const old = headers.get(key).?;
        const slices = [_][]const u8{old, ",", value};
        const new = try std.mem.concat(allocator, u8, &slices);
        try headers.put(headers.getKey(key).?, new);
        allocator.free(old);
    }
}

var it = headers.iterator();
while(it.next()) |x| {
    std.debug.print("{s} is {s}\n", .{x.key_ptr.*, x.value_ptr.*});
}
std.debug.print("Closing down the thread normally\n", .{});
```
This initializes a HashMap of `[]u8` to `[]u8` (string to string).  Since the HashMap object doesn't handle deinitializing memory for us (since it doesn't know what's going to be in there and how or if that should be deinitialized), we have to create a defer function that frees every key and value (and we know that strings going into this hash map should be unmanaged).  For each line until an empty line (here we cheat by breaking if we don't find a `:`), grab the key and value on either side of the `:`.  There are two possible scenarios here:
* The header does not exist - we create a copy of the key and value (remember - they will get freed in the defer block!) and put those into the hash map
* The header already exists - we use `std.mem.concat` to create a new string with `{old},{new}` and free the old string

The order of `defer`s, `errdefer`s, and `free`s came with a couple hours of trial-and-error and straight-up guesswork, and I'm not entirely convinced that it's correct, but it works for now so we continue on.  I also added a quick debug line to print out the headers that are consumed:

```
$ telnet 127.0.0.1 1234
Connected to 127.0.0.1
GET / HTTP/1.1
Foo: bin bar
fOo: bak yin
other: thing
```

```
You are doing a GET request to / with version HTTP/1.1
other is thing
foo is bin bar,bak yin
Closing down the thread normally
```

I also note that header names are case-insensitive, so we make the `key` lowercase always.  There's probably a more efficient way to do this without allocating `key` multiple times, but it works for now and onward we venture.

If the header Content-Length is specified, then the headers are followed by a <content-length>-length string which is the body of the request.  Technically, this can only happen on some methods, but we don't care.

```zig
// Read body
const contentLength: usize = if(headers.contains("content-length")) std.fmt.parseInt(usize, headers.get("content-length").?, 10) catch 0 else 0;
std.debug.print("Content length is {d}\n", .{contentLength});
const body: ?[]u8 = if(contentLength == 0) null else try allocator.alloc(u8, contentLength);
defer if(body != null) allocator.free(body.?);
var read:usize = 0;
while(read < contentLength) {
    read += try reader.read(body.?[read..]);
}
std.debug.print("Body is {?s}\n", .{body});
```

Fairly straightforward - reading the header content-length, parsing with `std.fmt.parseInt`, and reading that many bytes at the end and printing it.  And now, finally, we have the entire HTTP request read.

Unfortunately at this point, our little "handle" method has grown into a bit of a monster - I couldn't imagine trying to figure out which variables here I'm supposed to use and which have been freed.  Time to repurpose our `handleInternal` method into a general-purpose struct and do some general cleanup (see `HttpRequest` for the finished struct):

```zig
fn handle(connection: std.net.StreamServer.Connection, alloc: std.mem.Allocator) !void {
    defer connection.stream.close();
    var request = HttpRequest.readAlloc(connection.stream.reader(), alloc) catch |err| switch(err) {
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
```

Since we're parsing in the entire HTTP request at this point, we can use curl to test instead of manually typing out the TCP:
```sh
$ curl 127.0.0.1:1234
curl: (52) Empty reply from server
```
```
You are doing a GET request to / with version HTTP/1.1
Header `user-agent` is "curl/7.83.1"
Header `accept` is "*/*"
Header `host` is "127.0.0.1:1234"
No body was present
```
```sh
$ curl --data hello 127.0.0.1:1234
curl: (52) Empty reply from server
```
```
You are doing a POST request to / with version HTTP/1.1
Header `user-agent` is "curl/7.83.1"
Header `accept` is "*/*"
Header `content-length` is "5"
Header `content-type` is "application/x-www-form-urlencoded"
Header `host` is "127.0.0.1:1234"
Body of length 5 present: hello
```
```sh
$ curl --data hello --header "foo: bar" --header "FoO: bin" 127.0.0.1:1234
```
```
You are doing a POST request to / with version HTTP/1.1
Header `user-agent` is "curl/7.83.1"
Header `accept` is "*/*"
Header `content-length` is "5"
Header `content-type` is "application/x-www-form-urlencoded"
Header `host` is "127.0.0.1:1234"
Header `foo` is "bar,bin"
Body of length 5 present: hello
```

