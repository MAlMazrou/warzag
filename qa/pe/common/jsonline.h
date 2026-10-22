/*
 * jsonline.h: build one flat JSON object and print it as a single line.
 *
 * Warzag's PE test programs report their result as exactly one JSON line on stdout (and optionally in a file), so
 * it can be parsed whatever Wine writes to stderr. Header-only, so each program stays one translation unit; static
 * inline, so a program that does not use a function still builds without warnings. bridge/steamprobe uses it too
 * (built by runtime/n/build.sh): keep the interface stable.
 */
#ifndef WZ_JSONLINE_H
#define WZ_JSONLINE_H

#include <fcntl.h>
#include <io.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>

/* Longest string value kept, in UTF-8 bytes. Even escaped six-fold, a handful of these fit in the buffer, so the
   line is always complete, valid JSON. */
#define JL_MAX_STRING 512

struct jsonline
{
    char buf[16384];
    size_t len;
    int fields;
};

static inline void jl_append(struct jsonline *j, const char *s, size_t n)
{
    /* Always leave room for the closing "}\n" that jl_print adds. */
    size_t room = sizeof(j->buf) - sizeof("}\n") - j->len;

    if (n > room) n = room;
    memcpy(j->buf + j->len, s, n);
    j->len += n;
}

static inline void jl_cat(struct jsonline *j, const char *s)
{
    jl_append(j, s, strlen(s));
}

static inline void jl_key(struct jsonline *j, const char *key)
{
    jl_cat(j, j->fields++ ? ",\"" : "{\"");
    jl_cat(j, key);
    jl_cat(j, "\":");
}

static inline void jl_bool(struct jsonline *j, const char *key, int value)
{
    jl_key(j, key);
    jl_cat(j, value ? "true" : "false");
}

static inline void jl_int(struct jsonline *j, const char *key, long long value)
{
    char tmp[32];

    snprintf(tmp, sizeof(tmp), "%lld", value);
    jl_key(j, key);
    jl_cat(j, tmp);
}

/* Milliseconds and other measurements: three decimals is finer than any timer we read. JSON has no NaN or
   infinity, so those become null. */
static inline void jl_num(struct jsonline *j, const char *key, double value)
{
    char tmp[64];

    if (isfinite(value)) snprintf(tmp, sizeof(tmp), "%.3f", value);
    else strcpy(tmp, "null");
    jl_key(j, key);
    jl_cat(j, tmp);
}

/* PCI IDs and HRESULTs as "0x"-prefixed upper-case hex strings, e.g. "0x10DE" or "0x887A0004". */
static inline void jl_hex(struct jsonline *j, const char *key, unsigned long value, int digits)
{
    char tmp[32];

    snprintf(tmp, sizeof(tmp), "\"0x%0*lX\"", digits, value);
    jl_key(j, key);
    jl_cat(j, tmp);
}

static inline void jl_str(struct jsonline *j, const char *key, const char *utf8)
{
    size_t i, n = strlen(utf8);
    char esc[8];

    /* Cut over-long values on a UTF-8 character boundary. */
    if (n > JL_MAX_STRING)
    {
        n = JL_MAX_STRING;
        while (n > 0 && ((unsigned char)utf8[n] & 0xC0) == 0x80) n--;
    }
    jl_key(j, key);
    jl_cat(j, "\"");
    for (i = 0; i < n; i++)
    {
        unsigned char c = (unsigned char)utf8[i];

        if (c == '"' || c == '\\')
        {
            esc[0] = '\\';
            esc[1] = (char)c;
            jl_append(j, esc, 2);
        }
        else if (c < 0x20)
        {
            snprintf(esc, sizeof(esc), "\\u%04x", c);
            jl_cat(j, esc);
        }
        else jl_append(j, &utf8[i], 1);
    }
    jl_cat(j, "\"");
}

static inline void jl_wstr(struct jsonline *j, const char *key, const WCHAR *s)
{
    char utf8[JL_MAX_STRING * 4 + 1];
    size_t n = wcslen(s);
    int len;

    if (n > JL_MAX_STRING) n = JL_MAX_STRING;
    len = WideCharToMultiByte(CP_UTF8, 0, s, (int)n, utf8, (int)sizeof(utf8) - 1, NULL, NULL);
    utf8[len > 0 ? len : 0] = 0;
    jl_str(j, key, utf8);
}

/* Opens (truncating) the --out file early, so a bad path fails before the test does any work. */
static inline HANDLE jl_open_file(const WCHAR *path)
{
    return CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
}

/* Closes the object and prints the line to stdout and, if given, to an already opened file. */
static inline void jl_print(struct jsonline *j, HANDLE also)
{
    const char *end = j->fields ? "}\n" : "{}\n";
    DWORD written;

    /* jl_append always leaves room for this. */
    memcpy(j->buf + j->len, end, strlen(end));
    j->len += strlen(end);

    /* Binary mode: a plain "\n" line ending, whatever console or pipe is on the other side. */
    _setmode(_fileno(stdout), _O_BINARY);
    fwrite(j->buf, 1, j->len, stdout);
    fflush(stdout);
    if (also != INVALID_HANDLE_VALUE) WriteFile(also, j->buf, (DWORD)j->len, &written, NULL);
}

#endif /* WZ_JSONLINE_H */
