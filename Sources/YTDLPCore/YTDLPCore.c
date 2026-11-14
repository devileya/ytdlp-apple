// Embeds CPython (BeeWare's Python.xcframework) and forwards calls to the `ytdlp_apple` module.
#include "YTDLPCore.h"

#include <Python/Python.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t start_lock = PTHREAD_MUTEX_INITIALIZER;
static int started = 0;

static char *dup_or_null(const char *s) { return s ? strdup(s) : NULL; }

/// The current Python exception as text (caller holds the GIL).
static char *python_error(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (!exc) return strdup("unknown Python error");
    PyObject *text = PyObject_Str(exc);
    const char *s = text ? PyUnicode_AsUTF8(text) : NULL;
    char *out = strdup(s ? s : "unprintable Python error");
    Py_XDECREF(text);
    Py_DECREF(exc);
    PyErr_Clear();
    return out;
}

static int fail_status(PyStatus status, PyConfig *config, char **error) {
    if (error) *error = dup_or_null(status.err_msg ? status.err_msg : "Python failed to start");
    if (config) PyConfig_Clear(config);
    return -1;
}

int ytdlp_core_start(const char *home, const char *packages, char **error) {
    pthread_mutex_lock(&start_lock);
    if (started) {
        pthread_mutex_unlock(&start_lock);
        return 0;
    }

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        pthread_mutex_unlock(&start_lock);
        return fail_status(status, NULL, error);
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;          // the app bundle is read-only
    config.install_signal_handlers = 0; // the host app owns signals
    config.buffered_stdio = 0;
    status = PyConfig_SetBytesString(&config, &config.home, home);
    if (PyStatus_Exception(status)) { pthread_mutex_unlock(&start_lock); return fail_status(status, &config, error); }
    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) { pthread_mutex_unlock(&start_lock); return fail_status(status, &config, error); }
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        pthread_mutex_unlock(&start_lock);
        return fail_status(status, NULL, error);
    }

    // Our packages go first on the path (the standard library paths come from `home`).
    PyObject *path = PySys_GetObject("path");
    PyObject *entry = PyUnicode_FromString(packages);
    if (!path || !entry || PyList_Insert(path, 0, entry) != 0) {
        Py_XDECREF(entry);
        if (error) *error = python_error();
        PyEval_SaveThread();
        pthread_mutex_unlock(&start_lock);
        return -1;
    }
    Py_DECREF(entry);

    // Fail early (and clearly) if the packages folder is wrong.
    PyObject *module = PyImport_ImportModule("ytdlp_apple");
    if (!module) {
        if (error) *error = python_error();
        PyEval_SaveThread();
        pthread_mutex_unlock(&start_lock);
        return -1;
    }
    Py_DECREF(module);

    // Release the GIL: calls come from any thread via PyGILState_Ensure.
    PyEval_SaveThread();
    started = 1;
    pthread_mutex_unlock(&start_lock);
    return 0;
}

char *ytdlp_core_call(const char *function, const char *argument, ytdlp_line_fn line, void *context, char **error) {
    if (!started) {
        if (error) *error = strdup("ytdlp_core_start wasn't called");
        return NULL;
    }
    PyGILState_STATE gil = PyGILState_Ensure();
    char *result = NULL;
    PyObject *module = PyImport_ImportModule("ytdlp_apple");
    PyObject *fn = module ? PyObject_GetAttrString(module, function) : NULL;
    PyObject *ret = fn ? PyObject_CallFunction(fn, "sKK", argument ? argument : "",
                                              (unsigned long long)(uintptr_t)line,
                                              (unsigned long long)(uintptr_t)context)
                       : NULL;
    if (ret && PyUnicode_Check(ret)) {
        const char *s = PyUnicode_AsUTF8(ret);
        result = s ? strdup(s) : NULL;
    }
    if (!result && error) *error = PyErr_Occurred() ? python_error() : strdup("yt-dlp returned nothing");
    Py_XDECREF(ret);
    Py_XDECREF(fn);
    Py_XDECREF(module);
    PyGILState_Release(gil);
    return result;
}

void ytdlp_core_free(char *p) { free(p); }
