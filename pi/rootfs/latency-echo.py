#!/usr/bin/env python3
"""Minimal TCP echo for pipeline round-trip-time probing. Listens on :5002."""
import socket, threading

def handle(c):
    try:
        while True:
            d = c.recv(64)
            if not d:
                break
            c.sendall(d)
    except Exception:
        pass
    finally:
        c.close()

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
s.bind(("0.0.0.0", 5002))
s.listen(4)
while True:
    c, _ = s.accept()
    c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    threading.Thread(target=handle, args=(c,), daemon=True).start()
