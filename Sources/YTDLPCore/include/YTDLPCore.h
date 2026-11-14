#ifndef YTDLP_CORE_H
#define YTDLP_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Called for every line yt-dlp writes while a call runs (e.g. download progress).
typedef void (*ytdlp_line_fn)(void *context, const char *line, int is_stderr);

/// Starts the embedded Python once. `home`: Python home (standard library); `packages`: folder
/// with yt_dlp, yt_dlp_ejs, certifi and ytdlp_apple. Returns 0, or -1 with `*error` set (free it).
int ytdlp_core_start(const char *home, const char *packages, char **error);

/// Calls `ytdlp_apple.<function>(argument, line, context)` and returns its string result
/// (malloc'd, free with ytdlp_core_free), or NULL with `*error` set. Safe from any thread.
char *ytdlp_core_call(const char *function, const char *argument, ytdlp_line_fn line, void *context, char **error);

void ytdlp_core_free(char *p);

#ifdef __cplusplus
}
#endif
#endif
