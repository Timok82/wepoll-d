# wepoll-d - epoll for windows

A D language port of wepoll, based on the original C implementation by Bert Belder [wepoll](https://github.com/piscisaureus/wepoll).

## Description

wepoll-d provides an epoll-like API for Windows, allowing applications to monitor sockets for I/O events.

This library implements the [epoll][man epoll] API for Windows
applications. It is fast and scalable, and it closely resembles the API
and behavior of Linux' epoll.

It is distributed as a single, self-contained D module ([wepoll.d](wepoll.d))
that depends only on druntime (`core.*`); no C sources, headers or import
libraries are needed to build it.

## Rationale

Unlike Linux, OS X, and many other operating systems, Windows doesn't
have a good API for receiving socket state notifications. It only
supports the `select` and `WSAPoll` APIs, but they
[don't scale][select scale] and suffer from
[other issues][wsapoll broken].

Using I/O completion ports isn't always practical when software is
designed to be cross-platform. Wepoll offers an alternative that is
much closer to a drop-in replacement for software that was designed
to run on Linux.

## Features

* Can poll 100000s of sockets efficiently.
* Fully thread-safe.
* Multiple threads can poll the same epoll port.
* Sockets can be added to multiple epoll sets.
* All epoll events (`EPOLLIN`, `EPOLLOUT`, `EPOLLPRI`, `EPOLLRDHUP`)
  are supported.
* Level-triggered and one-shot (`EPOLLONESHOT`) modes are supported.
* Trivial to embed: just add the single file [wepoll.d](wepoll.d) to your
  D project.

## Limitations

* Only works with sockets.
* Edge-triggered (`EPOLLET`) mode isn't supported.

## How to use

Copy [wepoll.d](wepoll.d) into your project (or add its directory to your
import path), compile it together with the rest of your sources and import
the module:

```d
import wepoll;
import core.sys.windows.winsock2;  // SOCKET and the Winsock functions
```

The module declares `pragma(lib, "Kernel32")` and `pragma(lib, "Ws2_32")`,
so dmd/ldc link the required system libraries automatically. If you build
with a toolchain that ignores pragmas (e.g. gdc or a manual link step),
link `Kernel32.lib` and `Ws2_32.lib` yourself.

Unlike the original C library, this is a normal D module: all public
functions are `extern(C) nothrow @nogc`, the event type is a D `struct`,
user data is a D `union`, and there is no `struct` keyword or `NULL` macro
in client code. Winsock is initialized lazily by the module itself, so
calling `WSAStartup()` yourself is not required.

`extern(C)` here only selects the C ABI (unmangled names and calling
convention) so the signatures match `core.sys.linux.epoll` and `wepoll.h`.
The function bodies are implemented in D inside this file; it is **not** a
wrapper or binding around a compiled C library.

A minimal example:

```d
import wepoll;
import core.sys.windows.winsock2;

HANDLE ep = epoll_create1(0);
assert(ep !is null);

epoll_event ev;
ev.events = EPOLLIN | EPOLLRDHUP;
ev.data.sock = listener;
assert(epoll_ctl(ep, EPOLL_CTL_ADD, listener, &ev) == 0);

epoll_event[64] events;
int n = epoll_wait(ep, events.ptr, cast(int) events.length, -1);
foreach (i; 0 .. n)
{
    // use events[i].data.sock and events[i].events
}

epoll_close(ep);
```

Use the named constants exported by the module (`EPOLLIN`,
`EPOLL_CTL_ADD`, ...). In particular, do **not** hard-code the control
opcode values: this module follows wepoll.h and numbers them as
`EPOLL_CTL_ADD = 1`, `EPOLL_CTL_MOD = 2`, `EPOLL_CTL_DEL = 3`, which is a
different order from Linux.

Functions report failure with a negative return value (or `null` from
`epoll_create`/`epoll_create1`) and set both `errno` (see
`core.stdc.errno`) and `GetLastError()`. Since the functions are
`nothrow @nogc`, check return values rather than relying on exceptions.

## Compatibility

* Requires Windows Vista or higher. The whole module is guarded by
  `version (Windows)`; on other platforms it compiles to an empty module.
* Can be compiled with recent versions of dmd, ldc, and gdc.

## API

### General remarks

* The epoll port is a `HANDLE`, not a file descriptor (`core.sys.windows.windef`).
* All functions set both `errno` and `GetLastError()` on failure.
* For more extensive documentation, see the [epoll(7) man page][man epoll],
  and the per-function man pages that are linked below.

### epoll_create/epoll_create1

```d
extern(C) HANDLE epoll_create(int size) nothrow @nogc;
extern(C) HANDLE epoll_create1(int flags) nothrow @nogc;
```

* Create a new epoll instance (port).
* `size` is ignored but must be greater than zero.
* `flags` must be zero as there are no supported flags.
* Returns `null` on failure.
* [Linux man page][man epoll_create]

### epoll_close

```d
extern(C) int epoll_close(HANDLE ephnd) nothrow @nogc;
```

* Close an epoll port.
* Do not attempt to close the epoll port with `close()`,
  `CloseHandle()` or `closesocket()`.

### epoll_ctl

```d
extern(C) int epoll_ctl(HANDLE ephnd,
                        int op,
                        SOCKET sock,
                        epoll_event* event) nothrow @nogc;
```

* Control which socket events are monitored by an epoll port.
* `ephnd` must be a HANDLE created by
  [`epoll_create()`](#epoll_createepoll_create1) or
  [`epoll_create1()`](#epoll_createepoll_create1).
* `op` must be one of `EPOLL_CTL_ADD`, `EPOLL_CTL_MOD`, `EPOLL_CTL_DEL`
  (use the constants from this module; their numeric values differ from
  Linux, see [How to use](#how-to-use)).
* `sock` must be a valid socket created by [`socket()`][msdn socket],
  [`WSASocket()`][msdn wsasocket], or [`accept()`][msdn accept].
* `event` is a pointer to an [`epoll_event`](#struct-epoll_event).<br>
  If `op` is `EPOLL_CTL_DEL` then `event` is ignored and may be `null`.
* Returns 0 on success, -1 on failure.
* It is recommended to always explicitly remove a socket from its epoll
  set using `EPOLL_CTL_DEL` *before* closing it.<br>
  As on Linux, closed sockets are automatically removed from the epoll set, but
  wepoll may not be able to detect that a socket was closed until the next call
  to [`epoll_wait()`](#epoll_wait).
* [Linux man page][man epoll_ctl]

### epoll_wait

```d
extern(C) int epoll_wait(HANDLE ephnd,
                         epoll_event* events,
                         int maxevents,
                         int timeout) nothrow @nogc;
```

* Receive socket events from an epoll port.
* `events` points to a caller-allocated array of
  [`epoll_event`](#struct-epoll_event) values that will receive the
  reported events; pass `events.ptr` when using a D array.
* `maxevents` is the maximum number of events that will be written to the
  `events` array, and must be greater than zero. For a fixed-size D array,
  pass `cast(int) events.length`.
* `timeout` specifies whether to block when no events are immediately available.
  - `<0` block indefinitely
  - `0`  report any events that are already waiting, but don't block
  - `≥1` block for at most N milliseconds
* Return value:
  - `-1` an error occurred
  - `0`  timed out without any events to report
  - `≥1` the number of events stored in the `events` buffer
* [Linux man page][man epoll_wait]

### struct epoll_event

```d
union epoll_data_t
{
    void*  ptr;
    int    fd;
    uint   u32;
    ulong  u64;
    SOCKET sock;        // Windows specific
    HANDLE hnd;         // Windows specific
}

struct epoll_event
{
    uint         events;  // Bit mask of EPOLL_* events and flags
    epoll_data_t data;    // User data, returned unmodified
}
```

* The `events` field is a bit mask containing the events being
  monitored/reported, and optional flags.<br>
  Flags are accepted by [`epoll_ctl()`](#epoll_ctl), but they are not reported
  back by [`epoll_wait()`](#epoll_wait).
* The `data` field can be used to associate application-specific information
  with a socket; its value will be returned unmodified by
  [`epoll_wait()`](#epoll_wait).
* [Linux man page][man epoll_ctl]

| Event         | Description                                                          |
|---------------|----------------------------------------------------------------------|
| `EPOLLIN`     | incoming data available, or incoming connection ready to be accepted |
| `EPOLLOUT`    | ready to send data, or outgoing connection successfully established  |
| `EPOLLRDHUP`  | remote peer initiated graceful socket shutdown                       |
| `EPOLLPRI`    | out-of-band data available for reading                               |
| `EPOLLERR`    | socket error<sup>1</sup>                                             |
| `EPOLLHUP`    | socket hang-up<sup>1</sup>                                           |
| `EPOLLRDNORM` | same as `EPOLLIN`                                                    |
| `EPOLLRDBAND` | same as `EPOLLPRI`                                                   |
| `EPOLLWRNORM` | same as `EPOLLOUT`                                                   |
| `EPOLLWRBAND` | same as `EPOLLOUT`                                                   |
| `EPOLLMSG`    | never reported                                                       |

| Flag             | Description                       |
|------------------|-----------------------------------|
| `EPOLLONESHOT`   | report event(s) only once         |
| `EPOLLET`        | not supported by wepoll           |
| `EPOLLEXCLUSIVE` | not supported by wepoll           |
| `EPOLLWAKEUP`    | not supported by wepoll           |

The flag constants that wepoll does support are declared in this module as
manifest constants; unsupported flags such as `EPOLLET` are not declared.

<sup>1</sup>: the `EPOLLERR` and `EPOLLHUP` events may always be reported by
[`epoll_wait()`](#epoll_wait), regardless of the event mask that was passed to
[`epoll_ctl()`](#epoll_ctl).


[man epoll]:        http://man7.org/linux/man-pages/man7/epoll.7.html
[man epoll_create]: http://man7.org/linux/man-pages/man2/epoll_create.2.html
[man epoll_ctl]:    http://man7.org/linux/man-pages/man2/epoll_ctl.2.html
[man epoll_wait]:   http://man7.org/linux/man-pages/man2/epoll_wait.2.html
[msdn accept]:      https://msdn.microsoft.com/en-us/library/windows/desktop/ms737526(v=vs.85).aspx
[msdn socket]:      https://msdn.microsoft.com/en-us/library/windows/desktop/ms740506(v=vs.85).aspx
[msdn wsasocket]:   https://msdn.microsoft.com/en-us/library/windows/desktop/ms742212(v=vs.85).aspx
[select scale]:     https://daniel.haxx.se/docs/poll-vs-select.html
[wsapoll broken]:   https://daniel.haxx.se/blog/2012/10/10/wsapoll-is-broken/

## License

See LICENSE.
