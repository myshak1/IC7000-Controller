import sys, os, subprocess, atexit
from PyQt6.QtGui     import QGuiApplication
from PyQt6.QtQml     import QQmlApplicationEngine
from PyQt6.QtCore    import QUrl
from backend         import RadioBackend
from config          import CONFIG

DIREWOLF_CONF = os.path.expanduser(CONFIG["direwolf_conf"])
DIREWOLF_LOG  = os.path.expanduser(CONFIG["direwolf_log"])

_dw_log = None

def start_direwolf():
    """Uruchom direwolf w tle, jesli nie dziala. Zwraca Popen albo None."""
    global _dw_log
    try:
        if subprocess.run(["pgrep", "-x", "direwolf"],
                          stdout=subprocess.DEVNULL).returncode == 0:
            print("direwolf: juz dziala - pomijam autostart")
            return None
    except Exception:
        pass
    if not os.path.exists(DIREWOLF_CONF):
        print(f"direwolf: brak {DIREWOLF_CONF} - pomijam autostart")
        return None
    try:
        # FIX: wyjscie do pliku zamiast DEVNULL - inaczej nie widac bledow
        # (zajeta karta audio, zly ADEVICE, zajety port 8001...)
        _dw_log = open(DIREWOLF_LOG, "w", encoding="utf-8", errors="replace")
        proc = subprocess.Popen(
            ["direwolf", "-c", DIREWOLF_CONF, "-t", "0"],
            stdout=_dw_log,
            stderr=subprocess.STDOUT,
        )
        try:
            proc.wait(timeout=1.0)          # natychmiastowy blad startu?
            print(f"direwolf: zakonczyl sie od razu (kod {proc.returncode}) - zobacz {DIREWOLF_LOG}")
            return None
        except subprocess.TimeoutExpired:
            pass
        print(f"direwolf: uruchomiony (pid {proc.pid}), log: {DIREWOLF_LOG}")
        return proc
    except FileNotFoundError:
        print("direwolf: nie znaleziono programu w PATH")
        return None

def stop_direwolf(proc):
    global _dw_log
    if proc and proc.poll() is None:
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except Exception:
            try: proc.kill()
            except Exception: pass
    if _dw_log:
        try: _dw_log.close()
        except Exception: pass
        _dw_log = None

def main():
    if sys.platform.startswith("linux"):
        os.environ.setdefault("QT_QPA_PLATFORM", "xcb")

    dw = start_direwolf()
    atexit.register(stop_direwolf, dw)

    app    = QGuiApplication(sys.argv)
    engine = QQmlApplicationEngine()
    backend = RadioBackend()
    engine.rootContext().setContextProperty("backend", backend)
    engine.rootContext().setContextProperty("appConfig", {
        "callsign": CONFIG["callsign"], "locator": CONFIG["locator"]})
    qml_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "main.qml")
    engine.load(QUrl.fromLocalFile(qml_path))
    if not engine.rootObjects():
        backend.shutdown()
        stop_direwolf(dw)
        sys.exit(-1)
    engine.rootObjects()[0].showFullScreen()
    ret = app.exec()
    backend.shutdown()          # zwalnia PTT i zamyka port CI-V
    stop_direwolf(dw)
    sys.exit(ret)

if __name__ == "__main__":
    main()
