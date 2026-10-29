"""Local HTTP server for the retry tests: the first connection fails as MODE says, later ones get the file.
Usage: python3 -I flaky_server.py MODE [DIR]   (MODE: 503 | cut | reset | none). Prints its port, serves
until killed. Without DIR every path gets 200000 bytes of "x"; with DIR a path is the file under DIR (404
when missing), and each requested path is appended to DIR/../requests.log."""
import os
import socket
import struct
import sys

mode = sys.argv[1]
root = sys.argv[2] if len(sys.argv) > 2 else None
body = b"x" * 200000
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
print(srv.getsockname()[1], flush=True)


def answer(request):
    if root is None:
        return b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body), body
    path = request.split(b" ")[1].decode() if request.count(b" ") >= 2 else "/"
    with open(os.path.join(root, "..", "requests.log"), "a") as log:
        log.write(path + "\n")
    file = os.path.normpath(os.path.join(root, path.lstrip("/")))
    if not file.startswith(os.path.abspath(root)) or not os.path.isfile(file):
        return b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", b""
    with open(file, "rb") as f:
        data = f.read()
    return b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(data), data


first = mode != "none"
while True:
    conn, _ = srv.accept()
    conn.settimeout(5)
    try:
        request = conn.recv(65536)
        head, data = answer(request)
        if first:
            first = False
            if mode == "503":
                conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            elif mode == "cut":
                conn.sendall(head + data[: len(data) // 4])
            else:  # reset before any response
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        else:
            conn.sendall(head + data)
    except OSError:
        pass
    finally:
        conn.close()
