"""Local HTTP server for the retry tests: the first connection fails as MODE says, later ones get the file.
Usage: python3 -I flaky_server.py MODE   (MODE: 503 | cut | reset). Prints its port, serves until killed."""
import socket
import struct
import sys

mode = sys.argv[1]
body = b"x" * 200000
head = b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body)
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
print(srv.getsockname()[1], flush=True)
first = True
while True:
    conn, _ = srv.accept()
    conn.settimeout(5)
    try:
        conn.recv(65536)
        if first:
            first = False
            if mode == "503":
                conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            elif mode == "cut":
                conn.sendall(head + body[:50000])
            else:  # reset before any response
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        else:
            conn.sendall(head + body)
    except OSError:
        pass
    finally:
        conn.close()
