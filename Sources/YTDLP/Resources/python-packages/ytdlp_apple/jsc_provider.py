"""yt-dlp JS challenge provider backed by Apple's JavaScriptCore.

Reuses yt-dlp's EJS solver (the same scripts its Deno/Node/Bun providers run); only the
"run this script, return what it printed" step goes to JavaScriptCore instead of a process.
"""
from __future__ import annotations

from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProvider,
    JsChallengeProviderError,
    JsChallengeRequest,
    register_preference,
    register_provider,
)

from . import __version__, eval_js


@register_provider
class JavaScriptCoreJCP(EJSBaseJCP):
    PROVIDER_NAME = "javascriptcore"
    PROVIDER_VERSION = __version__
    JS_RUNTIME_NAME = "javascriptcore"
    BUG_REPORT_LOCATION = "https://github.com/devileya/ytdlp-apple/issues"

    def is_available(self, /) -> bool:
        from . import _js_eval

        return _js_eval is not None and self._available

    def _run_js_runtime(self, stdin: str, /) -> str:
        try:
            return eval_js(stdin)
        except Exception as e:
            raise JsChallengeProviderError(f"JavaScriptCore: {e}") from e


@register_preference(JavaScriptCoreJCP)
def preference(provider: JsChallengeProvider, requests: list[JsChallengeRequest]) -> int:
    return 1000  # in-process: always faster than starting a runtime
