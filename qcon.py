#!/usr/bin/env python3
"""Minimal qconn launcher client: run a shell one-liner on a QNX target.

Protocol (documented by QNX / public research):
  banner "QCONN" -> "service launcher" -> "OK" ->
  "start/flags run /bin/sh /bin/sh -c \"CMD\"" -> "OK <pid>" -> output.

Used here for legitimate dev-board access (our own image starts qconn on
purpose, per qnx_custom_builds startup.sh) to install an ssh key.
"""
import socket, sys, time

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.208.81"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8000
CMD = sys.argv[3]

def recv_some(s, timeout=2.0, quiet_after=0.6):
    s.settimeout(quiet_after)
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        try:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            break
    return buf

def main():
    s = socket.create_connection((HOST, PORT), timeout=5)
    banner = recv_some(s)
    if b"QCONN" not in banner:
        print(f"unexpected banner: {banner!r}", file=sys.stderr)
        sys.exit(2)
    s.sendall(b"service launcher\n")
    r = recv_some(s)
    if b"OK" not in r:
        print(f"launcher service refused: {r!r}", file=sys.stderr)
        sys.exit(3)
    # escape any double quotes in CMD for the sh -c "..." wrapper
    esc = CMD.replace("\\", "\\\\").replace('"', '\\"')
    s.sendall(f'start/flags run /bin/sh /bin/sh -c "{esc}"\n'.encode())
    out = recv_some(s, timeout=6.0)
    sys.stdout.write(out.decode(errors="replace"))
    s.close()

if __name__ == "__main__":
    main()
