"""Launch piper.http_server with a POST / alias and a bounded onnxruntime thread pool.

Two adjustments to upstream, both applied by monkeypatch so the vendored
piper package stays untouched and upgradable:

1. Upstream serves synthesis at /synthesize and reserves GET / for its HTML
   test page. The LAN consumer posts JSON to /, so the same view function is
   registered against POST / just before the app starts serving. That view
   returns raw bytes, which Flask labels text/html, so the wrapper relabels a
   bytes body as audio/wav on both routes.

2. onnxruntime sizes its intra-op pool from the host core count. The voice
   session is bounded via SessionOptions, but the Arabic tashkeel diacritizer
   builds its session with no options at all and would otherwise take every
   core and then stall against the service CPUQuota. Patching InferenceSession
   itself catches every call site regardless of how it was imported.
   PIPER_NUM_THREADS caps it; 0 restores upstream behaviour.

Usage: python piper_http_shim.py --host 0.0.0.0 --port 9091 -m <voice> [...]
"""

import functools
import os
import sys

import flask
import onnxruntime

from piper.http_server import main

_num_threads = int(os.environ.get("PIPER_NUM_THREADS", "2"))

_original_session_init = onnxruntime.InferenceSession.__init__


def _bounded_session_init(self, *args, **kwargs):
    if _num_threads > 0:
        options = kwargs.get("sess_options")
        if options is None and len(args) >= 2:
            options = args[1]
        if options is None:
            options = onnxruntime.SessionOptions()
            kwargs["sess_options"] = options
        options.intra_op_num_threads = _num_threads
        options.inter_op_num_threads = 1
    return _original_session_init(self, *args, **kwargs)


onnxruntime.InferenceSession.__init__ = _bounded_session_init

_original_run = flask.Flask.run


def _run_with_root_alias(self, *args, **kwargs):
    synthesize = self.view_functions.get("app_synthesize")
    if synthesize is not None:

        @functools.wraps(synthesize)
        def wav_view(*view_args, **view_kwargs):
            result = synthesize(*view_args, **view_kwargs)
            if isinstance(result, (bytes, bytearray)):
                return flask.Response(result, mimetype="audio/wav")
            return result

        self.view_functions["app_synthesize"] = wav_view
        if "root_synthesize" not in self.view_functions:
            self.add_url_rule("/", "root_synthesize", wav_view, methods=["POST"])
    return _original_run(self, *args, **kwargs)


flask.Flask.run = _run_with_root_alias

if __name__ == "__main__":
    sys.exit(main())
