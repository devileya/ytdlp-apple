"""In-process yt-dlp for apps on Apple platforms.

iOS apps can't start subprocesses, so yt-dlp runs inside the app's embedded Python, and the
YouTube "n/sig" JavaScript challenges are solved by the system's JavaScriptCore (passed in from
Swift as a C function pointer) instead of a Deno/Node binary.

Called from C (Sources/YTDLPCore) as `ytdlp_apple.<function>(arg: str, callback: int, context: int) -> str`.
"""
from __future__ import annotations

import ctypes
import io
import json
import re
import sys
import threading
import traceback

__version__ = "0.1.0"

_libc = ctypes.CDLL(None)
_libc.free.argtypes = [ctypes.c_void_p]
_libc.free.restype = None

# char *eval(const char *script): returns console output, malloc'd (freed here).
_EVAL_PROTO = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_char_p)
# void line(void *context, const char *line, int is_stderr)
_LINE_PROTO = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int)

_js_eval = None
_runs: dict[str, int] = {}  # run id -> thread ident, for cancel()
_cancelled: set[str] = set()
_runs_lock = threading.Lock()


def set_js_eval(address: str, _callback: int = 0, _context: int = 0) -> str:
    """Registers the JavaScriptCore evaluator (address of a C function, as a decimal string)."""
    global _js_eval
    _js_eval = _EVAL_PROTO(int(address)) if int(address) else None
    from . import jsc_provider  # noqa: F401  (registers the provider with yt-dlp)
    return "ok"


def eval_js(script: str) -> str:
    if _js_eval is None:
        raise RuntimeError("no JavaScript engine registered")
    ptr = _js_eval(script.encode("utf-8"))
    if not ptr:
        raise RuntimeError("JavaScript evaluation failed")
    try:
        return ctypes.string_at(ptr).decode("utf-8", "replace")
    finally:
        _libc.free(ptr)


class _ThreadStream(io.TextIOBase):
    """sys.stdout / sys.stderr that sends each run's output to that run (runs overlap on threads)."""

    def __init__(self, name: str, fallback):
        self._name = name
        self._fallback = fallback
        self._local = threading.local()

    @property
    def sink(self):
        return getattr(self._local, "sink", None)

    @sink.setter
    def sink(self, value):
        self._local.sink = value

    def write(self, s: str) -> int:
        sink = self.sink
        if sink is None:
            return self._fallback.write(s) if self._fallback else len(s)
        sink(self._name, s)
        return len(s)

    def flush(self):
        if self.sink is None and self._fallback:
            self._fallback.flush()

    def isatty(self) -> bool:
        return False

    def writable(self) -> bool:
        return True

    @property
    def encoding(self) -> str:
        return "utf-8"


def _streams() -> tuple[_ThreadStream, _ThreadStream]:
    if not isinstance(sys.stdout, _ThreadStream):
        sys.stdout = _ThreadStream("stdout", sys.__stdout__)
    if not isinstance(sys.stderr, _ThreadStream):
        sys.stderr = _ThreadStream("stderr", sys.__stderr__)
    return sys.stdout, sys.stderr


def run(request: str, callback: int = 0, context: int = 0) -> str:
    """Runs yt-dlp with command-line arguments, like the `yt-dlp` program.

    request: JSON `{"args": [...], "id": "optional run id for cancel()"}`.
    callback: optional C line callback, called for every output line as it's written
    (download progress). Returns JSON `{"code", "stdout", "stderr"}`.
    """
    req = json.loads(request)
    args = list(req.get("args", []))
    run_id = req.get("id")
    line = _LINE_PROTO(callback) if callback else None
    out: list[str] = []
    err: list[str] = []
    partial = {"stdout": "", "stderr": ""}

    def emit(name: str, text: str):
        if line and text:
            line(context, text.encode("utf-8", "replace"), 1 if name == "stderr" else 0)

    def sink(name: str, s: str):
        (out if name == "stdout" else err).append(s)
        if line:
            *lines, partial[name] = re.split(r"\r\n|\r|\n", partial[name] + s)
            for text in lines:
                emit(name, text)

    stdout, stderr = _streams()
    stdout.sink = stderr.sink = sink
    if run_id:
        with _runs_lock:
            _runs[run_id] = threading.get_ident()
    code = 0
    try:
        import yt_dlp

        yt_dlp.main(args)
    except SystemExit as e:
        if e.code is None:
            code = 0
        elif isinstance(e.code, int):
            code = e.code
        else:
            err.append(f"{e.code}\n")
            code = 1
    except KeyboardInterrupt:
        err.append("ERROR: cancelled\n")
        code = 130
    except BaseException:  # noqa: BLE001  (report everything; never kill the host app)
        err.append(traceback.format_exc())
        code = 1
    finally:
        stdout.sink = stderr.sink = None
        if run_id:
            with _runs_lock:
                _runs.pop(run_id, None)
                # yt-dlp turns the interrupt into "ERROR: Interrupted by user" + exit 1.
                if run_id in _cancelled:
                    _cancelled.discard(run_id)
                    code = 130
        for name, rest in partial.items():
            emit(name, rest)
    return json.dumps({"code": code, "stdout": "".join(out), "stderr": "".join(err)})


def cancel(run_id: str, _callback: int = 0, _context: int = 0) -> str:
    """Stops a run started with that id (raised as KeyboardInterrupt in its thread)."""
    with _runs_lock:
        ident = _runs.get(run_id)
        if ident is not None:
            _cancelled.add(run_id)
    if ident is None:
        return "not running"
    ctypes.pythonapi.PyThreadState_SetAsyncExc(ctypes.c_ulong(ident), ctypes.py_object(KeyboardInterrupt))
    return "ok"


def version(_arg: str = "", _callback: int = 0, _context: int = 0) -> str:
    import yt_dlp.version

    return json.dumps({"ytdlp_apple": __version__, "yt_dlp": yt_dlp.version.__version__, "python": sys.version.split()[0]})
