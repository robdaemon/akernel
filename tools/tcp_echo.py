#!/usr/bin/env python3
"""tools/tcp_echo.py (milestone 72c): TCP echo server for the
guest slirp test. `make test` starts this on 127.0.0.1 (default
port 10007) before booting QEMU; Tests/Tcp_Test connects to it
through slirp's 10.0.2.2 host-loopback alias and expects every
byte echoed back. Serves sequential connections until killed."""

import socket
import sys
import threading


def handle(conn):
    with conn:
        while True:
            data = conn.recv(4096)
            if not data:
                return
            conn.sendall(data)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 10007
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(4)
    print(f"tcp_echo listening on 127.0.0.1:{port}", flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,),
                         daemon=True).start()


if __name__ == "__main__":
    main()
