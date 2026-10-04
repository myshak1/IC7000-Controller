import json, math, os, re, socket, subprocess, threading, time, datetime
import xmlrpc.client
import urllib.request
import xml.etree.ElementTree as ET
from PyQt6.QtCore import QObject, pyqtSignal, pyqtSlot, QTimer
from civ import (
    CIV, BANDS, BAND_FREQS, BAND_PWR, UI_MODES, DUPLEX,
    SUB_PWR, SUB_MIC, AGC_MED, FUNC_AGC, FUNC_COMP,
    band_for_freq, max_pwr_for_freq, default_mode_for_freq, parse_tone,
    smeter_text, swr_from_raw, po_pct_from_raw,
    list_ports, SERIAL_OK
)
from config import CONFIG, PLACEHOLDER_CALLS

SOLAR_URL     = "https://www.hamqsl.com/solarxml.php"
SOLAR_MAX_AGE = 15 * 60      # automatyczne odswiezenie najwyzej co 15 min

# ---------------- APRS / direwolf (KISS TCP) ----------------
# Dane stacji pochodza z config.json (patrz config.py / config.example.json)
KISS_HOST   = CONFIG["kiss_host"]
KISS_PORT   = CONFIG["kiss_port"]
MYCALL      = CONFIG["callsign"]
APRS_TOCALL = CONFIG["aprs_tocall"]       # APZxxx = zakres eksperymentalny
APRS_PATH   = tuple(CONFIG["aprs_path"])
APRS_FREQ   = 144_800_000
FEND, FESC, TFEND, TFESC = 0xC0, 0xDB, 0xDC, 0xDD

# Pozycja QTH do beacona pozycyjnego
APRS_LAT = CONFIG["lat"]
APRS_LON = CONFIG["lon"]
APRS_SYM_TABLE = CONFIG["aprs_symbol_table"]
APRS_SYM       = CONFIG["aprs_symbol"]

# Czasy nadawania - musza zgadzac sie z direwolf.conf (TXDELAY 30, TXTAIL 10)
# WAZNE: w direwolf.conf ustaw FULLDUP ON, inaczej direwolf moze odlozyc
# nadanie (CSMA) na moment, gdy PTT jest juz zwolnione.
DW_TXDELAY = 0.30
DW_TXTAIL  = 0.10
PTT_LEAD   = 0.25   # czas na przejscie radia w TX po komendzie CI-V

# ---------------- fldigi (XML-RPC) ----------------
FLDIGI_URL     = CONFIG["fldigi_url"]
FLDIGI_TIMEOUT = 3.0
DEC_TEXT_MAX   = 4000


class _TimeoutTransport(xmlrpc.client.Transport):
    """ServerProxy bez timeoutu potrafi zawisnac na zawsze."""
    def __init__(self, timeout=FLDIGI_TIMEOUT):
        super().__init__()
        self._timeout = timeout

    def make_connection(self, host):
        conn = super().make_connection(host)
        conn.timeout = self._timeout
        return conn

def _fldigi():
    return xmlrpc.client.ServerProxy(FLDIGI_URL, transport=_TimeoutTransport())


def _fetch_solar():
    try:
        req = urllib.request.Request(SOLAR_URL, headers={"User-Agent": "IC7000-Ctrl/2.1"})
        with urllib.request.urlopen(req, timeout=12) as r:
            raw = r.read()
        root = ET.fromstring(raw)
        sc = root.find(".//solardata")
        if sc is None:
            return None

        def g(tag, default="N/A"):
            el = sc.find(tag)
            return el.text.strip() if el is not None and el.text else default

        bands = {}
        cc = sc.find("calculatedconditions")
        if cc is not None:
            for band in cc.findall("band"):
                name = band.get("name", "")
                time_attr = band.get("time", "")
                cond = band.text.strip() if band.text else "N/A"
                bands[name + "_" + time_attr] = cond
        # VHF (6m/2m) - hamqsl podaje je jako "phenomenon", nie "band"
        vhf = sc.find("calculatedvhfconditions")
        if vhf is not None:
            for ph in vhf.findall("phenomenon"):
                name = (ph.get("name", "") or "").lower()
                loc  = (ph.get("location", "") or "").lower()
                cond = ph.text.strip() if ph.text else "N/A"
                if name == "e-skip" and loc == "europe_6m":
                    bands["6m_day"] = bands["6m_night"] = cond
                elif name == "e-skip" and loc == "europe":
                    bands["2m_day"] = bands["2m_night"] = cond

        return {
            "sfi":      g("solarflux"),
            "sunspots": g("sunspots"),
            "aindex":   g("aindex"),
            "kindex":   g("kindex"),
            "xray":     g("xray"),
            "noise":    g("signalnoise"),
            "wind":     g("solarwind"),
            "geo":      g("geomagfield"),
            "updated":  g("updated"),
            "bands":    bands,
        }
    except Exception as e:
        print(f"Solar: {e}")
        return None


def _list_audio_devices():
    """Karty ALSA z nagrywaniem (arecord) i odtwarzaniem (aplay), bez duplikatow."""
    devices, seen = [], set()
    for tool in ("arecord", "aplay"):
        try:
            out = subprocess.check_output(
                [tool, "-l"], stderr=subprocess.DEVNULL, text=True, timeout=3)
        except Exception:
            continue
        for line in out.splitlines():
            m = re.match(r"card\s+(\d+):", line)
            if m and m.group(1) not in seen:
                seen.add(m.group(1))
                devices.append(line.strip())
    return devices or ["default"]


_MIXER_IN  = ("Mic", "Capture", "Line", "ADC")
_MIXER_OUT = ("Speaker", "PCM", "Master", "Headphone", "Line Out")

def _find_mixer_control(card, prefs):
    """Znajdz nazwe kontrolki amixer na danej karcie (rozne karty = rozne nazwy)."""
    try:
        out = subprocess.check_output(
            ["amixer", "-c", card, "scontrols"],
            stderr=subprocess.DEVNULL, text=True, timeout=2)
    except Exception:
        return None
    names = re.findall(r"'([^']+)'", out)
    for p in prefs:
        for n in names:
            if n.lower() == p.lower():
                return n
    for p in prefs:
        for n in names:
            if p.lower() in n.lower():
                return n
    return None


# ---------------- AX.25 / KISS helpers ----------------
def _ax25_addr_decode(buf):
    call = "".join(chr((b >> 1) & 0x7F) for b in buf[:6]).strip()
    ssid = (buf[6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call

def _ax25_parse(frame):
    """Zwraca (src, dest, info) dla ramek UI, inaczej None."""
    if len(frame) < 16:
        return None
    i = 14
    while i <= len(frame) - 7 and not (frame[i - 1] & 0x01):
        i += 7                                  # pomin digipeatery
    if i + 2 > len(frame) or frame[i] != 0x03 or frame[i + 1] != 0xF0:
        return None
    dest = _ax25_addr_decode(frame[0:7])
    src  = _ax25_addr_decode(frame[7:14])
    info = frame[i + 2:].decode("ascii", errors="replace").rstrip("\r\n")
    return src, dest, info

def _ax25_addr_encode(call, last=False, cbit=False):
    if "-" in call:
        base, ssid = call.split("-", 1); ssid = int(ssid)
    else:
        base, ssid = call, 0
    base = (base.upper() + "      ")[:6]
    out = bytes((ord(c) << 1) for c in base)
    return out + bytes([((ssid & 0x0F) << 1) | 0x60
                        | (0x80 if cbit else 0) | (1 if last else 0)])

def _ax25_ui_frame(dest, src, path, payload):
    """Ramka UI AX.25 v2 (bit C ustawiony w adresie docelowym)."""
    addrs = [_ax25_addr_encode(dest, cbit=True),
             _ax25_addr_encode(src, last=not path)]
    for n, p in enumerate(path):
        addrs.append(_ax25_addr_encode(p, last=(n == len(path) - 1)))
    return b"".join(addrs) + b"\x03\xf0" + payload

def _kiss_escape(data):
    out = bytearray()
    for b in data:
        if b == FEND:   out += bytes([FESC, TFEND])
        elif b == FESC: out += bytes([FESC, TFESC])
        else:           out.append(b)
    return bytes(out)

def _kiss_unescape(data):
    out, esc = bytearray(), False
    for b in data:
        if esc:
            out.append(FEND if b == TFEND else (FESC if b == TFESC else b))
            esc = False
        elif b == FESC:
            esc = True
        else:
            out.append(b)
    return bytes(out)

def _kiss_extract(buf):
    """Wyciaga kompletne ramki KISS z bufora (modyfikuje bufor)."""
    frames = []
    while True:
        try:
            start = buf.index(FEND)
            end   = buf.index(FEND, start + 1)
        except ValueError:
            break
        raw = bytes(buf[start + 1:end])
        del buf[:end]
        if raw:
            frames.append(raw)
    return frames


# ---------------- APRS payloads ----------------
def _deg_to_aprs(v, is_lat):
    hemi = ("N" if v >= 0 else "S") if is_lat else ("E" if v >= 0 else "W")
    v = abs(v)
    deg = int(v)
    mins = round((v - deg) * 60, 2)
    if mins >= 60.0:                       # FIX: 59.996 -> "60.00" bylo bledne
        deg += 1; mins = 0.0
    return (f"{deg:02d}" if is_lat else f"{deg:03d}") + f"{mins:05.2f}{hemi}"

def _aprs_position_payload(comment):
    """Ramka pozycyjna APRS: '!DDMM.mmN/DDDMM.mmE-komentarz'."""
    lat_s = _deg_to_aprs(APRS_LAT, True)
    lon_s = _deg_to_aprs(APRS_LON, False)
    comment = comment[:43]
    return f"!{lat_s}{APRS_SYM_TABLE}{lon_s}{APRS_SYM}{comment}".encode("ascii", "replace")

def _aprs_msg_payload(to, text, msgid):
    text = re.sub(r"[|~{]", "", text)[:67]
    return f":{to.upper():<9}:{text}{{{msgid}".encode("ascii", "replace")

def _aprs_ack_payload(to, msgid):
    return f":{to.upper():<9}:ack{msgid}".encode("ascii", "replace")

def _parse_lat(s):
    try:
        s = s.replace(" ", "0")
        v = int(s[0:2]) + float(s[2:7]) / 60.0
        return -v if s[7].upper() == "S" else v
    except (ValueError, IndexError):
        return None

def _parse_lon(s):
    try:
        s = s.replace(" ", "0")
        v = int(s[0:3]) + float(s[3:8]) / 60.0
        return -v if s[8].upper() == "W" else v
    except (ValueError, IndexError):
        return None

def _aprs_decode_info(info):
    """Prosty dekoder pola info APRS: wiadomosc / ack / pozycja / inne."""
    if info.startswith(":") and len(info) >= 11 and info[10] == ":":
        to, body = info[1:10].strip(), info[11:]
        m = re.match(r"^(ack|rej)([A-Za-z0-9]{1,5})\s*$", body)
        if m:
            return {"kind": m.group(1), "to": to, "msgid": m.group(2), "text": body}
        msgid = ""
        if "{" in body:
            body, msgid = body.rsplit("{", 1)
            msgid = msgid.split("}")[0][:5].strip()
        return {"kind": "msg", "to": to, "text": body, "msgid": msgid}
    pos = info
    if info[:1] in ("/", "@") and len(info) > 8:
        pos = "!" + info[8:]                # pomin znacznik czasu
    if pos[:1] in ("!", "=") and len(pos) >= 20:
        lat, lon = _parse_lat(pos[1:9]), _parse_lon(pos[10:19])
        if lat is not None and lon is not None:
            return {"kind": "pos", "lat": lat, "lon": lon, "text": pos[20:]}
    return {"kind": "other", "text": info}

def _distance_km(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


class RadioBackend(QObject):
    freqChanged      = pyqtSignal(str,   arguments=["freq"])
    modeChanged      = pyqtSignal(str,   arguments=["mode"])
    filtChanged      = pyqtSignal(int,   arguments=["filt"])
    txChanged        = pyqtSignal(bool,  arguments=["tx"])
    connectedChanged = pyqtSignal(bool,  arguments=["connected"])
    statusChanged    = pyqtSignal(str,   arguments=["text"])
    utcChanged       = pyqtSignal(str,   arguments=["utc"])
    bandsReady       = pyqtSignal("QVariantList", arguments=["bands"])
    modesReady       = pyqtSignal("QVariantList", arguments=["modes"])
    portsReady       = pyqtSignal("QVariantList", arguments=["ports"])
    bandChanged      = pyqtSignal(str,   arguments=["band"])
    maxPwrChanged    = pyqtSignal(int,   arguments=["maxPwr"])
    agcChanged       = pyqtSignal(int,   arguments=["agc"])
    connectError     = pyqtSignal(str,   arguments=["msg"])
    setPwrPctChanged = pyqtSignal(int,   arguments=["pct"])
    micPctChanged    = pyqtSignal(int,   arguments=["pct"])
    solarChanged     = pyqtSignal("QVariantMap",  arguments=["data"])
    memoriesReady    = pyqtSignal("QVariantList", arguments=["memories"])
    memoryAddResult  = pyqtSignal(bool, str, arguments=["ok", "msg"])
    civActivity      = pyqtSignal()
    audioDevicesReady = pyqtSignal("QVariantList", arguments=["devices"])
    audioInLevel     = pyqtSignal(float, arguments=["level"])
    audioOutLevel    = pyqtSignal(float, arguments=["level"])
    aprsMessagesReady = pyqtSignal("QVariantList", arguments=["messages"])
    vfoMemChanged    = pyqtSignal(int,   arguments=["mode"])
    compChanged      = pyqtSignal(bool,  arguments=["on"])
    scanChanged      = pyqtSignal(bool,  arguments=["on"])
    meterChanged     = pyqtSignal(float, str, arguments=["level", "text"])
    # dekoder fldigi
    decoderText      = pyqtSignal(str,  arguments=["text"])
    decoderStatus    = pyqtSignal(str,  arguments=["status"])
    decoderRunning   = pyqtSignal(bool, arguments=["running"])

    def __init__(self, parent=None):
        super().__init__(parent)
        self._radio             = None
        self._connected         = False
        self._polling           = False
        self._poll_n            = 0
        self._mode_lock_until   = 0.0
        self._scanning          = False
        self._comp              = False
        self._cur_freq          = 14_200_000
        self._cur_band          = "20m"
        self._cur_mode          = "USB"
        self._cur_filt          = 1
        self._cur_agc           = AGC_MED
        self._max_pwr           = 100
        self._tx                = False
        self._set_pwr_pct       = 78
        self._mic_pct           = 50
        self._last_level_send   = {}
        self._pending_levels    = {}
        self._level_timers      = set()
        self._level_edit_until  = {}
        self._vfo_mem_mode      = 0
        self._audio_device      = "default"
        self._audio_in_gain     = 50
        self._audio_out_gain    = 50
        self._mixer_cache       = {}
        # APRS
        self._aprs_messages     = []
        self._aprs_lock         = threading.Lock()
        self._aprs_evt          = None       # Event petli KISS (None = nie dziala)
        self._aprs_active       = False
        self._aprs_saved        = None       # (freq, mode, filt) sprzed APRS
        self._aprs_msgid        = 0
        self._aprs_acked        = {}
        self._kiss_sock         = None
        self._tx_lock           = threading.Lock()
        # fldigi
        self._dec_evt           = None
        self._dec_running       = False
        self._dec_mode          = "CW"
        self._dec_last_rx       = 0.0
        self._dec_wpm_method    = None
        # solar
        self._solar_cache       = None
        self._solar_ts          = 0.0
        self._solar_busy        = False

        self._memory_path       = os.path.join(os.path.dirname(os.path.abspath(__file__)), "memories.json")
        self._memories          = self._load_memories()

        self._utc_timer = QTimer(self)
        self._utc_timer.timeout.connect(self._tick_utc)
        self._utc_timer.start(1000)
        self._tick_utc()

        self._audio_timer = QTimer(self)
        self._audio_timer.timeout.connect(self._tick_audio_levels)
        self._audio_timer.start(150)

        QTimer.singleShot(0, self._emit_static)
        threading.Thread(target=self._poll_loop, daemon=True).start()

    def _emit_static(self):
        self.bandsReady.emit(BANDS)
        self.modesReady.emit(UI_MODES)
        self.bandChanged.emit(self._cur_band)
        self.maxPwrChanged.emit(self._max_pwr)
        self.agcChanged.emit(self._cur_agc)
        self.setPwrPctChanged.emit(self._set_pwr_pct)
        self.micPctChanged.emit(self._mic_pct)
        self.compChanged.emit(self._comp)
        self.scanChanged.emit(self._scanning)
        self.vfoMemChanged.emit(self._vfo_mem_mode)
        self.memoriesReady.emit(self._memories)
        self.audioDevicesReady.emit(_list_audio_devices())

    def _tick_utc(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        self.utcChanged.emit(now.strftime("%H:%M:%S"))

    def _tick_audio_levels(self):
        """IN = aktywnosc dekodera fldigi, OUT = nadawanie (PTT)."""
        if self._dec_running:
            lvl = max(0.0, 1.0 - (time.monotonic() - self._dec_last_rx) / 3.0)
        else:
            lvl = 0.0
        self.audioInLevel.emit(lvl)
        self.audioOutLevel.emit(1.0 if self._tx else 0.0)

    # ---------------- solar ----------------
    def _fetch_solar_bg(self):
        if self._solar_busy:
            return
        self._solar_busy = True
        threading.Thread(target=self._do_solar, daemon=True).start()

    def _do_solar(self):
        try:
            d = _fetch_solar()
            if d:
                self._solar_cache = d
                self._solar_ts = time.monotonic()
            elif self._solar_cache:
                d = dict(self._solar_cache)
                d["updated"] = d.get("updated", "") + " (offline)"
            else:
                d = {"updated": "Fetch failed", "bands": {}}
            self.solarChanged.emit(d)
        finally:
            self._solar_busy = False

    @pyqtSlot()
    def refreshSolar(self):
        """Wymuszone odswiezenie (przycisk REFRESH)."""
        self._fetch_solar_bg()

    @pyqtSlot()
    def refreshSolarAuto(self):
        """Wejscie na zakladke: pobierz tylko, gdy dane sa stare."""
        if self._solar_cache and time.monotonic() - self._solar_ts < SOLAR_MAX_AGE:
            self.solarChanged.emit(self._solar_cache)
        else:
            self._fetch_solar_bg()

    # ---------------- pamieci: plik ----------------
    def _normalize_memory(self, item):
        freq_raw = str(item.get("freq", ""))
        hz = self._parse_freq_text(freq_raw)
        mode = str(item.get("mode", "")).upper()
        if mode not in UI_MODES and mode != "WFM":
            mode = default_mode_for_freq(hz) if hz else "USB"
        tone = parse_tone(item.get("tone", ""))
        if tone is None:
            print(f"Memories: '{item.get('name','')}' - zly ton CTCSS "
                  f"'{item.get('tone','')}', pomijam")
            tone = ""
        dup = str(item.get("dup", "SIMPLEX")).upper()
        if dup not in DUPLEX:
            dup = "SIMPLEX"
        return {
            "name": str(item.get("name", "")),
            "freq": self._fmt_freq(hz) if hz else freq_raw,
            "mode": mode,
            "tone": tone,
            "dup":  dup,
        }

    def _load_memories(self):
        try:
            with open(self._memory_path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, list):
                return [self._normalize_memory(it) for it in data if isinstance(it, dict)]
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"Memories load: {e}")
        return []

    def _save_memories(self):
        try:
            tmp = self._memory_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self._memories, fh, indent=2)
            os.replace(tmp, self._memory_path)       # zapis atomowy
        except Exception as e:
            print(f"Memories save: {e}")

    @staticmethod
    def _parse_freq_text(text):
        """Akceptuje: '14.200.000', '14.0745' (zawsze MHz przy jednej kropce),
        '7074' (kHz), '145500000' (Hz), '433' (MHz), '7.074 MHz', '7074 kHz'."""
        src = str(text).strip().lower().replace(",", ".").replace(" ", "")
        mul = None
        for unit, m in (("mhz", 1_000_000), ("khz", 1000), ("hz", 1)):
            if src.endswith(unit):
                mul, src = m, src[:-len(unit)]
                break
        if not src:
            return None
        try:
            dots = src.count(".")
            if mul is not None and dots <= 1:
                hz = int(round(float(src) * mul))
            elif dots == 2:
                mhz, khz, rest = src.split(".")
                if not (mhz.isdigit() and khz.isdigit() and len(khz) <= 3
                        and (rest == "" or (rest.isdigit() and len(rest) <= 3))):
                    return None
                hz = (int(mhz) * 1_000_000 + int(khz.ljust(3, "0")) * 1000
                      + (int(rest.ljust(3, "0")) if rest else 0))
            elif dots == 1:
                hz = int(round(float(src) * 1_000_000))
            elif dots == 0 and src.isdigit():
                n = int(src)
                if n >= 1_000_000:  hz = n
                elif n >= 1000:     hz = n * 1000
                else:               hz = n * 1_000_000
            else:
                return None
            return hz if 30_000 <= hz <= 470_000_000 else None
        except ValueError:
            return None

    @staticmethod
    def _fmt_freq(hz):
        if hz is None: return "---"
        if hz >= 1_000_000:
            s = f"{hz:09d}"
            return f"{int(s[:-6])}.{s[-6:-3]}.{s[-3:]}"
        return f"0.{hz//1000:03d}.{hz%1000:03d}"

    # ---------------- stan pasma / emisji ----------------
    def _lock_mode(self, seconds=2.0):
        self._mode_lock_until = time.monotonic() + seconds

    def _update_band_from_freq(self, hz):
        band = band_for_freq(hz)
        pwr = BAND_PWR.get(band, max_pwr_for_freq(hz))
        if band != self._cur_band:
            self._cur_band = band
            self.bandChanged.emit(band)
        if pwr != self._max_pwr:
            self._max_pwr = pwr
            self.maxPwrChanged.emit(pwr)

    def _set_state(self, hz=None, mode=None, filt=None):
        """Aktualizuje stan lokalny + UI (bez wysylania do radia)."""
        if hz is not None:
            self._cur_freq = hz
            self.freqChanged.emit(self._fmt_freq(hz))
            self._update_band_from_freq(hz)
        if mode is not None:
            self._cur_mode = mode
            self.modeChanged.emit(mode)
        if filt is not None:
            self._cur_filt = filt
            self.filtChanged.emit(filt)

    def _tune(self, hz, mode=None, filt=None):
        """Ustaw czestotliwosc (i opcjonalnie emisje) w UI i w radiu."""
        self._lock_mode()
        self._set_state(hz, mode, filt)
        radio = self._radio
        if radio:
            f = filt if filt is not None else self._cur_filt
            def _w():
                radio.set_freq(hz)
                if mode:
                    radio.set_mode(mode, f)
            threading.Thread(target=_w, daemon=True).start()

    # ---------------- odpytywanie radia ----------------
    def _poll_loop(self):
        while True:
            radio = self._radio                     # kopia lokalna (FIX wyscigu)
            if self._polling and radio:
                try:
                    self._poll_once(radio)
                except Exception as e:
                    print(f"Poll: {e}")
                time.sleep(0.15)
            else:
                time.sleep(0.4)

    def _poll_once(self, radio):
        self._poll_n += 1

        f = radio.read_freq()
        if f:
            if f != self._cur_freq:
                self._cur_freq = f
                self.freqChanged.emit(self._fmt_freq(f))
                self._update_band_from_freq(f)   # FIX: pasmo sledzi galke
            self.civActivity.emit()

        if time.monotonic() >= self._mode_lock_until:
            m = radio.read_mode()
            if m and (m[0], m[1]) != (self._cur_mode, self._cur_filt):
                self._cur_mode, self._cur_filt = m
                self.modeChanged.emit(self._cur_mode)
                self.filtChanged.emit(self._cur_filt)

        # FIX: TX z komendy 1C 00 (dziala tez w SSB bez modulacji);
        # gdy radio nie odpowiada - zapasowo po mierniku Po
        tx = radio.read_ptt()
        po = None
        if tx is None:
            po = radio.read_pwr()
            tx = po is not None and po > 8
        if tx != self._tx:
            self._tx = tx
            self.txChanged.emit(tx)

        if self._tx:
            if po is None:
                po = radio.read_pwr()
            swr = radio.read_swr()
            pct = po_pct_from_raw(po)
            lvl = min(1.0, (pct or 0) / 100.0)
            watts = round((pct or 0) / 100.0 * self._max_pwr)
            txt = f"PO {watts}W"
            sw = swr_from_raw(swr)
            if sw is not None:
                txt += f"  SWR {sw:.1f}"
            self.meterChanged.emit(lvl, txt)
        else:
            s = radio.read_smeter()
            self.meterChanged.emit(min(1.0, (s or 0) / 241.0), smeter_text(s))

        if self._poll_n % 4 == 0:
            for sub, attr, signal in (
                (SUB_PWR, "_set_pwr_pct", self.setPwrPctChanged),
                (SUB_MIC, "_mic_pct",     self.micPctChanged),
            ):
                if time.monotonic() < self._level_edit_until.get(sub, 0):
                    continue
                raw = radio.read_level(sub)
                if raw is None:
                    continue
                pct = round(raw / 255.0 * 100)
                if pct != getattr(self, attr):
                    setattr(self, attr, pct)
                    signal.emit(pct)

        if self._poll_n % 8 == 0:
            agc = radio.read_func(FUNC_AGC)
            if agc in (1, 2, 3) and agc != self._cur_agc:
                self._cur_agc = agc
                self.agcChanged.emit(agc)
            comp = radio.read_func(FUNC_COMP)
            if comp is not None and bool(comp) != self._comp:
                self._comp = bool(comp)
                self.compChanged.emit(self._comp)

    # ------------------------------------------------------------------ slots
    @pyqtSlot(str, str, str, str)
    def connectRadio(self, port, baud, addr_hex, audio_device):
        if not SERIAL_OK:
            self.connectError.emit("pyserial nie jest zainstalowany")
            return
        self._audio_device = audio_device or "default"
        try:
            addr = int(str(addr_hex).strip(), 16)
        except ValueError:
            addr = 0x70
        try:
            baud_i = int(baud)
        except ValueError:
            baud_i = 9600

        def _t():
            if self._radio:
                self._disconnect_internal()
            civ = CIV(port, baud_i, addr)
            if not civ.connect():
                self.connectError.emit(f"Nie mozna otworzyc {port}")
                return
            # FIX: sprawdz, czy radio naprawde odpowiada
            f = civ.read_freq()
            if f is None:
                civ.disconnect()
                self.connectError.emit(
                    f"Brak odpowiedzi radia na {port} "
                    f"(adres {addr:02X}h, {baud_i} bd)")
                return
            self._radio     = civ
            self._connected = True
            self._polling   = True
            self.connectedChanged.emit(True)
            self.statusChanged.emit(f"Polaczono  {port}")
            self._cur_freq = f
            self.freqChanged.emit(self._fmt_freq(f))
            self._update_band_from_freq(f)
            m = civ.read_mode()
            if m:
                self._cur_mode, self._cur_filt = m
                self.modeChanged.emit(self._cur_mode)
                self.filtChanged.emit(self._cur_filt)

        threading.Thread(target=_t, daemon=True).start()

    def _disconnect_internal(self):
        self._polling   = False
        self._connected = False
        radio, self._radio = self._radio, None
        if radio:
            self._ptt_off_safe(radio)
            radio.disconnect()
        if self._tx:
            self._tx = False
            self.txChanged.emit(False)

    @pyqtSlot()
    def disconnectRadio(self):
        self._polling = False
        threading.Thread(target=self._disconnect_internal, daemon=True).start()
        self.connectedChanged.emit(False)
        self.statusChanged.emit("Offline")

    @pyqtSlot(result="QVariantList")
    def getPorts(self):
        ports = list_ports()
        self.portsReady.emit(ports)
        return ports

    @pyqtSlot(result="QVariantList")
    def getAudioDevices(self):
        devs = _list_audio_devices()
        self.audioDevicesReady.emit(devs)
        return devs

    @pyqtSlot(str)
    def setBand(self, band):
        if band not in BAND_FREQS: return
        hz = BAND_FREQS[band]
        self._cur_freq = hz
        self.freqChanged.emit(self._fmt_freq(hz))
        self._cur_band = band
        self._max_pwr  = BAND_PWR.get(band, 100)
        self.bandChanged.emit(band)
        self.maxPwrChanged.emit(self._max_pwr)
        radio = self._radio
        if radio:
            threading.Thread(target=radio.set_freq, args=(hz,), daemon=True).start()

    @pyqtSlot(str)
    def setMode(self, mode):
        self._lock_mode()
        self._cur_mode = mode
        self.modeChanged.emit(mode)
        radio = self._radio
        if radio:
            threading.Thread(target=radio.set_mode,
                             args=(mode, self._cur_filt), daemon=True).start()

    @pyqtSlot(int)
    def setFilter(self, filt):
        self._lock_mode()
        self._cur_filt = filt
        self.filtChanged.emit(filt)
        radio = self._radio
        if radio:
            threading.Thread(target=radio.set_mode,
                             args=(self._cur_mode, filt), daemon=True).start()

    @pyqtSlot(int)
    def setAgc(self, speed):
        self._cur_agc = speed
        self.agcChanged.emit(speed)
        radio = self._radio
        if radio:
            threading.Thread(target=radio.set_agc, args=(speed,), daemon=True).start()

    def _send_level_now(self, sub, value):
        self._last_level_send[sub] = time.monotonic()
        radio = self._radio
        if radio:
            threading.Thread(target=radio.set_level,
                             args=(sub, value), daemon=True).start()

    def _schedule_level_flush(self, sub, delay):
        if sub in self._level_timers:
            return
        self._level_timers.add(sub)
        QTimer.singleShot(
            max(1, int(delay * 1000) + 5),
            lambda s=sub: self._flush_level(s))

    def _flush_level(self, sub):
        self._level_timers.discard(sub)
        value = self._pending_levels.pop(sub, None)
        if value is None:
            return
        elapsed = time.monotonic() - self._last_level_send.get(sub, 0)
        if elapsed < 0.08:
            self._pending_levels[sub] = value
            self._schedule_level_flush(sub, 0.08 - elapsed)
            return
        self._send_level_now(sub, value)

    @pyqtSlot(int, int)
    def setLevel(self, sub, value):
        value = max(0, min(255, int(value)))
        pct   = round(value / 255.0 * 100)
        self._level_edit_until[sub] = time.monotonic() + 0.7
        if sub == SUB_PWR and pct != self._set_pwr_pct:
            self._set_pwr_pct = pct
            self.setPwrPctChanged.emit(pct)
        elif sub == SUB_MIC and pct != self._mic_pct:
            self._mic_pct = pct
            self.micPctChanged.emit(pct)

        elapsed = time.monotonic() - self._last_level_send.get(sub, 0)
        if elapsed < 0.08:
            self._pending_levels[sub] = value
            self._schedule_level_flush(sub, 0.08 - elapsed)
            return
        self._pending_levels.pop(sub, None)
        self._send_level_now(sub, value)

    # ---------------- audio gain (amixer) ----------------
    def _audio_card_index(self):
        m = re.search(r"card\s+(\d+)", self._audio_device or "")
        return m.group(1) if m else "0"

    def _mixer_control(self, card, direction):
        key = (card, direction)
        if key not in self._mixer_cache:
            prefs = _MIXER_IN if direction == "capture" else _MIXER_OUT
            self._mixer_cache[key] = _find_mixer_control(card, prefs)
        return self._mixer_cache[key]

    def _amixer_set(self, direction, pct):
        card = self._audio_card_index()
        ctl = self._mixer_control(card, direction)
        if not ctl:
            self.statusChanged.emit(f"amixer: brak kontrolki {direction} na karcie {card}")
            return
        # FIX: tylko wskazany kierunek. Wczesniej 'sset Mic' ustawial tez
        # odsluch mikrofonu (playback) - na kartach CM108 to petla RX->TX.
        args = (["sset", ctl, "capture", f"{pct}%", "cap"] if direction == "capture"
                else ["sset", ctl, "playback", f"{pct}%", "unmute"])
        try:
            subprocess.run(["amixer", "-c", card] + args,
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=2)
        except Exception as e:
            print(f"amixer: {e}")

    @pyqtSlot(int)
    def setAudioInGain(self, pct):
        pct = max(0, min(100, pct))
        self._audio_in_gain = pct
        threading.Thread(target=self._amixer_set,
                         args=("capture", pct), daemon=True).start()

    @pyqtSlot(int)
    def setAudioOutGain(self, pct):
        pct = max(0, min(100, pct))
        self._audio_out_gain = pct
        threading.Thread(target=self._amixer_set,
                         args=("playback", pct), daemon=True).start()

    # ---------------- pamieci ----------------
    @pyqtSlot(str, str, str, str, str)
    def addMemory(self, name, freq, tone, dup, mode):
        hz = self._parse_freq_text(str(freq).strip())
        if hz is None:
            msg = f"Zla czestotliwosc: {freq}"
            self.memoryAddResult.emit(False, msg); self.statusChanged.emit(msg)
            return
        t = parse_tone(tone)
        if t is None:
            msg = f"Zly ton CTCSS: {tone} (np. 77.0, 88.5, 103.5)"
            self.memoryAddResult.emit(False, msg); self.statusChanged.emit(msg)
            return
        mode = str(mode).upper()
        if mode not in UI_MODES:
            mode = default_mode_for_freq(hz)
        dup = str(dup).upper()
        if dup not in DUPLEX:
            dup = "SIMPLEX"
        item = {
            "name": str(name).strip() or self._fmt_freq(hz),
            "freq": self._fmt_freq(hz),
            "mode": mode,
            "tone": t,
            "dup":  dup,
        }
        if item in self._memories:
            msg = "Taki kanal juz istnieje"
            self.memoryAddResult.emit(False, msg); self.statusChanged.emit(msg)
            return
        self._memories.append(item)
        self._save_memories()
        self.memoriesReady.emit(self._memories)
        self.memoryAddResult.emit(True, f"Dodano: {item['name']}")

    @pyqtSlot(int)
    def removeMemory(self, index):
        if 0 <= index < len(self._memories):
            del self._memories[index]
            self._save_memories()
            self.memoriesReady.emit(self._memories)

    @pyqtSlot(int)
    def recallMemory(self, index):
        """FIX: ustawia czestotliwosc, emisje, duplex i ton (wczesniej tylko f)."""
        if not (0 <= index < len(self._memories)):
            return
        mem = self._memories[index]
        hz = self._parse_freq_text(mem.get("freq", ""))
        if hz is None:
            self.statusChanged.emit("Zla czestotliwosc w pamieci")
            return
        mode = mem.get("mode") or default_mode_for_freq(hz)
        dup  = mem.get("dup", "SIMPLEX")
        tone = mem.get("tone", "")
        self._lock_mode(3.0)
        self._set_state(hz, mode)
        radio = self._radio
        if not radio:
            return
        filt = self._cur_filt

        def _w():
            radio.set_freq(hz)
            radio.set_mode(mode, filt)
            if mode == "FM":
                radio.set_duplex(dup)          # przesuniecie = ustawienie radia
                if tone:
                    radio.set_tone_freq(float(tone))
                    radio.set_tone(True)
                else:
                    radio.set_tone(False)
        threading.Thread(target=_w, daemon=True).start()

    # ---------------- funkcje ----------------
    @pyqtSlot(str, bool)
    def setToggle(self, name, on):
        radio = self._radio
        if not radio:
            self.statusChanged.emit("Brak polaczenia z radiem")
            if name == "COMP":
                self.compChanged.emit(self._comp)      # cofnij stan w UI
            return
        fns = {
            "PREAMP": radio.set_preamp,
            "NB":     radio.set_nb,
            "NR":     radio.set_nr,
            "COMP":   radio.set_comp,
        }
        fn = fns.get(name)
        if not fn:
            return
        if name == "COMP":
            self._comp = on
            self.compChanged.emit(on)

        def _w():
            if not fn(on) and name == "COMP":
                self._comp = not on
                self.compChanged.emit(self._comp)
                self.statusChanged.emit("COMP: radio nie potwierdzilo")
        threading.Thread(target=_w, daemon=True).start()

    @pyqtSlot(bool)
    def setScan(self, scanning):
        radio = self._radio
        if not radio:
            self.statusChanged.emit("Brak polaczenia z radiem")
            self.scanChanged.emit(self._scanning)
            return
        self._scanning = scanning
        self.scanChanged.emit(scanning)

        def _w():
            ok = radio.scan_start() if scanning else radio.scan_stop()
            if not ok:
                self._scanning = False
                self.scanChanged.emit(False)
                self.statusChanged.emit("SCAN: radio nie potwierdzilo")
        threading.Thread(target=_w, daemon=True).start()

    @pyqtSlot()
    def setVfoMem(self):
        """Przelacz VFO (0) / pamiec (1)."""
        radio = self._radio
        if not radio:
            self.statusChanged.emit("Brak polaczenia z radiem")
            return
        new = 1 - self._vfo_mem_mode

        def _w():
            if radio.set_vfo_mem(new):
                self._vfo_mem_mode = new
                self.vfoMemChanged.emit(new)
            else:
                self.statusChanged.emit("V/M: radio nie potwierdzilo")
        threading.Thread(target=_w, daemon=True).start()

    # ---------------- PTT: bezpieczne zwolnienie ----------------
    def _ptt_off_safe(self, radio):
        """Zwalnia PTT z ponawianiem i weryfikacja odczytem 1C 00."""
        for _ in range(4):
            try:
                ok = radio.set_ptt(False)
                st = radio.read_ptt()
                if st is False or (st is None and ok):
                    return True
            except Exception:
                pass
            time.sleep(0.2)
        self.statusChanged.emit("UWAGA: nie udalo sie zwolnic PTT!")
        return False

    # ---------------- APRS: direwolf KISS TCP + PTT przez CI-V ----------
    @pyqtSlot()
    def startAprsPolling(self):
        """Przestaw radio na 144.800 FM i sluchaj ramek z direwolfa."""
        if not self._aprs_active:
            self._aprs_active = True
            if self._radio and abs(self._cur_freq - APRS_FREQ) > 500:
                self._aprs_saved = (self._cur_freq, self._cur_mode, self._cur_filt)
            else:
                self._aprs_saved = None
        self._tune(APRS_FREQ, "FM", 1)

        # FIX: najwyzej jedna petla KISS (wczesniej szybkie wejscie/wyjscie
        # tworzylo dwie petle i zdublowane wiadomosci)
        if self._aprs_evt is not None and not self._aprs_evt.is_set():
            return
        evt = threading.Event()
        self._aprs_evt = evt
        threading.Thread(target=self._aprs_kiss_loop, args=(evt,), daemon=True).start()

    @pyqtSlot()
    def stopAprsPolling(self):
        if self._aprs_evt is not None:
            self._aprs_evt.set()
            self._aprs_evt = None
        if self._aprs_active:
            self._aprs_active = False
            saved, self._aprs_saved = self._aprs_saved, None
            if saved:                               # FIX: przywroc poprzednia f/emisje
                self._tune(saved[0], saved[1], saved[2])

    def _aprs_kiss_loop(self, evt):
        buf = bytearray()
        while not evt.is_set():
            s = None
            try:
                s = socket.create_connection((KISS_HOST, KISS_PORT), timeout=5)
                s.settimeout(1.0)
                self._kiss_sock = s
                self.statusChanged.emit("APRS: direwolf OK")
                buf.clear()
                while not evt.is_set():
                    try:
                        chunk = s.recv(1024)
                    except socket.timeout:
                        continue
                    if not chunk:
                        break
                    buf.extend(chunk)
                    for raw in _kiss_extract(buf):
                        self._aprs_handle_kiss(raw)
                if not evt.is_set():
                    evt.wait(2)
            except Exception:
                if not evt.is_set():
                    self.statusChanged.emit("APRS: brak direwolf (port 8001)")
                    evt.wait(5)
            finally:
                if s:
                    try: s.close()
                    except Exception: pass
                if self._kiss_sock is s:
                    self._kiss_sock = None

    def _aprs_add(self, callsign, comment, lat="", lng="", symbol="", mine=False):
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%S")
        with self._aprs_lock:
            self._aprs_messages.append({
                "callsign": callsign, "comment": comment,
                "lat": lat, "lng": lng, "time": now,
                "symbol": symbol, "mine": mine,
            })
            self._aprs_messages = self._aprs_messages[-100:]
            snapshot = list(self._aprs_messages)
        self.aprsMessagesReady.emit(snapshot)

    def _aprs_handle_kiss(self, raw):
        if len(raw) < 2 or (raw[0] & 0x0F) != 0x00:
            return
        parsed = _ax25_parse(_kiss_unescape(raw[1:]))
        if not parsed:
            return
        src, _dest, info = parsed
        d = _aprs_decode_info(info)
        kind = d["kind"]
        if kind == "msg":
            mine = d["to"].upper() == MYCALL.upper()
            self._aprs_add(src, f"→{d['to']}: {d['text']}", mine=mine, symbol="msg")
            if mine and d["msgid"]:
                self._aprs_send_ack(src, d["msgid"])
        elif kind in ("ack", "rej"):
            mine = d["to"].upper() == MYCALL.upper()
            self._aprs_add(src, f"{kind.upper()} {d['msgid']} →{d['to']}",
                           mine=mine, symbol=kind)
        elif kind == "pos":
            dist = _distance_km(APRS_LAT, APRS_LON, d["lat"], d["lon"])
            self._aprs_add(src, f"{dist:.0f} km · {d['text']}",
                           lat=f"{d['lat']:.4f}", lng=f"{d['lon']:.4f}", symbol="pos")
        else:
            self._aprs_add(src, d["text"])

    def _aprs_send_ack(self, to, msgid):
        """Automatyczne potwierdzenie wiadomosci do MYCALL (wymagane przez APRS).
        Kopie tej samej wiadomosci (digipeatery) potwierdzamy raz na 30 s."""
        key = (to.upper(), msgid)
        now = time.monotonic()
        self._aprs_acked = {k: t for k, t in self._aprs_acked.items() if now - t < 30}
        if key in self._aprs_acked:
            return
        self._aprs_acked[key] = now
        threading.Thread(target=self._aprs_tx,
                         args=(_aprs_ack_payload(to, msgid), f"ACK {msgid} →{to}"),
                         daemon=True).start()

    @pyqtSlot(str)
    def sendAprsMessage(self, text):
        """'SP2ABC: tekst' -> wiadomosc APRS do stacji; sam tekst -> beacon."""
        m = re.match(r"^\s*([A-Za-z0-9]{1,6}(?:-\d{1,2})?)\s*:\s*(.+)$", text)
        if m:
            to, body = m.group(1).upper(), m.group(2).strip()
            self._aprs_msgid = self._aprs_msgid % 99 + 1
            mid = str(self._aprs_msgid)
            payload = _aprs_msg_payload(to, body, mid)
            label = f"→{to}: {body} {{{mid}"
        else:
            payload = _aprs_position_payload(text)
            label = f"BEACON {text}"
        threading.Thread(target=self._aprs_tx, args=(payload, label), daemon=True).start()

    def _aprs_tx(self, payload, label):
        """Nadanie ramki: PTT przez CI-V, audio z direwolfa."""
        with self._tx_lock:                 # jedna transmisja naraz
            radio, sock = self._radio, self._kiss_sock
            reason = None
            if MYCALL in PLACEHOLDER_CALLS:
                reason = "ustaw swoj znak w config.json"
            elif not radio:
                reason = "brak polaczenia CI-V"
            elif not sock:
                reason = "brak polaczenia z direwolf"
            elif abs(self._cur_freq - APRS_FREQ) > 500 or self._cur_mode != "FM":
                # FIX: nie nadajemy, jesli ktos przestroil radio
                reason = "radio nie stoi na 144.800 FM"
            sent = False
            if reason is None:
                frame = _ax25_ui_frame(APRS_TOCALL, MYCALL, APRS_PATH, payload)
                try:
                    if not radio.set_ptt(True):
                        reason = "radio nie potwierdzilo PTT"
                    else:
                        time.sleep(PTT_LEAD)
                        sock.sendall(bytes([FEND, 0x00]) + _kiss_escape(frame) + bytes([FEND]))
                        airtime = (DW_TXDELAY
                                   + (len(frame) + 8) * 8 / 1200.0 * 1.25
                                   + DW_TXTAIL + 0.3)
                        time.sleep(airtime)
                        sent = True
                except Exception as ex:
                    reason = str(ex)
                finally:
                    self._ptt_off_safe(radio)   # zawsze, z ponawianiem
            if reason:
                self.statusChanged.emit(f"APRS TX: {reason}")
        self._aprs_add(MYCALL, f"[TX{'' if sent else ' FAIL'}] {label}",
                       symbol=">", mine=True)

    # ---------------- CW/RTTY: dekoder przez fldigi XML-RPC -------------
    @pyqtSlot(str)
    def startDecoder(self, mode):
        self._dec_mode = "CW" if mode == "CW" else "RTTY"
        if self._dec_evt is not None and not self._dec_evt.is_set():
            threading.Thread(target=self._dec_apply_mode, daemon=True).start()
            return
        evt = threading.Event()            # FIX: jedna petla dekodera naraz
        self._dec_evt = evt
        self._dec_running = True
        self.decoderRunning.emit(True)
        threading.Thread(target=self._decoder_loop, args=(evt,), daemon=True).start()

    @pyqtSlot()
    def stopDecoder(self):
        if self._dec_evt is not None:
            self._dec_evt.set()
            self._dec_evt = None
        self._dec_running = False
        self.decoderRunning.emit(False)

    @pyqtSlot()
    def clearDecoder(self):
        def _c():
            try:
                _fldigi().text.clear_rx()
            except Exception:
                pass
        threading.Thread(target=_c, daemon=True).start()

    def _find_wpm_method(self, srv):
        """Nazwa metody ustawiania WPM rozni sie miedzy wersjami fldigi -
        szukamy jej w fldigi.list zamiast zgadywac."""
        if self._dec_wpm_method is None:
            name = ""
            try:
                for m in srv.fldigi.list():
                    n = m.get("name", "") if isinstance(m, dict) else str(m)
                    if "wpm" in n.lower() and "set" in n.lower():
                        name = n
                        break
            except Exception:
                return None
            self._dec_wpm_method = name
        return self._dec_wpm_method or None

    @pyqtSlot(int)
    def setDecoderWpm(self, wpm):
        def _w():
            try:
                srv = _fldigi()
                name = self._find_wpm_method(srv)
                if not name:
                    self.decoderStatus.emit("fldigi: brak metody WPM (dekoder sledzi sam)")
                    return
                getattr(srv, name)(int(wpm))
                self.decoderStatus.emit(f"fldigi: {self._dec_mode} {int(wpm)} WPM")
            except Exception:
                self.decoderStatus.emit("fldigi: brak polaczenia (7362)")
        threading.Thread(target=_w, daemon=True).start()

    def _dec_apply_mode(self):
        try:
            srv = _fldigi()
            srv.modem.set_by_name(self._dec_mode)
            if self._dec_mode == "CW":
                srv.modem.set_carrier(700)
            self.decoderStatus.emit(f"fldigi: {self._dec_mode}")
            return True
        except Exception:
            self.decoderStatus.emit("fldigi: brak polaczenia (7362)")
            return False

    def _decoder_loop(self, evt):
        srv = _fldigi()
        ok = self._dec_apply_mode()
        while not evt.is_set():
            try:
                data = srv.rx.get_data()
                if isinstance(data, xmlrpc.client.Binary):
                    data = data.data
                if isinstance(data, bytes):
                    txt = data.decode("utf-8", errors="replace")
                else:
                    txt = str(data or "")
                if not ok:
                    ok = self._dec_apply_mode()
                if txt:
                    self._dec_last_rx = time.monotonic()
                    self.decoderText.emit(txt)
            except Exception:
                if ok:
                    self.decoderStatus.emit("fldigi: brak polaczenia (7362)")
                ok = False
                srv = _fldigi()
                evt.wait(2)
                continue
            evt.wait(0.3)

    # ---------------- shutdown ----------------
    def shutdown(self):
        self._polling = False
        if self._aprs_evt is not None:
            self._aprs_evt.set()
        if self._dec_evt is not None:
            self._dec_evt.set()
        self._dec_running = False
        sock = self._kiss_sock
        if sock:
            try: sock.close()
            except Exception: pass
        radio, self._radio = self._radio, None
        if radio:
            self._ptt_off_safe(radio)
            try: radio.disconnect()
            except Exception: pass
