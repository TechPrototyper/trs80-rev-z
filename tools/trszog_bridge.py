#!/usr/bin/env python3
"""trszog <-> FPGA debug bridge (ADR-0006 D1, docs/DEBUG-PROTOCOL.md).

Speaks newline-delimited JSON-RPC 2.0 with trszog on a local TCP port
(what a debug-enabled trs80gp would provide) and binary protocol v0
with the machine's debug core over the ULX3S FTDI serial port. This is
the reference implementation of the translation layer; the ESP32 debug
server ports exactly this logic.

Usage:
  python3 tools/trszog_bridge.py --serial /dev/tty.usbserial-XXXX \
      [--port 49152] [--baud 115200]

trszog side (launch.json): "trs80": {"hostname": "localhost",
"port": 49152, "emulator": {"autoStart": false}} — attach, don't launch.

Requires: pyserial.
"""

import argparse
import time
import json
import socket
import sys
import threading

import serial  # pyserial


class TcpSerial:
    """serial.Serial-shaped wrapper over the emulator's --debug-tcp port
    (--serial tcp:<port>): the same byte protocol over localhost TCP —
    immune to the macOS pty/CoreAudio launch race (sim/emu/README.md)."""

    def __init__(self, port):
        import socket
        self._socket = socket
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.sock.settimeout(2)
        self.is_open = True            # serial.Serial interface

    @property
    def in_waiting(self):
        """serial.Serial interface: >0 when a byte can be read without
        blocking. select() peeks without consuming."""
        import select
        r, _, _ = select.select([self.sock], [], [], 0)
        return 1 if r else 0

    def read(self, n=1):
        try:
            return self.sock.recv(n)
        except self._socket.timeout:
            return b""

    def write(self, data):
        self.sock.sendall(data)
        return len(data)

    def reset_input_buffer(self):
        old = self.sock.gettimeout()
        self.sock.settimeout(0.05)
        try:
            while self.sock.recv(4096):
                pass
        except (self._socket.timeout, BlockingIOError, OSError):
            pass
        self.sock.settimeout(old)

    def reset_output_buffer(self):
        pass

    def close(self):
        self.is_open = False
        self.sock.close()


# binary protocol v0 (rtl/m1_debug.v)
C_HALT, C_RUN, C_STEP, C_REGS, C_SETR = 0x01, 0x02, 0x03, 0x04, 0x05
C_RDM, C_WRM, C_SBP, C_STAT, C_SWP = 0x06, 0x07, 0x08, 0x09, 0x0A
R_ERR, R_EVT = 0xEE, 0x80

REG_IDX = {"AF": 0, "BC": 1, "DE": 2, "HL": 3, "IX": 4, "IY": 5,
           "SP": 6, "PC": 7, "I": 8, "R": 9,
           "AF_": 10, "BC_": 11, "DE_": 12, "HL_": 13}

STOP_REASONS = {0: "pause", 1: "breakpoint", 2: "step",
                3: "watchpoint", 4: "reset"}

CALL_OPCODES = {0xCD, 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC}
RST_OPCODES = {0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF}


def parse_num(v):
    """Accept JSON numbers and hex strings, with or without 0x."""
    if isinstance(v, int):
        return v
    return int(str(v).replace("0x", "").replace("0X", ""), 16)


class Link:
    """Serialized access to the binary port; demultiplexes async events."""

    def __init__(self, dev, baud, on_event):
        self.dev = dev
        self.baud = baud
        self.ser = None
        self.lock = threading.Lock()
        self.on_event = on_event
        self._open()

    def _open(self):
        """(Re)open the serial device — the FTDI re-enumerates on every
        board reboot/reflash, leaving the old handle dead (Errno 6). Any
        command that hits a dead handle triggers a reopen so the debugger
        survives a power-cycle without the bridge being restarted."""
        try:
            if self.ser:
                self.ser.close()
        except Exception:  # noqa: BLE001
            pass
        if self.dev.startswith("tcp:"):
            self.ser = TcpSerial(int(self.dev[4:]))
            time.sleep(0.05)
            self.ser.reset_input_buffer()
            return
        try:
            self.ser = serial.Serial(self.dev, self.baud, timeout=2)
        except OSError:
            # Pseudo-ttys (e.g. the SDL emulator's --debug-pty) reject some
            # baud rates at the ioctl level; the rate is meaningless on a
            # pty anyway, so retry with a rate every tty accepts.
            self.ser = serial.Serial(self.dev, 9600, timeout=2)
        time.sleep(0.05)
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()
        # drain any late bytes the core may still be emitting (stale
        # responses from a previous, interrupted session), so the first
        # command starts from a quiet line
        self.ser.timeout = 0.05
        while self.ser.read(256):
            pass
        self.ser.timeout = 2

    def _ensure(self):
        if self.ser is None or not self.ser.is_open:
            self._open()

    def _byte(self):
        d = self.ser.read(1)
        if not d:
            raise IOError("serial read timeout (board asleep or unplugged?)")
        return d[0]

    def _resp(self, first_ok, tail_len):
        """Read one response, letting events pass through."""
        while True:
            b = self._byte()
            if b == R_EVT:
                ev = [self._byte() for _ in range(3)]
                self.on_event(ev[0], ev[1] | (ev[2] << 8))
                continue
            if b == R_ERR:
                raise IOError("debug core refused the command")
            if b != first_ok:
                raise IOError(f"framing: expected {first_ok:02x}, got {b:02x}")
            return bytes(self._byte() for _ in range(tail_len))

    def poll_event(self):
        """Non-blocking: pick up an async event if one is on the wire.
        Safe against command traffic — the lock serializes the port."""
        with self.lock:
            try:
                self._ensure()
                if self.ser.in_waiting < 1:
                    return None
                b = self._byte()
                if b != R_EVT:
                    return None                # desync noise; drop
                ev = [self._byte() for _ in range(3)]
                return ev[0], ev[1] | (ev[2] << 8)
            except (OSError, serial.SerialException):
                self._drop()
                return None

    def _drop(self):
        try:
            if self.ser:
                self.ser.close()
        except Exception:  # noqa: BLE001
            pass
        self.ser = None                        # next command reopens

    def wait_event(self):
        """Block (politely) until an event arrives."""
        while True:
            ev = self.poll_event()
            if ev:
                return ev
            time.sleep(0.005)

    def _txn(self, frame, first_ok, tail_len):
        """One locked command/response, reopening a dead port on the
        next attempt so a board reboot mid-session self-heals."""
        with self.lock:
            try:
                self._ensure()
                self.ser.write(bytes(frame))
                return self._resp(first_ok, tail_len)
            except (OSError, serial.SerialException) as e:
                self._drop()
                raise IOError(f"serial link lost ({e}); "
                              f"retry — it reconnects on the next command")

    def halt(self):
        t = self._txn([C_HALT], C_HALT, 2)
        return t[0] | (t[1] << 8)

    def run(self):
        self._txn([C_RUN], C_RUN, 0)

    def step(self):
        t = self._txn([C_STEP], C_STEP, 2)
        return t[0] | (t[1] << 8)

    def regs(self):
        return self._txn([C_REGS], C_REGS, 30)

    def set_reg(self, idx, val):
        val &= 0xFFFF
        self._txn([C_SETR, idx, val & 0xFF, val >> 8], C_SETR, 2)

    def read_mem(self, addr, n):
        addr &= 0xFFFF                     # DeZog long addresses: bank
        n = min(n, 0x10000 - addr)         # bits above bit 15 drop here
        out = bytearray()
        while n > 0:                       # DeZog reads a whole 64K bank
            chunk = min(n, 0x8000)         # for disassembly; the count
            out += self._txn([C_RDM, addr & 0xFF, addr >> 8,
                              chunk & 0xFF, chunk >> 8], C_RDM, chunk)
            addr = (addr + chunk) & 0xFFFF
            n -= chunk
        return bytes(out)

    def write_mem(self, addr, data):
        addr &= 0xFFFF
        off = 0
        while off < len(data):
            chunk = data[off:off + 0x8000]
            self._txn([C_WRM, addr & 0xFF, addr >> 8,
                       len(chunk) & 0xFF, len(chunk) >> 8]
                      + list(chunk), C_WRM, 0)
            addr = (addr + len(chunk)) & 0xFFFF
            off += len(chunk)

    def set_bp(self, slot, addr, en):
        addr &= 0xFFFF
        self._txn([C_SBP, slot, addr & 0xFF, addr >> 8, 1 if en else 0],
                  C_SBP, 0)

    def status(self):
        t = self._txn([C_STAT], C_STAT, 4)
        return t[0], t[1], t[2] | (t[3] << 8)


def hx(v, w=4):
    return f"0x{v:0{w}X}"


class Bridge:
    TEMP_BP_SLOT = 7          # reserved for stepOver
    BP_SLOTS = range(0, 7)

    def __init__(self, link):
        self.link = link
        self.sock = None
        self.running = False
        self.bps = []

    # ---- notifications ----
    def on_event(self, cause, pc):
        self.running = False
        if cause == 4:
            # the target reset out from under us: it is running free from
            # its reset vector. Retake control and report a clean stop so
            # the session resyncs rather than acting on stale state.
            try:
                pc = self.link.halt()
            except Exception:  # noqa: BLE001
                pass
            self.notify("stopped", {"reason": "pause", "address": pc,
                                    "text": "target reset"})
            return
        self.notify("stopped",
                    {"reason": STOP_REASONS.get(cause, "pause"),
                     "address": pc})

    def notify(self, method, params):
        if self.sock:
            msg = {"jsonrpc": "2.0", "method": method, "params": params}
            self.sock.sendall((json.dumps(msg) + "\n").encode())

    def ensure_halted(self):
        """Guarantee the machine is FROZEN (not just halted) before a
        memory/register op, and report whether it had been running.

        STATUS's halted bit reflects run_mode, not the freeze — and after
        an instruction-stuffing op (getRegisters/setRegister) there is a
        one-instruction window where run_mode is already 0 (STATUS says
        "halted") but the freeze has not re-asserted yet. A memory op in
        that window is refused (0xEE), and since a WRITE_MEM has already
        put its payload on the wire, that desyncs the byte stream. So do
        not trust STATUS here: always issue HALT, which waits for the
        freeze and is idempotent when already frozen."""
        was_running = (self.link.status()[0] & 1) == 0
        self.link.halt()          # waits for the freeze; safe if already frozen
        self.running = False
        return was_running

    # ---- register block decode (rtl/m1_debug.v capture order) ----
    def reg_object(self):
        r = self.link.regs()
        (a, f, b, c, d, e, h, l, ixh, ixl, iyh, iyl,
         i_reg, _fi, r_reg, _fr,
         a2, f2, b2, c2, d2, e2, h2, l2,
         sp_lo, sp_hi, pc_lo, pc_hi, im, iff) = r
        return {
            "AF": hx((a << 8) | f), "BC": hx((b << 8) | c),
            "DE": hx((d << 8) | e), "HL": hx((h << 8) | l),
            "IX": hx((ixh << 8) | ixl), "IY": hx((iyh << 8) | iyl),
            "SP": hx((sp_hi << 8) | sp_lo), "PC": hx((pc_hi << 8) | pc_lo),
            "I": hx(i_reg, 2), "R": hx(r_reg, 2),
            "AF_": hx((a2 << 8) | f2), "BC_": hx((b2 << 8) | c2),
            "DE_": hx((d2 << 8) | e2), "HL_": hx((h2 << 8) | l2),
            "IM": im, "IFF": iff,
        }

    # ---- .cmd loader (TRS-80 load-module format) ----
    def load_cmd(self, path):
        data = open(path, "rb").read()
        i, lo_addr, hi_addr, entry = 0, None, None, None
        while i < len(data):
            typ, ln = data[i], data[i + 1]
            i += 2
            if typ == 0x01:                       # load block; ln counts
                n = ln - 2 if ln > 2 else ln + 254  # the 2 addr bytes too
                addr = data[i] | (data[i + 1] << 8)
                chunk = data[i + 2:i + 2 + n]
                self.link.write_mem(addr, chunk)
                lo_addr = addr if lo_addr is None else min(lo_addr, addr)
                hi_addr = max(hi_addr or 0, addr + n)
                i += 2 + n
            elif typ == 0x02:                     # entry point
                entry = data[i] | (data[i + 1] << 8)
                i += ln
            else:                                 # comment/other: skip
                i += ln
        if entry is not None:
            self.link.set_reg(REG_IDX["PC"], entry)
        return lo_addr or 0, hi_addr or 0, entry or 0

    # ---- stepOver: temp breakpoint after call-family instructions ----
    def step_over(self):
        self.ensure_halted()
        pc = self.link.status()[2]
        op = self.link.read_mem(pc, 1)[0]
        if op in CALL_OPCODES or op == 0x10:      # CALLs, DJNZ
            length = 3 if op in CALL_OPCODES else 2
            self.link.set_bp(self.TEMP_BP_SLOT, (pc + length) & 0xFFFF, True)
            self.link.run()
            cause, npc = self.link.wait_event()
            self.link.set_bp(self.TEMP_BP_SLOT, 0, False)
            return npc, "step"
        if op in RST_OPCODES:
            self.link.set_bp(self.TEMP_BP_SLOT, (pc + 1) & 0xFFFF, True)
            self.link.run()
            cause, npc = self.link.wait_event()
            self.link.set_bp(self.TEMP_BP_SLOT, 0, False)
            return npc, "step"
        return self.link.step(), "step"

    # ---- JSON-RPC dispatch ----
    def handle(self, msg):
        m, p = msg.get("method"), msg.get("params") or {}
        if m == "initialize":
            return {"programName": "trs80-rev-z debug bridge",
                    "version": "0.1",
                    "modelName": "TRS-80 Model I (FPGA)", "modelNumber": 1}
        if m == "getRegisters":
            self.ensure_halted()
            return self.reg_object()
        if m == "setRegister":
            idx = REG_IDX.get(str(p["register"]).upper())
            if idx is None:
                raise ValueError(f"register {p['register']}")
            self.ensure_halted()
            self.link.set_reg(idx, parse_num(p["value"]))
            return True
        if m == "readMemory":
            addr = parse_num(p["address"])
            n = parse_num(p.get("length", p.get("size", 1)))
            was_running = self.ensure_halted()
            data = self.link.read_mem(addr, n)
            if was_running:                    # transparent peek: resume
                self.link.run()
                self.running = True
            return {"address": f"0x{addr:04x}", "size": n,
                    "data": data.hex()}
        if m == "writeMemory":
            addr = parse_num(p["address"])
            was_running = self.ensure_halted()
            self.link.write_mem(addr, bytes.fromhex(p["data"]))
            if was_running:
                self.link.run()
                self.running = True
            return True
        if m == "continue":
            self.link.run()
            self.running = True
            threading.Thread(target=self.wait_stop, daemon=True).start()
            return True
        if m == "pause":
            pc = self.link.halt()
            self.running = False
            self.notify("stopped", {"reason": "pause", "address": pc})
            return True
        if m == "stepInto":
            pc = self.link.step()
            self.notify("stopped", {"reason": "step", "address": pc})
            return True
        if m == "stepOver":
            pc, reason = self.step_over()
            self.notify("stopped", {"reason": reason, "address": pc})
            return True
        if m == "setBreakpoints":
            bps = p.get("breakpoints", [])
            if len(bps) > len(self.BP_SLOTS):
                raise ValueError("too many breakpoints (7 hardware slots)")
            self.bps = [parse_num(bp["address"]) & 0xFFFF for bp in bps]
            for slot in self.BP_SLOTS:
                if slot < len(self.bps):
                    self.link.set_bp(slot, self.bps[slot], True)
                else:
                    self.link.set_bp(slot, 0, False)
            return True
        if m == "launch":
            # the real emulator loads AND starts a .cmd natively; here the
            # bridge does the same against the machine. The client arms a
            # breakpoint at the entry first when it wants stop-at-entry —
            # honor it by reporting the stop instead of racing RUN past it
            # (RUN deliberately steps off a breakpoint under the PC).
            self.ensure_halted()
            lo, hi, entry = self.load_cmd(p["program"])
            if not (entry and any((b & 0xFFFF) == entry
                                  for b in self.bps)):
                self.link.run()
                self.running = True
                threading.Thread(target=self.wait_stop,
                                 daemon=True).start()
            # else: stay halted at the entry, silently — the client is
            # mid-launch and a notification here breaks its init (the
            # real server sends none after 'launch' either)
            return True
        if m == "loadObj":
            self.ensure_halted()
            lo, hi, entry = self.load_cmd(p["filePath"])
            return {"success": True, "startAddress": lo, "endAddress": hi,
                    "entryPoint": entry}
        if m == "saveObj":
            data = self.link.read_mem(parse_num(p["startAddress"]),
                                      parse_num(p["endAddress"])
                                      - parse_num(p["startAddress"]) + 1)
            open(p["filePath"], "wb").write(data)
            return {"success": True}
        if m == "configure":
            return {"message": "no configurable options"}
        raise LookupError(m)

    def wait_stop(self):
        """continue: watch for the stop event without hogging the port
        (pause/halt from the debugger side ends the vigil via the flag)."""
        while self.running:
            ev = self.link.poll_event()
            if ev:
                self.on_event(ev[0], ev[1])
                return
            time.sleep(0.02)

    # ---- server loop ----
    def serve(self, port):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", port))
        srv.listen(1)
        print(f"bridge: listening on 127.0.0.1:{port}")
        while True:
            self.sock, peer = srv.accept()
            print(f"bridge: debugger connected from {peer}")
            buf = b""
            try:
                while True:
                    chunk = self.sock.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        if not line.strip():
                            continue
                        msg = json.loads(line)
                        rsp = {"jsonrpc": "2.0", "id": msg.get("id")}
                        try:
                            rsp["result"] = self.handle(msg)
                        except LookupError as ex:
                            rsp["error"] = {"code": -32601,
                                            "message": f"Method not found: {ex}"}
                        except Exception as ex:  # noqa: BLE001
                            rsp["error"] = {"code": -32602,
                                            "message": str(ex)}
                        self.sock.sendall((json.dumps(rsp) + "\n").encode())
            finally:
                print("bridge: debugger disconnected")
                self.sock = None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--baud", type=int, default=460800)
    ap.add_argument("--port", type=int, default=49152)
    args = ap.parse_args()

    bridge = Bridge(None)
    bridge.link = Link(args.serial, args.baud, bridge.on_event)
    try:
        bridge.serve(args.port)
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
