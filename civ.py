"""
IC-7000 CI-V protocol driver.
No Qt dependencies - pure Python + pyserial.
"""
import threading, time

try:
    import serial
    import serial.tools.list_ports
    SERIAL_OK = True
except ImportError:
    SERIAL_OK = False

PREAMBLE    = 0xFE
EOM         = 0xFD
PC_ADDR     = 0xE0
IC7000_ADDR = 0x70
ACK_OK      = 0xFB
ACK_NG      = 0xFA

REPLY_WAIT  = 0.30   # maks. czas oczekiwania na odpowiedz radia [s]

# -- BCD helpers --------------------------------------------------------
def freq_to_bcd(hz: int) -> list:
    s = f"{hz:010d}"
    pairs = [s[-2:], s[-4:-2], s[-6:-4], s[-8:-6], s[-10:-8]]
    return [(int(p[1]) | (int(p[0]) << 4)) for p in pairs]

def bcd_to_freq(data: list):
    if not data or len(data) < 5:
        return None
    hz, mult = 0, 1
    for byte in data[:5]:
        lo, hi = byte & 0x0F, (byte >> 4) & 0x0F
        if lo > 9 or hi > 9:
            return None
        hz += lo * mult;  mult *= 10
        hz += hi * mult;  mult *= 10
    return hz if 30_000 <= hz <= 470_000_000 else None

def val2bcd(v: int) -> list:
    """Poziom 0-255 -> 2 bajty BCD w kolejnosci Icoma:
    najpierw bajt setek, potem dziesiatki/jednosci. Np. 255 -> [0x02, 0x55]."""
    v = max(0, min(255, int(v)))
    return [v // 100, ((v % 100) // 10 << 4) | (v % 10)]

def bcd_to_val(data, sub=None):
    """Odczyt poziomu: data[0]=setki, data[1]=dziesiatki/jednosci.
    Zwraca 0-255 albo None, gdy brak/zla odpowiedz (wczesniej 0, co
    mylilo sie z prawdziwym zerem)."""
    if data and sub is not None and len(data) >= 3 and data[0] == sub:
        data = data[1:]
    if data and len(data) >= 2:
        hundreds = data[0] & 0x0F
        tens     = (data[1] >> 4) & 0x0F
        ones     = data[1] & 0x0F
        if (data[0] >> 4) == 0 and hundreds <= 9 and tens <= 9 and ones <= 9:
            v = hundreds * 100 + tens * 10 + ones
            return v if v <= 255 else None
    return None

# -- CTCSS --------------------------------------------------------------
CTCSS_TONES = (
     67.0,  69.3,  71.9,  74.4,  77.0,  79.7,  82.5,  85.4,  88.5,  91.5,
     94.8,  97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
    131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
    171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
    203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1,
)

def parse_tone(text):
    """'' -> '' (bez tonu), poprawny ton -> np. '88.5', zly -> None.
    Akceptuje '88.5', '88,5', '885' (dziesiate czesci Hz), '100'."""
    t = str(text or "").strip().lower().replace(",", ".").replace("hz", "").strip()
    if not t:
        return ""
    try:
        v = float(t)
    except ValueError:
        return None
    cands = [v] if "." in t else [v, v / 10.0]
    for c in cands:
        for tone in CTCSS_TONES:
            if abs(c - tone) < 0.05:
                return f"{tone:.1f}"
    return None

def tone_to_bcd(tone_hz: float) -> list:
    """88.5 Hz -> [0x00, 0x08, 0x85] (format komendy 1B 00)."""
    t = int(round(float(tone_hz) * 10))
    s = f"{t:04d}"
    return [0x00, (int(s[0]) << 4) | int(s[1]), (int(s[2]) << 4) | int(s[3])]

# -- Mode tables --------------------------------------------------------
MODES     = {0x00:"LSB", 0x01:"USB", 0x02:"AM", 0x03:"CW", 0x04:"RTTY",
             0x05:"FM",  0x06:"WFM", 0x07:"CW-R", 0x08:"RTTY-R"}
MODE_REV  = {v: k for k, v in MODES.items()}
UI_MODES  = ["LSB", "USB", "AM", "CW", "CW-R", "RTTY", "RTTY-R", "FM"]

DUPLEX    = {"SIMPLEX": 0x10, "DUP-": 0x11, "DUP+": 0x12}

BAND_FREQS = {
    "160m":  1_840_000, "80m":  3_573_000, "40m":  7_074_000,
    "30m":  10_136_000, "20m": 14_074_000, "17m": 18_100_000,
    "15m":  21_074_000, "12m": 24_915_000, "10m": 28_074_000,
    "6m":   50_313_000, "2m": 145_500_000, "70cm":433_500_000,
}
BAND_EDGES = {
    "160m": (1_810_000,   2_000_000), "80m": (3_500_000,   3_800_000),
    "40m":  (7_000_000,   7_200_000), "30m": (10_100_000, 10_150_000),
    "20m":  (14_000_000, 14_350_000), "17m": (18_068_000, 18_168_000),
    "15m":  (21_000_000, 21_450_000), "12m": (24_890_000, 24_990_000),
    "10m":  (28_000_000, 29_700_000), "6m":  (50_000_000, 52_000_000),
    "2m":   (144_000_000, 146_000_000), "70cm": (430_000_000, 440_000_000),
}
BAND_PWR = {
    "160m":100,"80m":100,"40m":100,"30m":100,
    "20m":100,"17m":100,"15m":100,"12m":100,
    "10m":100,"6m":100,"2m":50,"70cm":35,
}
BANDS = list(BAND_FREQS.keys())

def band_for_freq(hz):
    """Nazwa pasma amatorskiego albo 'GEN' poza pasmami."""
    for name, (lo, hi) in BAND_EDGES.items():
        if lo <= hz <= hi:
            return name
    return "GEN"

def max_pwr_for_freq(hz):
    """Maks. moc IC-7000 dla danego zakresu."""
    if hz < 60_000_000:  return 100
    if hz < 300_000_000: return 50
    return 35

def default_mode_for_freq(hz):
    """Rozsadna emisja domyslna dla pamieci bez zapisanej emisji."""
    if 118_000_000 <= hz <= 137_000_000: return "AM"     # lotnicze
    if hz < 10_000_000:                  return "LSB"
    if hz < 60_000_000:                  return "USB"
    return "FM"

SUB_PWR  = 0x0A
SUB_MIC  = 0x0B
AGC_FAST = 0x01
AGC_MED  = 0x02
AGC_SLOW = 0x03
FUNC_AGC  = 0x12
FUNC_COMP = 0x44

# -- Meter scaling (przyblizone krzywe Icoma) ---------------------------
def _interp(raw, pts):
    if raw is None: return None
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if raw <= x1:
            return y0 + (y1 - y0) * (raw - x0) / float(x1 - x0)
    return pts[-1][1]

def smeter_text(raw):
    """0=S0, 120=S9, 241=S9+60."""
    if raw is None: return "S -"
    if raw <= 120:
        return f"S{min(9, int(round(raw / 120.0 * 9)))}"
    db = int(round((raw - 120) / 121.0 * 6)) * 10
    return f"S9+{db}" if db > 0 else "S9"

def swr_from_raw(raw):
    """0=1.0, 48=1.5, 80=2.0, 120=3.0."""
    return _interp(raw, [(0, 1.0), (48, 1.5), (80, 2.0), (120, 3.0), (255, 6.0)])

def po_pct_from_raw(raw):
    """Moc wyjsciowa w % mocy maks.: 0=0%, 141=50%, 213=100%."""
    v = _interp(raw, [(0, 0.0), (141, 50.0), (213, 100.0), (255, 120.0)])
    return None if v is None else max(0.0, v)

# -- CI-V driver --------------------------------------------------------
class CIV:
    def __init__(self, port, baud=9600, addr=IC7000_ADDR):
        self.port = port; self.baud = baud; self.addr = addr
        self.ser  = None; self.connected = False
        self._lock = threading.Lock()

    def connect(self):
        try:
            self.ser = serial.Serial(
                self.port, self.baud,
                bytesize=8, parity="N", stopbits=1,
                timeout=0.05, write_timeout=0.5,
                exclusive=True)
            self.connected = True
            return True
        except Exception as e:
            print(f"Serial: {e}")
            self.ser = None
            return False

    def disconnect(self):
        # pod lockiem - nie zamykamy portu w trakcie transakcji
        with self._lock:
            self.connected = False
            if self.ser:
                try:
                    if self.ser.is_open: self.ser.close()
                except Exception:
                    pass
            self.ser = None

    def _frame(self, cmd, sub=None, data=None):
        f = [PREAMBLE, PREAMBLE, self.addr, PC_ADDR, cmd]
        if sub  is not None: f.append(sub)
        if data:              f.extend(data)
        f.append(EOM)
        return bytes(f)

    def _parse(self, raw, cmd):
        """Szuka w buforze ramki radio->PC dla danej komendy.
        Zwraca (znaleziono, dane): dane = lista bajtow po bajcie komendy
        (lacznie z sub-komenda), [] dla FB (OK), None dla FA (NG).
        Echo wlasnej komendy (adresat = radio) jest pomijane."""
        d = bytes(raw)
        i = 0
        while True:
            i = d.find(b"\xfe\xfe", i)
            if i < 0:
                return False, None
            j = d.find(b"\xfd", i + 2)
            if j < 0:
                return False, None
            k = i
            while k < j and d[k] == PREAMBLE:
                k += 1
            body = d[k:j]                  # to, from, cmd, ...
            if len(body) >= 3 and body[0] == PC_ADDR and body[1] == self.addr:
                c = body[2]
                if c == cmd:    return True, list(body[3:])
                if c == ACK_OK: return True, []
                if c == ACK_NG: return True, None
            i = j + 1

    def _send(self, cmd, sub=None, data=None, wait=REPLY_WAIT):
        """Wysyla komende i czeka tylko do nadejscia odpowiedzi
        (FIX: wczesniej read(64) zawsze czekal pelny timeout ~0.35 s)."""
        with self._lock:
            if not self.connected or not self.ser:
                return None
            try:
                self.ser.reset_input_buffer()
                self.ser.write(self._frame(cmd, sub, data))
                buf = bytearray()
                deadline = time.monotonic() + wait
                while time.monotonic() < deadline:
                    chunk = self.ser.read_until(bytes([EOM]))
                    if chunk:
                        buf += chunk
                        found, res = self._parse(buf, cmd)
                        if found:
                            return res
                return None
            except Exception as e:
                print(f"CIV send: {e}")
                return None

    # -- odczyty ---------------------------------------------------------
    def read_freq(self):
        r = self._send(0x03)
        return bcd_to_freq(r[:5]) if r and len(r) >= 5 else None

    def read_mode(self):
        r = self._send(0x04)
        if r:
            return MODES.get(r[0], f"?{r[0]:02X}"), (r[1] if len(r) > 1 else 1)
        return None

    def read_level(self, sub):  return bcd_to_val(self._send(0x14, sub), sub)
    def read_smeter(self):      return bcd_to_val(self._send(0x15, 0x02), 0x02)
    def read_pwr(self):         return bcd_to_val(self._send(0x15, 0x11), 0x11)
    def read_swr(self):         return bcd_to_val(self._send(0x15, 0x12), 0x12)

    def read_func(self, sub):
        r = self._send(0x16, sub)
        if r and len(r) >= 2 and r[0] == sub:
            return r[1]
        return None

    def read_ptt(self):
        """True/False, albo None gdy radio nie odpowiada na odczyt 1C 00."""
        r = self._send(0x1C, 0x00)
        if r and len(r) >= 2 and r[0] == 0x00:
            return bool(r[1])
        return None

    # -- ustawienia (zwracaja True, gdy radio potwierdzilo FB) ----------
    def _ok(self, r):               return r is not None
    def set_freq(self, hz):         return self._ok(self._send(0x05, data=freq_to_bcd(hz)))
    def set_mode(self, m, f=1):     return self._ok(self._send(0x06, data=[MODE_REV.get(m, 0x01), max(1, min(3, int(f)))]))
    def set_level(self, sub, v):    return self._ok(self._send(0x14, sub=sub, data=val2bcd(v)))
    def set_preamp(self, on):       return self._ok(self._send(0x16, sub=0x02, data=[0x01 if on else 0x00]))
    def set_nb(self, on):           return self._ok(self._send(0x16, sub=0x22, data=[0x01 if on else 0x00]))
    def set_nr(self, on):           return self._ok(self._send(0x16, sub=0x40, data=[0x01 if on else 0x00]))
    def set_comp(self, on):         return self._ok(self._send(0x16, sub=FUNC_COMP, data=[0x01 if on else 0x00]))
    def set_agc(self, speed):       return self._ok(self._send(0x16, sub=FUNC_AGC, data=[int(speed)]))
    # FIX: ton on/off to 16 42; 1B 00 ustawia czestotliwosc tonu
    def set_tone(self, on):         return self._ok(self._send(0x16, sub=0x42, data=[0x01 if on else 0x00]))
    def set_tone_freq(self, hz):    return self._ok(self._send(0x1B, sub=0x00, data=tone_to_bcd(hz)))
    def set_duplex(self, dup):
        code = DUPLEX.get(str(dup).upper())
        return self._ok(self._send(0x0F, sub=code)) if code is not None else False
    # FIX: 07 = tryb VFO, 08 = tryb pamieci (wczesniej 07 00/01 = VFO A/B)
    def set_vfo_mem(self, mem):     return self._ok(self._send(0x08 if mem else 0x07))
    def set_ptt(self, on):          return self._ok(self._send(0x1C, sub=0x00, data=[0x01 if on else 0x00]))
    def scan_start(self):           return self._ok(self._send(0x0E, sub=0x01))
    def scan_stop(self):            return self._ok(self._send(0x0E, sub=0x00))

def list_ports():
    if not SERIAL_OK: return []
    return [p.device for p in serial.tools.list_ports.comports()]
