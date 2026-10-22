/*
 * wz-winhttp-probe: can Wine's WinHTTP fetch Digital Extremes' content index over TLS?
 *
 * Sends exactly one GET, the request DE's launcher starts every update with:
 *   https://origin.warframe.com/origin/<8 random upper-case hex digits>/index.txt.lzma
 * The hex part only defeats caches. Never HEAD: origin answers HEAD with 503. The body is read with the usual
 * WinHttpQueryDataAvailable/WinHttpReadData loop and checked for an LZMA-alone header. Prints exactly one JSON line
 * on stdout (and to --out).
 *
 *   wz-winhttp-probe.exe [--url <http(s) URL>] [--out <file>]
 *
 * Exit status: 0 passed; 1 failed (see "stage"); 2 bad arguments.
 */
#define WIN32_LEAN_AND_MEAN
#define _CRT_RAND_S
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <windows.h>
#include <winhttp.h>

#include "../common/jsonline.h"

#define USER_AGENT L"Warzag-winhttp-probe/1.0"

static const char usage[] =
    "usage: wz-winhttp-probe.exe [--url <http(s) URL>] [--out <file>]\n"
    "  --url <URL>    fetch this instead of https://origin.warframe.com/origin/<8 hex>/index.txt.lzma\n"
    "  --out <file>   also write the JSON line to <file>, a Windows path such as Z:\\tmp\\probe.json\n";

struct probe
{
    WCHAR url[2048];
    BOOL expect_lzma;  /* the URL names an .lzma file, so the body must look like one */
    const char *stage; /* first failed stage; NULL when everything passed */
    DWORD error;       /* Win32/WinHTTP error code of the call that failed, if any */
    DWORD status;
    unsigned long long bytes;
    BOOL have_length;
    unsigned long long content_length;
    WCHAR etag[256];
    WCHAR location[2048];
    unsigned char head[13];
    BOOL lzma_header;
    double elapsed_ms;
};

/* Records the first failure only: later stages fail because of it, not for reasons of their own. */
static void fail(struct probe *p, const char *stage, DWORD error)
{
    if (p->stage) return;
    p->stage = stage;
    p->error = error;
}

static const char *error_name(DWORD error)
{
#define NAME(e) case e: return #e
    switch (error)
    {
    NAME(ERROR_WINHTTP_TIMEOUT);
    NAME(ERROR_WINHTTP_INTERNAL_ERROR);
    NAME(ERROR_WINHTTP_INVALID_URL);
    NAME(ERROR_WINHTTP_UNRECOGNIZED_SCHEME);
    NAME(ERROR_WINHTTP_NAME_NOT_RESOLVED);
    NAME(ERROR_WINHTTP_OPERATION_CANCELLED);
    NAME(ERROR_WINHTTP_CANNOT_CONNECT);
    NAME(ERROR_WINHTTP_CONNECTION_ERROR);
    NAME(ERROR_WINHTTP_INVALID_SERVER_RESPONSE);
    NAME(ERROR_WINHTTP_SECURE_FAILURE);
    NAME(ERROR_WINHTTP_SECURE_CHANNEL_ERROR);
    NAME(ERROR_WINHTTP_SECURE_INVALID_CA);
    NAME(ERROR_WINHTTP_SECURE_INVALID_CERT);
    NAME(ERROR_WINHTTP_SECURE_CERT_DATE_INVALID);
    NAME(ERROR_WINHTTP_SECURE_CERT_CN_INVALID);
    NAME(ERROR_WINHTTP_SECURE_CERT_REV_FAILED);
    NAME(ERROR_WINHTTP_SECURE_CERT_REVOKED);
    /* Wine's WinHTTP passes some socket errors through unchanged, e.g. a stalled body fails with WSAETIMEDOUT. */
    NAME(WSAETIMEDOUT);
    NAME(WSAECONNRESET);
    NAME(WSAECONNABORTED);
    NAME(WSAECONNREFUSED);
    }
#undef NAME
    return NULL;
}

/*
 * An LZMA-alone (.lzma) stream starts with 13 bytes: the lc/lp/pb properties byte (0x5D for the usual lc=3 lp=0
 * pb=2), a little-endian 32-bit dictionary size and a 64-bit uncompressed size (all ones when unknown). Plausible
 * means a dictionary between 4 KiB and 1.5 GiB, the range LZMA encoders write, and a size under 1 TiB.
 */
static BOOL is_lzma_alone(const unsigned char *h, unsigned long long bytes)
{
    unsigned long long size = 0;
    unsigned int dict;
    int i;

    if (bytes < 13 || h[0] != 0x5D) return FALSE;
    dict = (unsigned int)h[1] | (unsigned int)h[2] << 8 | (unsigned int)h[3] << 16 | (unsigned int)h[4] << 24;
    for (i = 12; i >= 5; i--) size = size << 8 | h[i];
    return dict >= 1u << 12 && dict <= 3u << 29 && (size == ~0ull || size < 1ull << 40);
}

/* Whether the URL's path names an .lzma file, ignoring any query or fragment. */
static BOOL names_lzma_file(const WCHAR *url)
{
    size_t n = wcscspn(url, L"?#");

    return n >= 5 && !_wcsnicmp(url + n - 5, L".lzma", 5);
}

static void default_url(WCHAR *url, size_t count)
{
    unsigned int r;

    /* DE's launcher builds this path from "/origin/%08X/index.txt.lzma"; the number only defeats caches. */
    if (rand_s(&r)) r = GetTickCount() ^ (GetCurrentProcessId() << 16);
    swprintf(url, count, L"https://origin.warframe.com/origin/%08X/index.txt.lzma", r);
}

/* Copies a response header into buf (count WCHARs); leaves it empty when the header is absent or too long. */
static void query_header(HINTERNET request, DWORD info, WCHAR *buf, DWORD count)
{
    DWORD size = count * sizeof(WCHAR);

    if (!WinHttpQueryHeaders(request, info, WINHTTP_HEADER_NAME_BY_INDEX, buf, &size, WINHTTP_NO_HEADER_INDEX))
        buf[0] = 0;
}

static void read_response(struct probe *p, HINTERNET request)
{
    static char buf[65536];
    DWORD size = sizeof(p->status);
    WCHAR length[32];

    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &p->status, &size, WINHTTP_NO_HEADER_INDEX))
    {
        fail(p, "receive", GetLastError());
        return;
    }
    query_header(request, WINHTTP_QUERY_CONTENT_LENGTH, length, ARRAYSIZE(length));
    if (length[0])
    {
        p->have_length = TRUE;
        p->content_length = _wcstoui64(length, NULL, 10);
    }
    query_header(request, WINHTTP_QUERY_ETAG, p->etag, ARRAYSIZE(p->etag));
    query_header(request, WINHTTP_QUERY_LOCATION, p->location, ARRAYSIZE(p->location));

    for (;;)
    {
        DWORD avail = 0, got = 0;
        size_t keep;

        if (!WinHttpQueryDataAvailable(request, &avail))
        {
            fail(p, "read", GetLastError());
            return;
        }
        if (!avail) break;
        if (avail > sizeof(buf)) avail = sizeof(buf);
        if (!WinHttpReadData(request, buf, avail, &got))
        {
            fail(p, "read", GetLastError());
            return;
        }
        if (!got) break;
        if (p->bytes < sizeof(p->head))
        {
            keep = sizeof(p->head) - (size_t)p->bytes;
            memcpy(p->head + p->bytes, buf, keep < got ? keep : got);
        }
        p->bytes += got;
    }
}

static void run(struct probe *p)
{
    HINTERNET session = NULL, connection = NULL, request = NULL;
    DWORD no_redirects = WINHTTP_DISABLE_REDIRECTS;
    LARGE_INTEGER freq, start, end;
    URL_COMPONENTS uc = {0};
    WCHAR host[256];

    /* With NULL pointers and -1 lengths WinHttpCrackUrl points into p->url; the path runs to its end, query included. */
    uc.dwStructSize = sizeof(uc);
    uc.dwHostNameLength = uc.dwUrlPathLength = (DWORD)-1;
    if (!WinHttpCrackUrl(p->url, 0, 0, &uc))
    {
        fail(p, "url", GetLastError());
        return;
    }
    if ((uc.nScheme != INTERNET_SCHEME_HTTPS && uc.nScheme != INTERNET_SCHEME_HTTP) || !uc.dwHostNameLength
        || uc.dwHostNameLength >= ARRAYSIZE(host))
    {
        fail(p, "url", ERROR_WINHTTP_INVALID_URL);
        return;
    }
    lstrcpynW(host, uc.lpszHostName, uc.dwHostNameLength + 1);

    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    if (!(session = WinHttpOpen(USER_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
                                WINHTTP_NO_PROXY_BYPASS, 0)))
        fail(p, "open", GetLastError());
    /* Bounded, so a stuck connection fails the probe instead of hanging it. */
    else if (!WinHttpSetTimeouts(session, 15000, 15000, 30000, 30000))
        fail(p, "open", GetLastError());
    else if (!(connection = WinHttpConnect(session, host, uc.nPort, 0)))
        fail(p, "connect", GetLastError());
    else if (!(request = WinHttpOpenRequest(connection, L"GET", uc.dwUrlPathLength ? uc.lpszUrlPath : L"/", NULL,
                                            WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                            uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)))
        fail(p, "request", GetLastError());
    /* Exactly one request per run: report a redirect instead of following it. */
    else if (!WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &no_redirects, sizeof(no_redirects)))
        fail(p, "request", GetLastError());
    else if (!WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0))
        fail(p, "send", GetLastError());
    else if (!WinHttpReceiveResponse(request, NULL))
        fail(p, "receive", GetLastError());
    else
        read_response(p, request);
    QueryPerformanceCounter(&end);
    p->elapsed_ms = (double)(end.QuadPart - start.QuadPart) * 1000.0 / (double)freq.QuadPart;

    if (request) WinHttpCloseHandle(request);
    if (connection) WinHttpCloseHandle(connection);
    if (session) WinHttpCloseHandle(session);
}

/* A response only counts when it is complete and is what was asked for. */
static void evaluate(struct probe *p)
{
    p->lzma_header = is_lzma_alone(p->head, p->bytes);
    if (p->stage) return;
    if (p->status < 200 || p->status > 299) fail(p, "http_status", 0);
    else if (p->have_length && p->bytes != p->content_length) fail(p, "truncated", 0);
    else if (p->expect_lzma && !p->lzma_header) fail(p, "not_lzma", 0);
}

static void print_result(const struct probe *p, HANDLE out)
{
    struct jsonline j = {0};
    const char *name;

    jl_bool(&j, "ok", !p->stage);
    if (p->stage) jl_str(&j, "stage", p->stage);
    if (p->error)
    {
        jl_int(&j, "error", p->error);
        if ((name = error_name(p->error))) jl_str(&j, "error_name", name);
    }
    jl_int(&j, "status", p->status);
    jl_int(&j, "bytes", (long long)p->bytes);
    jl_bool(&j, "lzma_header", p->lzma_header);
    jl_wstr(&j, "url", p->url);
    if (p->have_length) jl_int(&j, "content_length", (long long)p->content_length);
    if (p->etag[0]) jl_wstr(&j, "etag", p->etag);
    if (p->location[0]) jl_wstr(&j, "location", p->location);
    jl_num(&j, "elapsed_ms", p->elapsed_ms);
    jl_print(&j, out);
}

/* Returns 0 to run, 1 for --help, -1 for bad arguments. */
static int parse_args(int argc, WCHAR **argv, struct probe *p, const WCHAR **out)
{
    int i;

    for (i = 1; i < argc; i++)
    {
        const WCHAR *arg = argv[i], *value = i + 1 < argc ? argv[i + 1] : NULL;

        if (!wcscmp(arg, L"--help") || !wcscmp(arg, L"-h")) return 1;
        if (!value) return -1;
        if (!wcscmp(arg, L"--url") && wcslen(value) < ARRAYSIZE(p->url)) wcscpy(p->url, value);
        else if (!wcscmp(arg, L"--out")) *out = value;
        else return -1;
        i++;
    }
    return 0;
}

int wmain(int argc, WCHAR **argv)
{
    static struct probe p;
    const WCHAR *out_path = NULL;
    HANDLE out = INVALID_HANDLE_VALUE;

    /* A test must never sit behind a crash or "insert disk" dialog. */
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);

    switch (parse_args(argc, argv, &p, &out_path))
    {
    case 1:
        fputs(usage, stdout);
        return 0;
    case -1:
        fputs(usage, stderr);
        fail(&p, "args", ERROR_INVALID_PARAMETER);
        print_result(&p, out);
        return 2;
    }
    if (!p.url[0]) default_url(p.url, ARRAYSIZE(p.url));
    p.expect_lzma = names_lzma_file(p.url);
    if (out_path && (out = jl_open_file(out_path)) == INVALID_HANDLE_VALUE)
    {
        fail(&p, "out_file", GetLastError());
        print_result(&p, out);
        return 1;
    }

    run(&p);
    evaluate(&p);
    print_result(&p, out);
    if (out != INVALID_HANDLE_VALUE) CloseHandle(out);
    return p.stage ? 1 : 0;
}
