/*
 * wepoll - epoll for Windows
 * https://github.com/piscisaureus/wepoll
 *
 * Copyright 2012-2020, Bert Belder <bertbelder@gmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *   * Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *
 *   * Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * ---------------------------------------------------------------------------
 * D port, based on the original C implementation by Bert Belder.
 *
 * The public API intentionally mirrors `core.sys.linux.epoll` so that code
 * written against the Linux epoll module can be compiled on Windows with
 * minimal changes.  A few Windows-specific additions are kept (the epoll port
 * is a HANDLE rather than a file descriptor, `epoll_close()` exists, and
 * epoll_data_t has `sock`/`hnd` members), exactly like the original wepoll.h.
 *
 * Note: wepoll.h numbers the control operations as `EPOLL_CTL_ADD = 1`,
 * `EPOLL_CTL_MOD = 2`, `EPOLL_CTL_DEL = 3` (Linux uses ADD/DEL/MOD order).
 * Use the constants provided by this module rather than hard-coded numbers.
 *
 * Example:
 * ---
 * import wepoll;
 * import core.sys.windows.winsock2;
 *
 * HANDLE ep = epoll_create1(0);
 * epoll_event ev;
 * ev.events = EPOLLIN | EPOLLRDHUP;
 * ev.data.sock = listener;
 * epoll_ctl(ep, EPOLL_CTL_ADD, listener, &ev);
 *
 * epoll_event[64] events;
 * int n = epoll_wait(ep, events.ptr, events.length, -1);
 * foreach (i; 0 .. n)
 *     handle(events[i].data.sock, events[i].events);
 * epoll_close(ep);
 * ---
 */

module wepoll;

version (Windows):

/* ------------------------------------------------------------------------- */
/* Imports                                                                   */
/* ------------------------------------------------------------------------- */

import core.atomic : atomicExchange, atomicOp;
import core.stdc.errno;          // errno and the E* error codes
import core.stdc.stdlib : abort, free, malloc;
import core.stdc.string : memset;

import core.sys.windows.ntdef : NTSTATUS, OBJECT_ATTRIBUTES, UNICODE_STRING,
    NT_SUCCESS;
import core.sys.windows.windef : BOOL, DWORD, FARPROC, HANDLE, HMODULE,
    LPCSTR, LPCWSTR, PWSTR;
import core.sys.windows.winbase : CRITICAL_SECTION,
    INFINITE, INVALID_HANDLE_VALUE, CloseHandle, CreateIoCompletionPort,
    DeleteCriticalSection, EnterCriticalSection, GetHandleInformation,
    GetLastError, GetModuleHandleW, GetProcAddress, InitializeCriticalSection,
    LeaveCriticalSection, SetLastError;
import core.sys.windows.winerror : ERROR_ACCESS_DENIED, ERROR_ALREADY_EXISTS,
    ERROR_BAD_COMMAND, ERROR_BAD_EXE_FORMAT, ERROR_BAD_LENGTH,
    ERROR_BAD_NETPATH, ERROR_BAD_NET_NAME, ERROR_BAD_NET_RESP,
    ERROR_BAD_PATHNAME, ERROR_BROKEN_PIPE, ERROR_CANNOT_MAKE,
    ERROR_COMMITMENT_LIMIT, ERROR_CONNECTION_ABORTED, ERROR_CONNECTION_ACTIVE,
    ERROR_CONNECTION_REFUSED, ERROR_CRC, ERROR_DIR_NOT_EMPTY, ERROR_DISK_FULL,
    ERROR_DUP_NAME, ERROR_FILENAME_EXCED_RANGE, ERROR_FILE_NOT_FOUND,
    ERROR_GEN_FAILURE, ERROR_GRACEFUL_DISCONNECT, ERROR_HOST_DOWN,
    ERROR_HOST_UNREACHABLE, ERROR_INSUFFICIENT_BUFFER, ERROR_INVALID_ADDRESS,
    ERROR_INVALID_FUNCTION, ERROR_INVALID_HANDLE, ERROR_INVALID_NETNAME,
    ERROR_INVALID_PARAMETER, ERROR_INVALID_USER_BUFFER, ERROR_IO_PENDING,
    ERROR_LOCK_VIOLATION, ERROR_MORE_DATA, ERROR_NETNAME_DELETED,
    ERROR_NETWORK_ACCESS_DENIED, ERROR_NETWORK_BUSY, ERROR_NETWORK_UNREACHABLE,
    ERROR_NOACCESS, ERROR_NONPAGED_SYSTEM_RESOURCES, ERROR_NOT_ENOUGH_MEMORY,
    ERROR_NOT_ENOUGH_QUOTA, ERROR_NOT_FOUND, ERROR_NOT_LOCKED, ERROR_NOT_READY,
    ERROR_NOT_SAME_DEVICE, ERROR_NOT_SUPPORTED, ERROR_NO_MORE_FILES,
    ERROR_NO_SYSTEM_RESOURCES, ERROR_OPERATION_ABORTED, ERROR_OUT_OF_PAPER,
    ERROR_PAGED_SYSTEM_RESOURCES, ERROR_PAGEFILE_QUOTA, ERROR_PATH_NOT_FOUND,
    ERROR_PIPE_NOT_CONNECTED, ERROR_PORT_UNREACHABLE, ERROR_PROTOCOL_UNREACHABLE,
    ERROR_REM_NOT_LIST, ERROR_REQUEST_ABORTED, ERROR_REQ_NOT_ACCEP,
    ERROR_SECTOR_NOT_FOUND, ERROR_SEM_TIMEOUT, ERROR_SHARING_VIOLATION,
    ERROR_TOO_MANY_NAMES, ERROR_TOO_MANY_OPEN_FILES, ERROR_UNEXP_NET_ERR,
    ERROR_WAIT_NO_CHILDREN, ERROR_WORKING_SET_QUOTA, ERROR_WRITE_PROTECT,
    ERROR_WRONG_DISK, WAIT_TIMEOUT;
import core.sys.windows.winnt : ACCESS_MASK, FILE_OPEN, FILE_SHARE_READ,
    FILE_SHARE_WRITE, LARGE_INTEGER, STANDARD_RIGHTS_REQUIRED, SYNCHRONIZE;
import core.sys.windows.winsock2 : INVALID_SOCKET, SOCKET, SOCKET_ERROR,
    WSAStartup, WSADATA, WSAIoctl, WSAEACCES, WSAEADDRINUSE, WSAEADDRNOTAVAIL,
    WSAEAFNOSUPPORT, WSAECONNABORTED, WSAECONNREFUSED, WSAECONNRESET,
    WSAEFAULT, WSAEHOSTDOWN, WSAEHOSTUNREACH, WSAEINPROGRESS,
    WSAEINTR, WSAEINVAL, WSAEISCONN, WSAEMSGSIZE, WSAENETDOWN, WSAENETRESET,
    WSAENETUNREACH, WSAENOBUFS, WSAENOTCONN, WSAENOTSOCK, WSAEOPNOTSUPP,
    WSAEPROCLIM, WSAESHUTDOWN, WSAETIMEDOUT, WSAEWOULDBLOCK,
    WSANOTINITIALISED, WSASYSNOTREADY, WSAVERNOTSUPPORTED;

pragma(lib, "Kernel32");
pragma(lib, "Ws2_32");

/* ------------------------------------------------------------------------- */
/* Public API (same shape as core.sys.linux.epoll + wepoll.h additions)      */
/* ------------------------------------------------------------------------- */

/// Epoll event flags.
enum : uint
{
    EPOLLIN      = 1u << 0,
    EPOLLPRI     = 1u << 1,
    EPOLLOUT     = 1u << 2,
    EPOLLERR     = 1u << 3,
    EPOLLHUP     = 1u << 4,
    EPOLLRDNORM  = 1u << 6,
    EPOLLRDBAND  = 1u << 7,
    EPOLLWRNORM  = 1u << 8,
    EPOLLWRBAND  = 1u << 9,
    EPOLLMSG     = 1u << 10,  // never reported
    EPOLLRDHUP   = 1u << 13,
    EPOLLONESHOT = 1u << 31,
}

/// Valid opcodes for the `op` parameter of `epoll_ctl`.
enum
{
    EPOLL_CTL_ADD = 1,  /// Add a socket to the interface.
    EPOLL_CTL_MOD = 2,  /// Change the events monitored for a socket.
    EPOLL_CTL_DEL = 3,  /// Remove a socket from the interface.
}

/// User data associated with a socket (mirrors the C `epoll_data_t`).
union epoll_data_t
{
    void*  ptr;
    int    fd;
    uint   u32;
    ulong  u64;
    SOCKET sock;        /// Windows specific.
    HANDLE hnd;         /// Windows specific.
}

/// The event structure passed to `epoll_ctl` and returned by `epoll_wait`.
struct epoll_event
{
    uint         events;  /// Bit mask of EPOLL_* events and flags.
    epoll_data_t data;    /// User data, returned unmodified by epoll_wait.
}

/* `epoll_data_t` contains a 64-bit field, so the exact size/alignment depends
 * on the platform ABI; only require that both members fit. */
static assert(epoll_event.events.offsetof == 0 &&
              epoll_event.sizeof >= uint.sizeof + size_t.sizeof);

/**
 * Creates a new epoll instance (port).
 *
 * Params:
 *   size = ignored, but must be greater than zero.
 * Returns: the port HANDLE, or null on failure (errno and GetLastError are set).
 */
extern(C) HANDLE epoll_create(int size) nothrow @nogc
{
    if (size <= 0)
        return returnSetError!HANDLE(null, ERROR_INVALID_PARAMETER);
    return epollCreate();
}

/**
 * Creates a new epoll instance (port).
 *
 * Params:
 *   flags = must be zero; no flags are currently supported.
 * Returns: the port HANDLE, or null on failure.
 */
extern(C) HANDLE epoll_create1(int flags) nothrow @nogc
{
    if (flags != 0)
        return returnSetError!HANDLE(null, ERROR_INVALID_PARAMETER);
    return epollCreate();
}

/**
 * Closes an epoll port.  Do not use CloseHandle(), close() or closesocket()
 * on a port returned by epoll_create()/epoll_create1().
 *
 * Returns: 0 on success, -1 on failure.
 */
extern(C) int epoll_close(HANDLE ephnd) nothrow @nogc
{
    TsTreeNode* treeNode;
    PortState* portState;

    if (init() < 0)
        return -1;

    treeNode = tsTreeDelAndRef(&epollHandleTree, cast(size_t) ephnd);
    if (treeNode is null)
    {
        errSetWinError(ERROR_INVALID_PARAMETER);
        goto err;
    }

    portState = portStateFromHandleTreeNode(treeNode);
    portClose(portState);
    tsTreeNodeUnrefAndDestroy(treeNode);

    return portDelete(portState);

err:
    errCheckHandle(ephnd);
    return -1;
}

/**
 * Controls which socket events are monitored by an epoll port.
 *
 * Params:
 *   ephnd = a port returned by epoll_create()/epoll_create1()
 *   op    = one of EPOLL_CTL_ADD, EPOLL_CTL_MOD, EPOLL_CTL_DEL
 *   sock  = a valid socket
 *   event = pointer to the event description; ignored (and may be null) for
 *           EPOLL_CTL_DEL
 * Returns: 0 on success, -1 on failure.
 */
extern(C) int epoll_ctl(HANDLE ephnd, int op, SOCKET sock,
                        epoll_event* event) nothrow @nogc
{
    TsTreeNode* treeNode;
    PortState* portState;
    int r;

    if (init() < 0)
        return -1;

    treeNode = tsTreeFindAndRef(&epollHandleTree, cast(size_t) ephnd);
    if (treeNode is null)
    {
        errSetWinError(ERROR_INVALID_PARAMETER);
        goto err;
    }

    portState = portStateFromHandleTreeNode(treeNode);
    r = portCtl(portState, op, sock, event);
    tsTreeNodeUnref(treeNode);

    if (r < 0)
        goto err;
    return 0;

err:
    /* As on Linux, EBADF takes priority over other errors. */
    errCheckHandle(ephnd);
    errCheckHandle(cast(HANDLE) sock);
    return -1;
}

/**
 * Waits for events on an epoll port.
 *
 * Params:
 *   ephnd      = a port returned by epoll_create()/epoll_create1()
 *   events     = caller-allocated array that receives the reported events
 *   maxevents  = maximum number of events to write to `events` (must be > 0)
 *   timeout    = -1 block indefinitely, 0 don't block, > 0 wait up to N ms
 * Returns: the number of events, 0 on timeout, -1 on error.
 */
extern(C) int epoll_wait(HANDLE ephnd, epoll_event* events,
                         int maxevents, int timeout) nothrow @nogc
{
    TsTreeNode* treeNode;
    PortState* portState;
    int numEvents;

    if (maxevents <= 0)
        return returnSetError!int(-1, ERROR_INVALID_PARAMETER);
    if (init() < 0)
        return -1;

    treeNode = tsTreeFindAndRef(&epollHandleTree, cast(size_t) ephnd);
    if (treeNode is null)
    {
        errSetWinError(ERROR_INVALID_PARAMETER);
        goto err;
    }

    portState = portStateFromHandleTreeNode(treeNode);
    numEvents = portWait(portState, events, maxevents, timeout);
    tsTreeNodeUnref(treeNode);

    if (numEvents < 0)
        goto err;
    return numEvents;

err:
    errCheckHandle(ephnd);
    return -1;
}

/* ------------------------------------------------------------------------- */
/* Internal helpers: Win32 declarations not present in druntime              */
/* ------------------------------------------------------------------------- */

private extern(Windows) nothrow @nogc
{
    struct SRWLOCK { void* ptr; }

    void InitializeSRWLock(SRWLOCK*);
    void AcquireSRWLockExclusive(SRWLOCK*);
    void ReleaseSRWLockExclusive(SRWLOCK*);
    void AcquireSRWLockShared(SRWLOCK*);
    void ReleaseSRWLockShared(SRWLOCK*);

    struct OVERLAPPED_ENTRY
    {
        size_t   lpCompletionKey;
        void*    lpOverlapped;
        size_t   internal;
        DWORD    dwNumberOfBytesTransferred;
    }

    BOOL GetQueuedCompletionStatusEx(HANDLE, OVERLAPPED_ENTRY*, DWORD,
                                     DWORD*, DWORD, BOOL);
    BOOL SetFileCompletionNotificationModes(HANDLE, ubyte);
    ulong GetTickCount64();

    struct INIT_ONCE { void* ptr; }
    extern(Windows) alias BOOL function(INIT_ONCE*, void*, void**)
        nothrow @nogc InitOnceCallback;
    BOOL InitOnceExecuteOnce(INIT_ONCE*, InitOnceCallback, void*, void**);
}

private enum DWORD FILE_SKIP_SET_EVENT_ON_HANDLE = 0x00000002;

/* ------------------------------------------------------------------------- */
/* Internal helpers: NT types and dynamically imported ntdll functions        */
/* ------------------------------------------------------------------------- */

private enum NTSTATUS STATUS_SUCCESS   = 0x00000000;
private enum NTSTATUS STATUS_PENDING   = 0x00000103;
private enum NTSTATUS STATUS_CANCELLED = cast(NTSTATUS) 0xC0000120L;
private enum NTSTATUS STATUS_NOT_FOUND = cast(NTSTATUS) 0xC0000225L;

private enum uint FILE_OPEN_DISPOSITION = FILE_OPEN;
private enum DWORD KEYEDEVENT_WAIT = 0x00000001;
private enum DWORD KEYEDEVENT_WAKE = 0x00000002;
private enum DWORD KEYEDEVENT_ALL_ACCESS =
    STANDARD_RIGHTS_REQUIRED | KEYEDEVENT_WAIT | KEYEDEVENT_WAKE;

private struct IO_STATUS_BLOCK
{
    NTSTATUS status;
    size_t   information;
}

private enum DWORD WSAEDISCON = 10032; /// WSABASEERR + 32 (not in all headers)

private extern(Windows) alias void function(void*, IO_STATUS_BLOCK*, uint)
    nothrow @nogc PIO_APC_ROUTINE;

private struct AFD_POLL_HANDLE_INFO
{
    HANDLE   handle;
    uint     events;
    NTSTATUS status;
}

private struct AFD_POLL_INFO
{
    LARGE_INTEGER       timeout;
    uint                numberOfHandles;
    uint                exclusive;
    AFD_POLL_HANDLE_INFO[1] handles;
}

static assert(IO_STATUS_BLOCK.sizeof == (size_t.sizeof == 8 ? 16 : 8),
    "unexpected IO_STATUS_BLOCK layout");

private extern(Windows) alias NTSTATUS function(
    HANDLE, IO_STATUS_BLOCK*, IO_STATUS_BLOCK*) nothrow @nogc NtCancelIoFileExFn;
private extern(Windows) alias NTSTATUS function(
    HANDLE*, ACCESS_MASK, OBJECT_ATTRIBUTES*, IO_STATUS_BLOCK*,
    LARGE_INTEGER*, uint, uint, uint, uint, void*, uint) nothrow @nogc
    NtCreateFileFn;
private extern(Windows) alias NTSTATUS function(
    HANDLE*, ACCESS_MASK, OBJECT_ATTRIBUTES*, uint) nothrow @nogc
    NtCreateKeyedEventFn;
private extern(Windows) alias NTSTATUS function(
    HANDLE, HANDLE, PIO_APC_ROUTINE, void*, IO_STATUS_BLOCK*, uint,
    void*, uint, void*, uint) nothrow @nogc NtDeviceIoControlFileFn;
private extern(Windows) alias NTSTATUS function(
    HANDLE, void*, BOOL, LARGE_INTEGER*) nothrow @nogc NtReleaseKeyedEventFn;
private extern(Windows) alias NTSTATUS function(
    HANDLE, void*, BOOL, LARGE_INTEGER*) nothrow @nogc NtWaitForKeyedEventFn;
private extern(Windows) alias uint function(NTSTATUS) nothrow @nogc
    RtlNtStatusToDosErrorFn;

private __gshared NtCancelIoFileExFn        pNtCancelIoFileEx;
private __gshared NtCreateFileFn            pNtCreateFile;
private __gshared NtCreateKeyedEventFn      pNtCreateKeyedEvent;
private __gshared NtDeviceIoControlFileFn   pNtDeviceIoControlFile;
private __gshared NtReleaseKeyedEventFn     pNtReleaseKeyedEvent;
private __gshared NtWaitForKeyedEventFn     pNtWaitForKeyedEvent;
private __gshared RtlNtStatusToDosErrorFn   pRtlNtStatusToDosError;

private enum uint IOCTL_AFD_POLL = 0x00012024;

private enum : uint
{
    AFD_POLL_RECEIVE           = 0x0001,
    AFD_POLL_RECEIVE_EXPEDITED = 0x0002,
    AFD_POLL_SEND              = 0x0004,
    AFD_POLL_DISCONNECT        = 0x0008,
    AFD_POLL_ABORT             = 0x0010,
    AFD_POLL_LOCAL_CLOSE       = 0x0020,
    AFD_POLL_ACCEPT            = 0x0080,
    AFD_POLL_CONNECT_FAIL      = 0x0100,
}

private enum uint SIO_BSP_HANDLE_POLL = 0x4800001D;
private enum uint SIO_BASE_HANDLE     = 0x48000022;

/* ------------------------------------------------------------------------- */
/* Internal helpers: error handling                                          */
/* ------------------------------------------------------------------------- */

private T returnSetError(T)(T value, DWORD error) nothrow @nogc
{
    errSetWinError(error);
    return value;
}

private T returnMapError(T)(T value) nothrow @nogc
{
    errMapWinError();
    return value;
}

private int mapWinErrorToErrno(DWORD error) nothrow @nogc
{
    switch (error)
    {
        case ERROR_ACCESS_DENIED:           return EACCES;
        case ERROR_ALREADY_EXISTS:          return EEXIST;
        case ERROR_BAD_COMMAND:             return EACCES;
        case ERROR_BAD_EXE_FORMAT:          return ENOEXEC;
        case ERROR_BAD_LENGTH:              return EACCES;
        case ERROR_BAD_NETPATH:             return ENOENT;
        case ERROR_BAD_NET_NAME:            return ENOENT;
        case ERROR_BAD_NET_RESP:            return ENETDOWN;
        case ERROR_BAD_PATHNAME:            return ENOENT;
        case ERROR_BROKEN_PIPE:             return EPIPE;
        case ERROR_CANNOT_MAKE:             return EACCES;
        case ERROR_COMMITMENT_LIMIT:        return ENOMEM;
        case ERROR_CONNECTION_ABORTED:      return ECONNABORTED;
        case ERROR_CONNECTION_ACTIVE:       return EISCONN;
        case ERROR_CONNECTION_REFUSED:      return ECONNREFUSED;
        case ERROR_CRC:                     return EACCES;
        case ERROR_DIR_NOT_EMPTY:           return ENOTEMPTY;
        case ERROR_DISK_FULL:               return ENOSPC;
        case ERROR_DUP_NAME:                return EADDRINUSE;
        case ERROR_FILENAME_EXCED_RANGE:    return ENOENT;
        case ERROR_FILE_NOT_FOUND:          return ENOENT;
        case ERROR_GEN_FAILURE:             return EACCES;
        case ERROR_GRACEFUL_DISCONNECT:     return EPIPE;
        case ERROR_HOST_DOWN:               return EHOSTUNREACH;
        case ERROR_HOST_UNREACHABLE:        return EHOSTUNREACH;
        case ERROR_INSUFFICIENT_BUFFER:     return EFAULT;
        case ERROR_INVALID_ADDRESS:         return EADDRNOTAVAIL;
        case ERROR_INVALID_FUNCTION:        return EINVAL;
        case ERROR_INVALID_HANDLE:          return EBADF;
        case ERROR_INVALID_NETNAME:         return EADDRNOTAVAIL;
        case ERROR_INVALID_PARAMETER:       return EINVAL;
        case ERROR_INVALID_USER_BUFFER:     return EMSGSIZE;
        case ERROR_IO_PENDING:              return EINPROGRESS;
        case ERROR_LOCK_VIOLATION:          return EACCES;
        case ERROR_MORE_DATA:               return EMSGSIZE;
        case ERROR_NETNAME_DELETED:         return ECONNABORTED;
        case ERROR_NETWORK_ACCESS_DENIED:   return EACCES;
        case ERROR_NETWORK_BUSY:            return ENETDOWN;
        case ERROR_NETWORK_UNREACHABLE:     return ENETUNREACH;
        case ERROR_NOACCESS:                return EFAULT;
        case ERROR_NONPAGED_SYSTEM_RESOURCES: return ENOMEM;
        case ERROR_NOT_ENOUGH_MEMORY:       return ENOMEM;
        case ERROR_NOT_ENOUGH_QUOTA:        return ENOMEM;
        case ERROR_NOT_FOUND:               return ENOENT;
        case ERROR_NOT_LOCKED:              return EACCES;
        case ERROR_NOT_READY:               return EACCES;
        case ERROR_NOT_SAME_DEVICE:         return EXDEV;
        case ERROR_NOT_SUPPORTED:           return ENOTSUP;
        case ERROR_NO_MORE_FILES:           return ENOENT;
        case ERROR_NO_SYSTEM_RESOURCES:     return ENOMEM;
        case ERROR_OPERATION_ABORTED:       return EINTR;
        case ERROR_OUT_OF_PAPER:            return EACCES;
        case ERROR_PAGED_SYSTEM_RESOURCES:  return ENOMEM;
        case ERROR_PAGEFILE_QUOTA:          return ENOMEM;
        case ERROR_PATH_NOT_FOUND:          return ENOENT;
        case ERROR_PIPE_NOT_CONNECTED:      return EPIPE;
        case ERROR_PORT_UNREACHABLE:        return ECONNRESET;
        case ERROR_PROTOCOL_UNREACHABLE:    return ENETUNREACH;
        case ERROR_REM_NOT_LIST:            return ECONNREFUSED;
        case ERROR_REQUEST_ABORTED:         return EINTR;
        case ERROR_REQ_NOT_ACCEP:           return EWOULDBLOCK;
        case ERROR_SECTOR_NOT_FOUND:        return EACCES;
        case ERROR_SEM_TIMEOUT:             return ETIMEDOUT;
        case ERROR_SHARING_VIOLATION:       return EACCES;
        case ERROR_TOO_MANY_NAMES:          return ENOMEM;
        case ERROR_TOO_MANY_OPEN_FILES:     return EMFILE;
        case ERROR_UNEXP_NET_ERR:           return ECONNABORTED;
        case ERROR_WAIT_NO_CHILDREN:        return ECHILD;
        case ERROR_WORKING_SET_QUOTA:       return ENOMEM;
        case ERROR_WRITE_PROTECT:           return EACCES;
        case ERROR_WRONG_DISK:              return EACCES;
        case WSAEACCES:                     return EACCES;
        case WSAEADDRINUSE:                 return EADDRINUSE;
        case WSAEADDRNOTAVAIL:              return EADDRNOTAVAIL;
        case WSAEAFNOSUPPORT:               return EAFNOSUPPORT;
        case WSAECONNABORTED:               return ECONNABORTED;
        case WSAECONNREFUSED:               return ECONNREFUSED;
        case WSAECONNRESET:                 return ECONNRESET;
        case WSAEDISCON:                    return EPIPE;
        case WSAEFAULT:                     return EFAULT;
        case WSAEHOSTDOWN:                  return EHOSTUNREACH;
        case WSAEHOSTUNREACH:               return EHOSTUNREACH;
        case WSAEINPROGRESS:                return EBUSY;
        case WSAEINTR:                      return EINTR;
        case WSAEINVAL:                     return EINVAL;
        case WSAEISCONN:                    return EISCONN;
        case WSAEMSGSIZE:                   return EMSGSIZE;
        case WSAENETDOWN:                   return ENETDOWN;
        case WSAENETRESET:                  return EHOSTUNREACH;
        case WSAENETUNREACH:                return ENETUNREACH;
        case WSAENOBUFS:                    return ENOMEM;
        case WSAENOTCONN:                   return ENOTCONN;
        case WSAENOTSOCK:                   return ENOTSOCK;
        case WSAEOPNOTSUPP:                 return EOPNOTSUPP;
        case WSAEPROCLIM:                   return ENOMEM;
        case WSAESHUTDOWN:                  return EPIPE;
        case WSAETIMEDOUT:                  return ETIMEDOUT;
        case WSAEWOULDBLOCK:                return EWOULDBLOCK;
        case WSANOTINITIALISED:             return ENETDOWN;
        case WSASYSNOTREADY:                return ENETDOWN;
        case WSAVERNOTSUPPORTED:            return ENOSYS;
        default:                            return EINVAL;
    }
}

private void errMapWinError() nothrow @nogc
{
    errno = mapWinErrorToErrno(GetLastError());
}

private void errSetWinError(DWORD error) nothrow @nogc
{
    SetLastError(error);
    errno = mapWinErrorToErrno(error);
}

private int errCheckHandle(HANDLE handle) nothrow @nogc
{
    DWORD flags;
    if (handle == INVALID_HANDLE_VALUE)
        return returnSetError!int(-1, ERROR_INVALID_HANDLE);
    if (!GetHandleInformation(handle, &flags))
        return returnMapError!int(-1);
    return 0;
}

/* ------------------------------------------------------------------------- */
/* AFD device helpers                                                        */
/* ------------------------------------------------------------------------- */

private __gshared wchar[17] afdDeviceNameBuf;
private __gshared UNICODE_STRING afdDeviceName;
private __gshared OBJECT_ATTRIBUTES afdDeviceAttributes;

private void afdInitStatics() nothrow @nogc
{
    /* RTL_CONSTANT_STRING(L"\\Device\\Afd\\Wepoll") */
    afdDeviceNameBuf[] = "\\Device\\Afd\\Wepoll\0"w;
    afdDeviceName.Length = cast(ushort)(16 * wchar.sizeof);
    afdDeviceName.MaximumLength = cast(ushort)(17 * wchar.sizeof);
    afdDeviceName.Buffer = afdDeviceNameBuf.ptr;

    afdDeviceAttributes.Length = OBJECT_ATTRIBUTES.sizeof;
    afdDeviceAttributes.RootDirectory = null;
    afdDeviceAttributes.ObjectName = &afdDeviceName;
    afdDeviceAttributes.Attributes = 0;
    afdDeviceAttributes.SecurityDescriptor = null;
    afdDeviceAttributes.SecurityQualityOfService = null;
}

private int afdCreateDeviceHandle(HANDLE iocpHandle,
                                  HANDLE* afdDeviceHandleOut) nothrow @nogc
{
    HANDLE afdDeviceHandle;
    IO_STATUS_BLOCK iosb;
    NTSTATUS status;

    /* Opening \Device\Afd without extended attributes gives a handle that can
     * talk to the AFD driver, but that has no associated endpoint (not a
     * socket). */
    status = pNtCreateFile(&afdDeviceHandle,
                           cast(ACCESS_MASK) SYNCHRONIZE,
                           &afdDeviceAttributes,
                           &iosb,
                           null,
                           0,
                           FILE_SHARE_READ | FILE_SHARE_WRITE,
                           FILE_OPEN_DISPOSITION,
                           0,
                           null,
                           0);
    if (status != STATUS_SUCCESS)
        return returnSetError!int(-1, pRtlNtStatusToDosError(status));

    if (CreateIoCompletionPort(afdDeviceHandle, iocpHandle, 0, 0) is null)
        goto error;

    if (!SetFileCompletionNotificationModes(afdDeviceHandle,
                                            FILE_SKIP_SET_EVENT_ON_HANDLE))
        goto error;

    *afdDeviceHandleOut = afdDeviceHandle;
    return 0;

error:
    CloseHandle(afdDeviceHandle);
    return returnMapError!int(-1);
}

private int afdPoll(HANDLE afdDeviceHandle, AFD_POLL_INFO* pollInfo,
                    IO_STATUS_BLOCK* ioStatusBlock) nothrow @nogc
{
    NTSTATUS status;

    assert(ioStatusBlock !is null);
    ioStatusBlock.status = STATUS_PENDING;
    status = pNtDeviceIoControlFile(afdDeviceHandle,
                                    null,
                                    null,
                                    ioStatusBlock,
                                    ioStatusBlock,
                                    IOCTL_AFD_POLL,
                                    pollInfo,
                                    AFD_POLL_INFO.sizeof,
                                    pollInfo,
                                    AFD_POLL_INFO.sizeof);

    if (status == STATUS_SUCCESS)
        return 0;
    else if (status == STATUS_PENDING)
        return returnSetError!int(-1, ERROR_IO_PENDING);
    else
        return returnSetError!int(-1, pRtlNtStatusToDosError(status));
}

private int afdCancelPoll(HANDLE afdDeviceHandle,
                          IO_STATUS_BLOCK* ioStatusBlock) nothrow @nogc
{
    NTSTATUS cancelStatus;
    IO_STATUS_BLOCK cancelIosb;

    if (ioStatusBlock.status != STATUS_PENDING)
        return 0;

    cancelStatus = pNtCancelIoFileEx(afdDeviceHandle, ioStatusBlock, &cancelIosb);

    /* NtCancelIoFileEx() may return STATUS_NOT_FOUND if the operation completed
     * just before the call; that is not an error. */
    if (cancelStatus == STATUS_SUCCESS || cancelStatus == STATUS_NOT_FOUND)
        return 0;
    return returnSetError!int(-1, pRtlNtStatusToDosError(cancelStatus));
}

/* ------------------------------------------------------------------------- */
/* Global initialization                                                     */
/* ------------------------------------------------------------------------- */

private __gshared bool initDone;
private __gshared INIT_ONCE initOnce;
private __gshared HANDLE reflockKeyedEvent;

private extern(Windows) BOOL initOnceCallback(INIT_ONCE* once, void* parameter,
                                              void** context) nothrow @nogc
{
    /* Initialization order matters. */
    if (wsGlobalInit() < 0 || ntGlobalInit() < 0 ||
        reflockGlobalInit() < 0 || epollGlobalInit() < 0)
        return false;

    initDone = true;
    return true;
}

private int init() nothrow @nogc
{
    if (!initDone &&
        !InitOnceExecuteOnce(&initOnce, &initOnceCallback, null, null))
        return -1;
    return 0;
}

private int ntGlobalInit() nothrow @nogc
{
    HMODULE ntdll = GetModuleHandleW("ntdll.dll"w.ptr);
    if (ntdll is null)
        return -1;

    pNtCancelIoFileEx = cast(NtCancelIoFileExFn)
        GetProcAddress(ntdll, "NtCancelIoFileEx");
    pNtCreateFile = cast(NtCreateFileFn) GetProcAddress(ntdll, "NtCreateFile");
    pNtCreateKeyedEvent = cast(NtCreateKeyedEventFn)
        GetProcAddress(ntdll, "NtCreateKeyedEvent");
    pNtDeviceIoControlFile = cast(NtDeviceIoControlFileFn)
        GetProcAddress(ntdll, "NtDeviceIoControlFile");
    pNtReleaseKeyedEvent = cast(NtReleaseKeyedEventFn)
        GetProcAddress(ntdll, "NtReleaseKeyedEvent");
    pNtWaitForKeyedEvent = cast(NtWaitForKeyedEventFn)
        GetProcAddress(ntdll, "NtWaitForKeyedEvent");
    pRtlNtStatusToDosError = cast(RtlNtStatusToDosErrorFn)
        GetProcAddress(ntdll, "RtlNtStatusToDosError");

    if (pNtCancelIoFileEx is null || pNtCreateFile is null ||
        pNtCreateKeyedEvent is null || pNtDeviceIoControlFile is null ||
        pNtReleaseKeyedEvent is null || pNtWaitForKeyedEvent is null ||
        pRtlNtStatusToDosError is null)
        return -1;

    afdInitStatics();
    return 0;
}

private int wsGlobalInit() nothrow @nogc
{
    WSADATA wsaData;
    int r = WSAStartup(0x0202, &wsaData); /* MAKEWORD(2, 2) */
    if (r != 0)
        return returnSetError!int(-1, cast(DWORD) r);
    return 0;
}

private SOCKET wsIoctlGetBspSocket(SOCKET socket, uint ioctl) nothrow @nogc
{
    SOCKET bspSocket;
    uint bytes;

    if (WSAIoctl(socket, ioctl, null, 0, &bspSocket, SOCKET.sizeof,
                 &bytes, null, null) != SOCKET_ERROR)
        return bspSocket;
    return INVALID_SOCKET;
}

private SOCKET wsGetBaseSocket(SOCKET socket) nothrow @nogc
{
    SOCKET baseSocket;
    DWORD error;

    for (;;)
    {
        baseSocket = wsIoctlGetBspSocket(socket, SIO_BASE_HANDLE);
        if (baseSocket != INVALID_SOCKET)
            return baseSocket;

        error = GetLastError();
        if (error == WSAENOTSOCK)
            return returnSetError!SOCKET(INVALID_SOCKET, error);

        /* Work around layered service providers (Komodia) that intercept
         * SIO_BASE_HANDLE but not SIO_BSP_HANDLE_POLL. */
        baseSocket = wsIoctlGetBspSocket(socket, SIO_BSP_HANDLE_POLL);
        if (baseSocket != INVALID_SOCKET && baseSocket != socket)
            socket = baseSocket;
        else
            return returnSetError!SOCKET(INVALID_SOCKET, error);
    }
}

/* ------------------------------------------------------------------------- */
/* Intrusive doubly-linked queue                                             */
/* ------------------------------------------------------------------------- */

private struct QueueNode
{
    QueueNode* prev;
    QueueNode* next;
}

private struct Queue
{
    QueueNode head;
}

private void queueInit(Queue* queue) nothrow @nogc
{
    queueNodeInit(&queue.head);
}

private void queueNodeInit(QueueNode* node) nothrow @nogc
{
    node.prev = node;
    node.next = node;
}

private void queueDetachNode(QueueNode* node) nothrow @nogc
{
    node.prev.next = node.next;
    node.next.prev = node.prev;
}

private QueueNode* queueFirst(Queue* queue) nothrow @nogc
{
    return !queueIsEmpty(queue) ? queue.head.next : null;
}

private QueueNode* queueLast(Queue* queue) nothrow @nogc
{
    return !queueIsEmpty(queue) ? queue.head.prev : null;
}

private void queuePrepend(Queue* queue, QueueNode* node) nothrow @nogc
{
    node.next = queue.head.next;
    node.prev = &queue.head;
    node.next.prev = node;
    queue.head.next = node;
}

private void queueAppend(Queue* queue, QueueNode* node) nothrow @nogc
{
    node.next = &queue.head;
    node.prev = queue.head.prev;
    node.prev.next = node;
    queue.head.prev = node;
}

private void queueMoveToStart(Queue* queue, QueueNode* node) nothrow @nogc
{
    queueDetachNode(node);
    queuePrepend(queue, node);
}

private void queueMoveToEnd(Queue* queue, QueueNode* node) nothrow @nogc
{
    queueDetachNode(node);
    queueAppend(queue, node);
}

private void queueRemove(QueueNode* node) nothrow @nogc
{
    queueDetachNode(node);
    queueNodeInit(node);
}

private bool queueIsEmpty(Queue* queue) nothrow @nogc
{
    return !queueIsEnqueued(&queue.head);
}

private bool queueIsEnqueued(QueueNode* node) nothrow @nogc
{
    return node.prev !is node;
}

/* ------------------------------------------------------------------------- */
/* Red/black tree (non-thread-safe)                                          */
/* ------------------------------------------------------------------------- */

private struct TreeNode
{
    TreeNode* left;
    TreeNode* right;
    TreeNode* parent;
    size_t    key;
    bool      red;
}

private struct Tree
{
    TreeNode* root;
}

private void treeInit(Tree* tree) nothrow @nogc
{
    memset(tree, 0, Tree.sizeof);
}

private void treeNodeInit(TreeNode* node) nothrow @nogc
{
    memset(node, 0, TreeNode.sizeof);
}

private void treeRotateLeft(Tree* tree, TreeNode* node) nothrow @nogc
{
    TreeNode* p = node;
    TreeNode* q = node.right;
    TreeNode* parent = p.parent;

    if (parent !is null)
    {
        if (parent.left is p)
            parent.left = q;
        else
            parent.right = q;
    }
    else
        tree.root = q;

    q.parent = parent;
    p.parent = q;
    p.right = q.left;
    if (p.right !is null)
        p.right.parent = p;
    q.left = p;
}

private void treeRotateRight(Tree* tree, TreeNode* node) nothrow @nogc
{
    TreeNode* p = node;
    TreeNode* q = node.left;
    TreeNode* parent = p.parent;

    if (parent !is null)
    {
        if (parent.left is p)
            parent.left = q;
        else
            parent.right = q;
    }
    else
        tree.root = q;

    q.parent = parent;
    p.parent = q;
    p.left = q.right;
    if (p.left !is null)
        p.left.parent = p;
    q.right = p;
}

private int treeAdd(Tree* tree, TreeNode* node, size_t key) nothrow @nogc
{
    TreeNode* parent = tree.root;

    if (parent !is null)
    {
        for (;;)
        {
            if (key < parent.key)
            {
                if (parent.left !is null)
                    parent = parent.left;
                else
                {
                    parent.left = node;
                    break;
                }
            }
            else if (key > parent.key)
            {
                if (parent.right !is null)
                    parent = parent.right;
                else
                {
                    parent.right = node;
                    break;
                }
            }
            else
                return -1;
        }
    }
    else
        tree.root = node;

    node.key = key;
    node.left = null;
    node.right = null;
    node.parent = parent;
    node.red = true;

    for (; parent !is null && parent.red; parent = node.parent)
    {
        TreeNode* grandparent = parent.parent;
        if (parent is grandparent.left)
        {
            TreeNode* uncle = grandparent.right;
            if (uncle !is null && uncle.red)
            {
                parent.red = false;
                uncle.red = false;
                grandparent.red = true;
                node = grandparent;
            }
            else
            {
                if (node is parent.right)
                {
                    treeRotateLeft(tree, parent);
                    node = parent;
                    parent = node.parent;
                }
                parent.red = false;
                grandparent.red = true;
                treeRotateRight(tree, grandparent);
            }
        }
        else
        {
            TreeNode* uncle = grandparent.left;
            if (uncle !is null && uncle.red)
            {
                parent.red = false;
                uncle.red = false;
                grandparent.red = true;
                node = grandparent;
            }
            else
            {
                if (node is parent.left)
                {
                    treeRotateRight(tree, parent);
                    node = parent;
                    parent = node.parent;
                }
                parent.red = false;
                grandparent.red = true;
                treeRotateLeft(tree, grandparent);
            }
        }
    }
    tree.root.red = false;
    return 0;
}

/* Returns true when the caller must break out of the fix-up loop. */
private bool treeRebalanceAfterRemoveLeft(Tree* tree, TreeNode* parent,
                                          ref TreeNode* node) nothrow @nogc
{
    TreeNode* sibling = parent.right;

    if (sibling.red)
    {
        sibling.red = false;
        parent.red = true;
        treeRotateLeft(tree, parent);
        sibling = parent.right;
    }

    if ((sibling.left !is null && sibling.left.red) ||
        (sibling.right !is null && sibling.right.red))
    {
        if (sibling.right is null || !sibling.right.red)
        {
            sibling.left.red = false;
            sibling.red = true;
            treeRotateRight(tree, sibling);
            sibling = parent.right;
        }
        sibling.red = parent.red;
        parent.red = false;
        sibling.right.red = false;
        treeRotateLeft(tree, parent);
        node = tree.root;
        return true;
    }
    sibling.red = true;
    return false;
}

private bool treeRebalanceAfterRemoveRight(Tree* tree, TreeNode* parent,
                                           ref TreeNode* node) nothrow @nogc
{
    TreeNode* sibling = parent.left;

    if (sibling.red)
    {
        sibling.red = false;
        parent.red = true;
        treeRotateRight(tree, parent);
        sibling = parent.left;
    }

    if ((sibling.right !is null && sibling.right.red) ||
        (sibling.left !is null && sibling.left.red))
    {
        if (sibling.left is null || !sibling.left.red)
        {
            sibling.right.red = false;
            sibling.red = true;
            treeRotateLeft(tree, sibling);
            sibling = parent.left;
        }
        sibling.red = parent.red;
        parent.red = false;
        sibling.left.red = false;
        treeRotateRight(tree, parent);
        node = tree.root;
        return true;
    }
    sibling.red = true;
    return false;
}

private void treeDel(Tree* tree, TreeNode* node) nothrow @nogc
{
    TreeNode* parent = node.parent;
    TreeNode* left = node.left;
    TreeNode* right = node.right;
    TreeNode* next;
    bool red;

    if (left is null)
        next = right;
    else if (right is null)
        next = left;
    else
    {
        next = right;
        while (next.left !is null)
            next = next.left;
    }

    if (parent !is null)
    {
        if (parent.left is node)
            parent.left = next;
        else
            parent.right = next;
    }
    else
        tree.root = next;

    if (left !is null && right !is null)
    {
        red = next.red;
        next.red = node.red;
        next.left = left;
        left.parent = next;
        if (next !is right)
        {
            parent = next.parent;
            next.parent = node.parent;
            node = next.right;
            parent.left = node;
            next.right = right;
            right.parent = next;
        }
        else
        {
            next.parent = parent;
            parent = next;
            node = next.right;
        }
    }
    else
    {
        red = node.red;
        node = next;
    }

    if (node !is null)
        node.parent = parent;
    if (red)
        return;
    if (node !is null && node.red)
    {
        node.red = false;
        return;
    }

    for (;;)
    {
        if (node is tree.root)
            break;

        bool done;
        if (node is parent.left)
            done = treeRebalanceAfterRemoveLeft(tree, parent, node);
        else
            done = treeRebalanceAfterRemoveRight(tree, parent, node);
        if (done)
            break;

        node = parent;
        parent = parent.parent;
        if (node !is null && node.red)
            break;
    }
    if (node !is null)
        node.red = false;
}

private TreeNode* treeFind(Tree* tree, size_t key) nothrow @nogc
{
    TreeNode* node = tree.root;
    while (node !is null)
    {
        if (key < node.key)
            node = node.left;
        else if (key > node.key)
            node = node.right;
        else
            return node;
    }
    return null;
}

private TreeNode* treeRoot(Tree* tree) nothrow @nogc
{
    return tree.root;
}

/* ------------------------------------------------------------------------- */
/* Thread-safe red/black tree keyed by epoll handle / socket                  */
/* ------------------------------------------------------------------------- */

private struct Reflock
{
    shared long state; /* 32-bit Interlocked APIs operate on long values. */
}

private enum long REFLOCK_REF          = 0x00000001;
private enum long REFLOCK_REF_MASK     = 0x0fffffff;
private enum long REFLOCK_DESTROY      = 0x10000000;
private enum long REFLOCK_DESTROY_MASK = 0xf0000000;
private enum long REFLOCK_POISON       = 0x300dead0;

private int reflockGlobalInit() nothrow @nogc
{
    NTSTATUS status = pNtCreateKeyedEvent(&reflockKeyedEvent,
                                          KEYEDEVENT_ALL_ACCESS, null, 0);
    if (status != STATUS_SUCCESS)
        return returnSetError!int(-1, pRtlNtStatusToDosError(status));
    return 0;
}

private void reflockInit(Reflock* reflock) nothrow @nogc
{
    reflock.state = 0;
}

private void reflockSignalEvent(void* address) nothrow @nogc
{
    NTSTATUS status = pNtReleaseKeyedEvent(reflockKeyedEvent, address, false,
                                           null);
    if (status != STATUS_SUCCESS)
        abort();
}

private void reflockAwaitEvent(void* address) nothrow @nogc
{
    NTSTATUS status = pNtWaitForKeyedEvent(reflockKeyedEvent, address, false,
                                           null);
    if (status != STATUS_SUCCESS)
        abort();
}

private void reflockRef(Reflock* reflock) nothrow @nogc
{
    long state = atomicOp!"+="(reflock.state, REFLOCK_REF);
    assert((state & REFLOCK_DESTROY_MASK) == 0);
}

private void reflockUnref(Reflock* reflock) nothrow @nogc
{
    long state = atomicOp!"+="(reflock.state, -REFLOCK_REF);
    assert((state & REFLOCK_DESTROY_MASK & ~REFLOCK_DESTROY) == 0);
    if (state == REFLOCK_DESTROY)
        reflockSignalEvent(reflock);
}

private void reflockUnrefAndDestroy(Reflock* reflock) nothrow @nogc
{
    long state = atomicOp!"+="(reflock.state, REFLOCK_DESTROY - REFLOCK_REF);
    long refCount = state & REFLOCK_REF_MASK;

    assert((state & REFLOCK_DESTROY_MASK) == REFLOCK_DESTROY);
    if (refCount != 0)
        reflockAwaitEvent(reflock);

    state = atomicExchange(&reflock.state, REFLOCK_POISON);
    assert(state == REFLOCK_DESTROY);
}

private struct TsTree
{
    Tree    tree;
    SRWLOCK lock;
}

private struct TsTreeNode
{
    TreeNode treeNode;
    Reflock  reflock;
}

private void tsTreeInit(TsTree* tsTree) nothrow @nogc
{
    treeInit(&tsTree.tree);
    InitializeSRWLock(&tsTree.lock);
}

private void tsTreeNodeInit(TsTreeNode* node) nothrow @nogc
{
    treeNodeInit(&node.treeNode);
    reflockInit(&node.reflock);
}

private int tsTreeAdd(TsTree* tsTree, TsTreeNode* node, size_t key) nothrow @nogc
{
    AcquireSRWLockExclusive(&tsTree.lock);
    int r = treeAdd(&tsTree.tree, &node.treeNode, key);
    ReleaseSRWLockExclusive(&tsTree.lock);
    return r;
}

private TsTreeNode* tsTreeFindNode(TsTree* tsTree, size_t key) nothrow @nogc
{
    TreeNode* treeNode = treeFind(&tsTree.tree, key);
    if (treeNode is null)
        return null;
    return cast(TsTreeNode*)(cast(ubyte*) treeNode - TsTreeNode.treeNode.offsetof);
}

private TsTreeNode* tsTreeDelAndRef(TsTree* tsTree, size_t key) nothrow @nogc
{
    AcquireSRWLockExclusive(&tsTree.lock);
    TsTreeNode* node = tsTreeFindNode(tsTree, key);
    if (node !is null)
    {
        treeDel(&tsTree.tree, &node.treeNode);
        reflockRef(&node.reflock);
    }
    ReleaseSRWLockExclusive(&tsTree.lock);
    return node;
}

private TsTreeNode* tsTreeFindAndRef(TsTree* tsTree, size_t key) nothrow @nogc
{
    AcquireSRWLockShared(&tsTree.lock);
    TsTreeNode* node = tsTreeFindNode(tsTree, key);
    if (node !is null)
        reflockRef(&node.reflock);
    ReleaseSRWLockShared(&tsTree.lock);
    return node;
}

private void tsTreeNodeUnref(TsTreeNode* node) nothrow @nogc
{
    reflockUnref(&node.reflock);
}

private void tsTreeNodeUnrefAndDestroy(TsTreeNode* node) nothrow @nogc
{
    reflockUnrefAndDestroy(&node.reflock);
}

/* ------------------------------------------------------------------------- */
/* Port / poll group / socket state                                          */
/* ------------------------------------------------------------------------- */

private enum size_t POLL_GROUP_MAX_GROUP_SIZE = 32;

private struct PollGroup
{
    PortState*  portState;
    QueueNode   queueNode;
    HANDLE      afdDeviceHandle;
    size_t      groupSize;
}

private enum uint SOCK_KNOWN_EPOLL_EVENTS =
    EPOLLIN | EPOLLPRI | EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLRDNORM |
    EPOLLRDBAND | EPOLLWRNORM | EPOLLWRBAND | EPOLLMSG | EPOLLRDHUP;

private enum PollStatus
{
    idle,
    pending,
    cancelled,
}

private struct SockState
{
    IO_STATUS_BLOCK   ioStatusBlock;
    AFD_POLL_INFO     pollInfo;
    QueueNode         queueNode;
    TreeNode          treeNode;
    PollGroup*        pollGroup;
    SOCKET            baseSocket;
    epoll_data_t      userData;
    uint              userEvents;
    uint              pendingEvents;
    PollStatus        pollStatus;
    bool              deletePending;
}

private struct PortState
{
    HANDLE        iocpHandle;
    Tree          sockTree;
    Queue         sockUpdateQueue;
    Queue         sockDeletedQueue;
    Queue         pollGroupQueue;
    TsTreeNode    handleTreeNode;
    CRITICAL_SECTION lock;
    size_t        activePollCount;
}

private __gshared TsTree epollHandleTree;

private int epollGlobalInit() nothrow @nogc
{
    tsTreeInit(&epollHandleTree);
    return 0;
}

/* ------------------------------------------------------------------------- */
/* Container-of helpers                                                      */
/* ------------------------------------------------------------------------- */

private T* containerOf(T, string member)(void* memberPtr) nothrow @nogc
{
    return cast(T*)(cast(ubyte*) memberPtr - __traits(getMember, T, member).offsetof);
}

/* ------------------------------------------------------------------------- */
/* Poll groups                                                               */
/* ------------------------------------------------------------------------- */

private PollGroup* pollGroupNew(PortState* portState) nothrow @nogc
{
    HANDLE iocpHandle = portGetIocpHandle(portState);
    Queue* pollGroupQueue = portGetPollGroupQueue(portState);

    PollGroup* pollGroup = cast(PollGroup*) malloc(PollGroup.sizeof);
    if (pollGroup is null)
        return returnSetError!(PollGroup*)(null, ERROR_NOT_ENOUGH_MEMORY);
    memset(pollGroup, 0, PollGroup.sizeof);
    queueNodeInit(&pollGroup.queueNode);
    pollGroup.portState = portState;

    if (afdCreateDeviceHandle(iocpHandle, &pollGroup.afdDeviceHandle) < 0)
    {
        free(pollGroup);
        return null;
    }

    queueAppend(pollGroupQueue, &pollGroup.queueNode);
    return pollGroup;
}

private void pollGroupDelete(PollGroup* pollGroup) nothrow @nogc
{
    assert(pollGroup.groupSize == 0);
    CloseHandle(pollGroup.afdDeviceHandle);
    queueRemove(&pollGroup.queueNode);
    free(pollGroup);
}

private PollGroup* pollGroupFromQueueNode(QueueNode* queueNode) nothrow @nogc
{
    return containerOf!(PollGroup, "queueNode")(queueNode);
}

private HANDLE pollGroupGetAfdDeviceHandle(PollGroup* pollGroup) nothrow @nogc
{
    return pollGroup.afdDeviceHandle;
}

private PollGroup* pollGroupAcquire(PortState* portState) nothrow @nogc
{
    Queue* pollGroupQueue = portGetPollGroupQueue(portState);
    QueueNode* last = queueLast(pollGroupQueue);
    PollGroup* pollGroup = last !is null ? pollGroupFromQueueNode(last) : null;

    if (pollGroup is null || pollGroup.groupSize >= POLL_GROUP_MAX_GROUP_SIZE)
        pollGroup = pollGroupNew(portState);
    if (pollGroup is null)
        return null;

    if (++pollGroup.groupSize == POLL_GROUP_MAX_GROUP_SIZE)
        queueMoveToStart(pollGroupQueue, &pollGroup.queueNode);
    return pollGroup;
}

private void pollGroupRelease(PollGroup* pollGroup) nothrow @nogc
{
    PortState* portState = pollGroup.portState;
    Queue* pollGroupQueue = portGetPollGroupQueue(portState);

    pollGroup.groupSize--;
    assert(pollGroup.groupSize < POLL_GROUP_MAX_GROUP_SIZE);
    queueMoveToEnd(pollGroupQueue, &pollGroup.queueNode);
    /* Poll groups are currently only freed when the epoll port is closed. */
}

/* ------------------------------------------------------------------------- */
/* Port                                                                      */
/* ------------------------------------------------------------------------- */

private PortState* portAlloc() nothrow @nogc
{
    PortState* portState = cast(PortState*) malloc(PortState.sizeof);
    if (portState is null)
        return returnSetError!(PortState*)(null, ERROR_NOT_ENOUGH_MEMORY);
    return portState;
}

private void portFree(PortState* port) nothrow @nogc
{
    assert(port !is null);
    free(port);
}

private HANDLE portCreateIocp() nothrow @nogc
{
    HANDLE iocpHandle = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
    if (iocpHandle is null)
        return returnMapError!HANDLE(null);
    return iocpHandle;
}

private PortState* portNew(HANDLE* iocpHandleOut) nothrow @nogc
{
    PortState* portState = portAlloc();
    if (portState is null)
        return null;

    HANDLE iocpHandle = portCreateIocp();
    if (iocpHandle is null)
    {
        portFree(portState);
        return null;
    }

    memset(portState, 0, PortState.sizeof);
    portState.iocpHandle = iocpHandle;
    treeInit(&portState.sockTree);
    queueInit(&portState.sockUpdateQueue);
    queueInit(&portState.sockDeletedQueue);
    queueInit(&portState.pollGroupQueue);
    tsTreeNodeInit(&portState.handleTreeNode);
    InitializeCriticalSection(&portState.lock);

    *iocpHandleOut = iocpHandle;
    return portState;
}

private int portCloseIocp(PortState* portState) nothrow @nogc
{
    HANDLE iocpHandle = portState.iocpHandle;
    portState.iocpHandle = null;
    if (!CloseHandle(iocpHandle))
        return returnMapError!int(-1);
    return 0;
}

private int portClose(PortState* portState) nothrow @nogc
{
    EnterCriticalSection(&portState.lock);
    int result = portCloseIocp(portState);
    LeaveCriticalSection(&portState.lock);
    return result;
}

private int portDelete(PortState* portState) nothrow @nogc
{
    /* At this point the IOCP port should have been closed. */
    assert(portState.iocpHandle is null);

    while (TreeNode* treeNode = treeRoot(&portState.sockTree))
    {
        SockState* sockState = sockStateFromTreeNode(treeNode);
        sockForceDelete(portState, sockState);
    }

    while (QueueNode* queueNode = queueFirst(&portState.sockDeletedQueue))
    {
        SockState* sockState = sockStateFromQueueNode(queueNode);
        sockForceDelete(portState, sockState);
    }

    while (QueueNode* queueNode = queueFirst(&portState.pollGroupQueue))
    {
        PollGroup* pollGroup = pollGroupFromQueueNode(queueNode);
        pollGroupDelete(pollGroup);
    }

    assert(queueIsEmpty(&portState.sockUpdateQueue));
    DeleteCriticalSection(&portState.lock);
    portFree(portState);
    return 0;
}

private int portUpdateEvents(PortState* portState) nothrow @nogc
{
    Queue* sockUpdateQueue = &portState.sockUpdateQueue;

    while (!queueIsEmpty(sockUpdateQueue))
    {
        QueueNode* queueNode = queueFirst(sockUpdateQueue);
        SockState* sockState = sockStateFromQueueNode(queueNode);

        if (sockUpdate(portState, sockState) < 0)
            return -1;
        /* sockUpdate() removes the socket from the update queue. */
    }
    return 0;
}

private void portUpdateEventsIfPolling(PortState* portState) nothrow @nogc
{
    if (portState.activePollCount > 0)
        portUpdateEvents(portState);
}

private int portFeedEvents(PortState* portState, epoll_event* epollEvents,
                           OVERLAPPED_ENTRY* iocpEvents,
                           DWORD iocpEventCount) nothrow @nogc
{
    int epollEventCount = 0;

    foreach (i; 0 .. iocpEventCount)
    {
        IO_STATUS_BLOCK* iosb = cast(IO_STATUS_BLOCK*) iocpEvents[i].lpOverlapped;
        epoll_event* ev = &epollEvents[epollEventCount];
        epollEventCount += sockFeedEvent(portState, iosb, ev);
    }
    return epollEventCount;
}

private int portPoll(PortState* portState, epoll_event* epollEvents,
                     OVERLAPPED_ENTRY* iocpEvents, DWORD maxevents,
                     DWORD timeout) nothrow @nogc
{
    DWORD completionCount;

    if (portUpdateEvents(portState) < 0)
        return -1;

    portState.activePollCount++;
    LeaveCriticalSection(&portState.lock);

    BOOL r = GetQueuedCompletionStatusEx(portState.iocpHandle, iocpEvents,
                                         maxevents, &completionCount,
                                         timeout, false);

    EnterCriticalSection(&portState.lock);
    portState.activePollCount--;

    if (!r)
        return returnMapError!int(-1);
    return portFeedEvents(portState, epollEvents, iocpEvents, completionCount);
}

private int portWait(PortState* portState, epoll_event* events,
                     int maxevents, int timeout) nothrow @nogc
{
    enum size_t MAX_ON_STACK_COMPLETIONS = 256;
    OVERLAPPED_ENTRY[MAX_ON_STACK_COMPLETIONS] stackIocpEvents;
    OVERLAPPED_ENTRY* iocpEvents;
    ulong due = 0;
    DWORD gqcsTimeout;
    int result;

    if (maxevents <= 0)
        return returnSetError!int(-1, ERROR_INVALID_PARAMETER);

    if (cast(size_t) maxevents <= MAX_ON_STACK_COMPLETIONS)
        iocpEvents = stackIocpEvents.ptr;
    else
    {
        iocpEvents = cast(OVERLAPPED_ENTRY*)
            malloc(cast(size_t) maxevents * OVERLAPPED_ENTRY.sizeof);
        if (iocpEvents is null)
            return returnSetError!int(-1, ERROR_NOT_ENOUGH_MEMORY);
    }

    if (timeout > 0)
    {
        due = GetTickCount64() + cast(ulong) timeout;
        gqcsTimeout = cast(DWORD) timeout;
    }
    else if (timeout == 0)
        gqcsTimeout = 0;
    else
        gqcsTimeout = INFINITE;

    EnterCriticalSection(&portState.lock);

    for (;;)
    {
        result = portPoll(portState, events, iocpEvents, cast(DWORD) maxevents,
                          gqcsTimeout);
        if (result < 0 || result > 0)
            break;

        if (timeout < 0)
            continue;

        ulong now = GetTickCount64();
        if (now >= due)
        {
            SetLastError(WAIT_TIMEOUT);
            break;
        }
        gqcsTimeout = cast(DWORD)(due - now);
    }

    portUpdateEventsIfPolling(portState);
    LeaveCriticalSection(&portState.lock);

    if (iocpEvents !is stackIocpEvents.ptr)
        free(iocpEvents);

    if (result >= 0)
        return result;
    else if (GetLastError() == WAIT_TIMEOUT)
        return 0;
    return -1;
}

private int portCtlAdd(PortState* portState, SOCKET sock,
                       epoll_event* ev) nothrow @nogc
{
    SockState* sockState = sockNew(portState, sock);
    if (sockState is null)
        return -1;

    if (sockSetEvent(portState, sockState, ev) < 0)
    {
        sockDelete(portState, sockState);
        return -1;
    }
    portUpdateEventsIfPolling(portState);
    return 0;
}

private int portCtlMod(PortState* portState, SOCKET sock,
                       epoll_event* ev) nothrow @nogc
{
    SockState* sockState = portFindSocket(portState, sock);
    if (sockState is null)
        return -1;
    if (sockSetEvent(portState, sockState, ev) < 0)
        return -1;
    portUpdateEventsIfPolling(portState);
    return 0;
}

private int portCtlDel(PortState* portState, SOCKET sock) nothrow @nogc
{
    SockState* sockState = portFindSocket(portState, sock);
    if (sockState is null)
        return -1;
    sockDelete(portState, sockState);
    return 0;
}

private int portCtlOp(PortState* portState, int op, SOCKET sock,
                      epoll_event* ev) nothrow @nogc
{
    switch (op)
    {
        case EPOLL_CTL_ADD: return portCtlAdd(portState, sock, ev);
        case EPOLL_CTL_MOD: return portCtlMod(portState, sock, ev);
        case EPOLL_CTL_DEL: return portCtlDel(portState, sock);
        default: return returnSetError!int(-1, ERROR_INVALID_PARAMETER);
    }
}

private int portCtl(PortState* portState, int op, SOCKET sock,
                    epoll_event* ev) nothrow @nogc
{
    EnterCriticalSection(&portState.lock);
    int result = portCtlOp(portState, op, sock, ev);
    LeaveCriticalSection(&portState.lock);
    return result;
}

private int portRegisterSocket(PortState* portState, SockState* sockState,
                               SOCKET socket) nothrow @nogc
{
    if (treeAdd(&portState.sockTree, &sockState.treeNode, cast(size_t) socket) < 0)
        return returnSetError!int(-1, ERROR_ALREADY_EXISTS);
    return 0;
}

private void portUnregisterSocket(PortState* portState,
                                  SockState* sockState) nothrow @nogc
{
    treeDel(&portState.sockTree, &sockState.treeNode);
}

private SockState* portFindSocket(PortState* portState, SOCKET socket) nothrow @nogc
{
    TreeNode* treeNode = treeFind(&portState.sockTree, cast(size_t) socket);
    if (treeNode is null)
        return returnSetError!(SockState*)(null, ERROR_NOT_FOUND);
    return sockStateFromTreeNode(treeNode);
}

private void portRequestSocketUpdate(PortState* portState,
                                     SockState* sockState) nothrow @nogc
{
    if (queueIsEnqueued(&sockState.queueNode))
        return;
    queueAppend(&portState.sockUpdateQueue, &sockState.queueNode);
}

private void portCancelSocketUpdate(PortState* portState,
                                    SockState* sockState) nothrow @nogc
{
    if (!queueIsEnqueued(&sockState.queueNode))
        return;
    queueRemove(&sockState.queueNode);
}

private void portAddDeletedSocket(PortState* portState,
                                  SockState* sockState) nothrow @nogc
{
    if (queueIsEnqueued(&sockState.queueNode))
        return;
    queueAppend(&portState.sockDeletedQueue, &sockState.queueNode);
}

private void portRemoveDeletedSocket(PortState* portState,
                                     SockState* sockState) nothrow @nogc
{
    if (!queueIsEnqueued(&sockState.queueNode))
        return;
    queueRemove(&sockState.queueNode);
}

private HANDLE portGetIocpHandle(PortState* portState) nothrow @nogc
{
    assert(portState.iocpHandle !is null);
    return portState.iocpHandle;
}

private Queue* portGetPollGroupQueue(PortState* portState) nothrow @nogc
{
    return &portState.pollGroupQueue;
}

private PortState* portStateFromHandleTreeNode(TsTreeNode* treeNode) nothrow @nogc
{
    return containerOf!(PortState, "handleTreeNode")(treeNode);
}

private TsTreeNode* portStateToHandleTreeNode(PortState* portState) nothrow @nogc
{
    return &portState.handleTreeNode;
}

/* ------------------------------------------------------------------------- */
/* Sockets                                                                   */
/* ------------------------------------------------------------------------- */

private SockState* sockAlloc() nothrow @nogc
{
    SockState* sockState = cast(SockState*) malloc(SockState.sizeof);
    if (sockState is null)
        return returnSetError!(SockState*)(null, ERROR_NOT_ENOUGH_MEMORY);
    return sockState;
}

private void sockFree(SockState* sockState) nothrow @nogc
{
    assert(sockState !is null);
    free(sockState);
}

private int sockCancelPoll(SockState* sockState) nothrow @nogc
{
    assert(sockState.pollStatus == PollStatus.pending);
    if (afdCancelPoll(pollGroupGetAfdDeviceHandle(sockState.pollGroup),
                      &sockState.ioStatusBlock) < 0)
        return -1;
    sockState.pollStatus = PollStatus.cancelled;
    sockState.pendingEvents = 0;
    return 0;
}

private SockState* sockNew(PortState* portState, SOCKET socket) nothrow @nogc
{
    if (socket == 0 || socket == INVALID_SOCKET)
        return returnSetError!(SockState*)(null, ERROR_INVALID_HANDLE);

    SOCKET baseSocket = wsGetBaseSocket(socket);
    if (baseSocket == INVALID_SOCKET)
        return null;

    PollGroup* pollGroup = pollGroupAcquire(portState);
    if (pollGroup is null)
        return null;

    SockState* sockState = sockAlloc();
    if (sockState is null)
    {
        pollGroupRelease(pollGroup);
        return null;
    }
    memset(sockState, 0, SockState.sizeof);

    sockState.baseSocket = baseSocket;
    sockState.pollGroup = pollGroup;
    treeNodeInit(&sockState.treeNode);
    queueNodeInit(&sockState.queueNode);

    if (portRegisterSocket(portState, sockState, socket) < 0)
    {
        sockFree(sockState);
        pollGroupRelease(pollGroup);
        return null;
    }
    return sockState;
}

private int sockDeleteImpl(PortState* portState, SockState* sockState,
                           bool force) nothrow @nogc
{
    if (!sockState.deletePending)
    {
        if (sockState.pollStatus == PollStatus.pending)
            sockCancelPoll(sockState);
        portCancelSocketUpdate(portState, sockState);
        portUnregisterSocket(portState, sockState);
        sockState.deletePending = true;
    }

    /* If a poll request still needs to complete, the SockState can't be freed
     * yet.  sockFeedEvent() or portClose() will take care of that later. */
    if (force || sockState.pollStatus == PollStatus.idle)
    {
        portRemoveDeletedSocket(portState, sockState);
        pollGroupRelease(sockState.pollGroup);
        sockFree(sockState);
    }
    else
        portAddDeletedSocket(portState, sockState);

    return 0;
}

private void sockDelete(PortState* portState, SockState* sockState) nothrow @nogc
{
    sockDeleteImpl(portState, sockState, false);
}

private void sockForceDelete(PortState* portState, SockState* sockState) nothrow @nogc
{
    sockDeleteImpl(portState, sockState, true);
}

private int sockSetEvent(PortState* portState, SockState* sockState,
                         epoll_event* ev) nothrow @nogc
{
    /* EPOLLERR and EPOLLHUP are always reported, except after a one-shot event
     * has been reported for the socket. */
    uint events = ev.events | EPOLLERR | EPOLLHUP;

    sockState.userEvents = events;
    sockState.userData = ev.data;

    if ((events & SOCK_KNOWN_EPOLL_EVENTS & ~sockState.pendingEvents) != 0)
        portRequestSocketUpdate(portState, sockState);
    return 0;
}

private uint sockEpollEventsToAfdEvents(uint epollEvents) nothrow @nogc
{
    uint afdEvents = AFD_POLL_LOCAL_CLOSE;

    if (epollEvents & (EPOLLIN | EPOLLRDNORM))
        afdEvents |= AFD_POLL_RECEIVE | AFD_POLL_ACCEPT;
    if (epollEvents & (EPOLLPRI | EPOLLRDBAND))
        afdEvents |= AFD_POLL_RECEIVE_EXPEDITED;
    if (epollEvents & (EPOLLOUT | EPOLLWRNORM | EPOLLWRBAND))
        afdEvents |= AFD_POLL_SEND;
    if (epollEvents & (EPOLLIN | EPOLLRDNORM | EPOLLRDHUP))
        afdEvents |= AFD_POLL_DISCONNECT;
    if (epollEvents & EPOLLHUP)
        afdEvents |= AFD_POLL_ABORT;
    if (epollEvents & EPOLLERR)
        afdEvents |= AFD_POLL_CONNECT_FAIL;

    return afdEvents;
}

private uint sockAfdEventsToEpollEvents(uint afdEvents) nothrow @nogc
{
    uint epollEvents;

    if (afdEvents & (AFD_POLL_RECEIVE | AFD_POLL_ACCEPT))
        epollEvents |= EPOLLIN | EPOLLRDNORM;
    if (afdEvents & AFD_POLL_RECEIVE_EXPEDITED)
        epollEvents |= EPOLLPRI | EPOLLRDBAND;
    if (afdEvents & AFD_POLL_SEND)
        epollEvents |= EPOLLOUT | EPOLLWRNORM | EPOLLWRBAND;
    if (afdEvents & AFD_POLL_DISCONNECT)
        epollEvents |= EPOLLIN | EPOLLRDNORM | EPOLLRDHUP;
    if (afdEvents & AFD_POLL_ABORT)
        epollEvents |= EPOLLHUP;
    if (afdEvents & AFD_POLL_CONNECT_FAIL)
        /* Linux reports all these events after connect() has failed. */
        epollEvents |= EPOLLIN | EPOLLOUT | EPOLLERR | EPOLLRDNORM |
                       EPOLLWRNORM | EPOLLRDHUP;

    return epollEvents;
}

private int sockUpdate(PortState* portState, SockState* sockState) nothrow @nogc
{
    assert(!sockState.deletePending);

    if (sockState.pollStatus == PollStatus.pending &&
        (sockState.userEvents & SOCK_KNOWN_EPOLL_EVENTS &
         ~sockState.pendingEvents) == 0)
    {
        /* All requested events are already being monitored. */
    }
    else if (sockState.pollStatus == PollStatus.pending)
    {
        /* Cancel the pending poll; a new one is submitted on completion. */
        if (sockCancelPoll(sockState) < 0)
            return -1;
    }
    else if (sockState.pollStatus == PollStatus.cancelled)
    {
        /* Still waiting for the cancelled poll to complete. */
    }
    else if (sockState.pollStatus == PollStatus.idle)
    {
        sockState.pollInfo.exclusive = false;
        sockState.pollInfo.numberOfHandles = 1;
        sockState.pollInfo.timeout.QuadPart = long.max;
        sockState.pollInfo.handles[0].handle = cast(HANDLE) sockState.baseSocket;
        sockState.pollInfo.handles[0].status = 0;
        sockState.pollInfo.handles[0].events =
            sockEpollEventsToAfdEvents(sockState.userEvents);

        if (afdPoll(pollGroupGetAfdDeviceHandle(sockState.pollGroup),
                    &sockState.pollInfo, &sockState.ioStatusBlock) < 0)
        {
            switch (GetLastError())
            {
                case ERROR_IO_PENDING:
                    break; /* expected */
                case ERROR_INVALID_HANDLE:
                    return sockDeleteImpl(portState, sockState, false);
                default:
                    return returnMapError!int(-1);
            }
        }

        sockState.pollStatus = PollStatus.pending;
        sockState.pendingEvents = sockState.userEvents;
    }
    else
        assert(false);

    portCancelSocketUpdate(portState, sockState);
    return 0;
}

private int sockFeedEvent(PortState* portState, IO_STATUS_BLOCK* iosb,
                          epoll_event* ev) nothrow @nogc
{
    SockState* sockState = containerOf!(SockState, "ioStatusBlock")(iosb);
    AFD_POLL_INFO* pollInfo = &sockState.pollInfo;
    uint epollEvents;

    sockState.pollStatus = PollStatus.idle;
    sockState.pendingEvents = 0;

    if (sockState.deletePending)
    {
        /* Socket was deleted earlier and can now be freed. */
        return sockDeleteImpl(portState, sockState, false);
    }
    else if (iosb.status == STATUS_CANCELLED)
    {
        /* Poll request was cancelled. */
    }
    else if (!NT_SUCCESS(iosb.status))
    {
        epollEvents = EPOLLERR;
    }
    else if (pollInfo.numberOfHandles < 1)
    {
        /* Poll succeeded but reported no socket events. */
    }
    else if (pollInfo.handles[0].events & AFD_POLL_LOCAL_CLOSE)
    {
        /* The socket was closed. */
        return sockDeleteImpl(portState, sockState, false);
    }
    else
        epollEvents = sockAfdEventsToEpollEvents(pollInfo.handles[0].events);

    /* Requeue so a new poll request will be submitted. */
    portRequestSocketUpdate(portState, sockState);

    /* Filter out events the user didn't ask for. */
    epollEvents &= sockState.userEvents;
    if (epollEvents == 0)
        return 0;

    /* One-shot: unmonitor all events, even EPOLLERR and EPOLLHUP, but keep
     * looking for closed sockets. */
    if (sockState.userEvents & EPOLLONESHOT)
        sockState.userEvents = 0;

    ev.data = sockState.userData;
    ev.events = epollEvents;
    return 1;
}

private SockState* sockStateFromQueueNode(QueueNode* queueNode) nothrow @nogc
{
    return containerOf!(SockState, "queueNode")(queueNode);
}

private SockState* sockStateFromTreeNode(TreeNode* treeNode) nothrow @nogc
{
    return containerOf!(SockState, "treeNode")(treeNode);
}

/* ------------------------------------------------------------------------- */
/* epoll port creation                                                       */
/* ------------------------------------------------------------------------- */

private HANDLE epollCreate() nothrow @nogc
{
    if (init() < 0)
        return null;

    HANDLE ephnd;
    PortState* portState = portNew(&ephnd);
    if (portState is null)
        return null;

    TsTreeNode* treeNode = portStateToHandleTreeNode(portState);
    if (tsTreeAdd(&epollHandleTree, treeNode, cast(size_t) ephnd) < 0)
    {
        /* Should never happen. */
        portDelete(portState);
        return returnSetError!HANDLE(null, ERROR_ALREADY_EXISTS);
    }
    return ephnd;
}
