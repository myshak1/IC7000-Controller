"""Self-contained tests: helpers, APRS encoding and the CI-V driver against a
simulated IC-7000 on a pseudo-terminal. Linux only. Run: python3 tests/test_civ.py"""
import sys, os, pty, threading, time, tty
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from civ import *
import backend as B
from backend import (RadioBackend, _aprs_decode_info, _aprs_position_payload, _ax25_ui_frame,
                     _ax25_parse, _kiss_escape, _kiss_unescape, _kiss_extract, _aprs_msg_payload, _deg_to_aprs)

# --- helpers
assert bcd_to_freq(freq_to_bcd(14_074_500)) == 14_074_500
assert val2bcd(255) == [0x02, 0x55] and bcd_to_val([0x0A, 0x02, 0x55], 0x0A) == 255
assert bcd_to_val(None) is None
assert tone_to_bcd(88.5) == [0x00, 0x08, 0x85] and tone_to_bcd(103.5) == [0x00, 0x10, 0x35]
assert parse_tone("76") is None and parse_tone("77") == "77.0" and parse_tone("885") == "88.5"
assert parse_tone("") == "" and parse_tone("100") == "100.0" and parse_tone("abc") is None
assert band_for_freq(14_200_000) == "20m" and band_for_freq(123_980_000) == "GEN"
assert default_mode_for_freq(123_980_000) == "AM" and default_mode_for_freq(7_074_000) == "LSB"
assert smeter_text(120) == "S9" and smeter_text(241) == "S9+60" and smeter_text(0) == "S0"
assert abs(swr_from_raw(48) - 1.5) < 1e-9
P = RadioBackend._parse_freq_text
cases = {"14.200.000":14_200_000, "14.0745":14_074_500, "7074":7_074_000, "145500000":145_500_000,
         "433":433_000_000, "7.074 MHz":7_074_000, "7074 kHz":7_074_000, "145.5":145_500_000,
         "123.980.000":123_980_000, "3,573":3_573_000, "999":None, "abc":None, "14.2.5":14_200_500}
for k, v in cases.items():
    assert P(k) == v, (k, P(k), v)

# --- APRS
assert _deg_to_aprs(45.5, True) == "4530.00N" and _deg_to_aprs(10.25, False) == "01015.00E"
assert _deg_to_aprs(54.99999, True) == "5500.00N"
pl = _aprs_position_payload("TEST").decode()
d = _aprs_decode_info(pl)
assert d["kind"] == "pos" and abs(d["lat"] - B.APRS_LAT) < 0.001 and d["text"] == "TEST", d
m = _aprs_decode_info(":N0CALL   :czesc{12")
assert m == {"kind": "msg", "to": "N0CALL", "text": "czesc", "msgid": "12"}, m
assert _aprs_decode_info(":N0CALL   :ack12")["kind"] == "ack"
assert _aprs_decode_info("@092345z5415.93N/01838.53E>mobile")["kind"] == "pos"
assert _aprs_msg_payload("sp2abc", "hi{|", 3) == b":SP2ABC   :hi{3"
fr = _ax25_ui_frame("APZIC7", "N0CALL", ("WIDE1-1", "WIDE2-1"), b"!test")
assert _ax25_parse(fr) == ("N0CALL", "APZIC7", "!test"), _ax25_parse(fr)
assert fr[6] & 0x80 and not (fr[13] & 0x80)
buf = bytearray(bytes([0xC0, 0x00]) + _kiss_escape(fr + b"\xc0") + bytes([0xC0]))
frames = _kiss_extract(buf)
assert len(frames) == 1 and _kiss_unescape(frames[0][1:]) == fr + b"\xc0"
print("helpers OK")

# --- simulated IC-7000 on a pseudo-terminal (with echo, like a real CI-V bus)
master, slave = pty.openpty()
tty.setraw(master); tty.setraw(slave)
state = {"freq": 14_200_000, "mode": 0x01, "filt": 1, "ptt": 0, "pwr": 200, "agc": 2, "comp": 0,
         "log": []}
def radio():
    buf = b""
    while True:
        try: data = os.read(master, 256)
        except OSError: return
        buf += data
        while b"\xfd" in buf:
            fr, buf = buf.split(b"\xfd", 1)
            fr += b"\xfd"
            os.write(master, fr)                          # echo
            body = fr[2:-1]; to, frm, cmd, rest = body[0], body[1], body[2], list(body[3:])
            if to != 0x70: continue
            state["log"].append((cmd, rest))
            rep = None
            if cmd == 0x03: rep = [0x03] + freq_to_bcd(state["freq"])
            elif cmd == 0x04: rep = [0x04, state["mode"], state["filt"]]
            elif cmd == 0x05: state["freq"] = bcd_to_freq(rest); rep = [0xFB]
            elif cmd == 0x06: state["mode"], state["filt"] = rest[0], rest[1]; rep = [0xFB]
            elif cmd == 0x14 and len(rest) == 1: rep = [0x14, rest[0]] + val2bcd(state["pwr"])
            elif cmd == 0x14: state["pwr"] = bcd_to_val(rest, rest[0]); rep = [0xFB]
            elif cmd == 0x15: rep = [0x15, rest[0]] + val2bcd(120)
            elif cmd == 0x16 and len(rest) == 1: rep = [0x16, rest[0], state["agc"] if rest[0]==0x12 else state["comp"]]
            elif cmd == 0x1C and len(rest) == 1: rep = [0x1C, 0x00, state["ptt"]]
            elif cmd == 0x1C: state["ptt"] = rest[1]; rep = [0xFB]
            elif cmd == 0x99: rep = [0xFA]
            else: rep = [0xFB]
            time.sleep(0.005)
            os.write(master, bytes([0xFE, 0xFE, 0xE0, 0x70] + rep + [0xFD]))
threading.Thread(target=radio, daemon=True).start()

c = CIV(os.ttyname(slave), 9600)
c.connect()
t = time.monotonic(); f = c.read_freq(); dt = time.monotonic() - t
assert f == 14_200_000, f
print(f"read_freq = {f} in {dt*1000:.0f} ms")
assert dt < 0.15
assert c.read_mode() == ("USB", 1)
assert c.set_freq(7_074_000) and c.read_freq() == 7_074_000
assert c.read_level(SUB_PWR) == 200
assert c.set_level(SUB_PWR, 255) and c.read_level(SUB_PWR) == 255
assert c.read_smeter() == 120 and c.read_func(FUNC_AGC) == 2
assert c.set_ptt(True) and c.read_ptt() is True and c.set_ptt(False) and c.read_ptt() is False
assert c._send(0x99) is None                              # NG reply
c.set_vfo_mem(1); c.set_vfo_mem(0)
assert state["log"][-2] == (0x08, []) and state["log"][-1] == (0x07, []), state["log"][-2:]
c.set_tone_freq(88.5); assert state["log"][-1] == (0x1B, [0x00, 0x00, 0x08, 0x85])
c.set_tone(True);      assert state["log"][-1] == (0x16, [0x42, 0x01])
c.set_duplex("DUP-");  assert state["log"][-1] == (0x0F, [0x11])
t = time.monotonic()
for _ in range(20): c.read_freq()
print(f"20 reads: {(time.monotonic()-t)*1000:.0f} ms")
c.disconnect()
print("CI-V OK")
