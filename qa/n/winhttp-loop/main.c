/*
 * wz-winhttp-loop.exe: a WinHTTP download loop shaped like DE's launcher (Wine bug 59605 class), for local servers.
 *
 *   wz-winhttp-loop.exe [--decompress] [--range BYTES] [--buffer BYTES] --url URL [--url URL ...]
 *
 * DE's Launcher.exe imports WinHttpOpen/Connect/OpenRequest/AddRequestHeaders/SendRequest/ReceiveResponse/
 * ReadData/QueryHeaders/SetOption, and not WinHttpQueryDataAvailable or WinHttpSetStatusCallback: a synchronous
 * client that reads with WinHttpReadData alone. This program does the same, over one session and one connection
 * per host (keep-alive), fetching every URL in order; with --range it fetches each file in Range pieces, with
 * --decompress it turns on WINHTTP_OPTION_DECOMPRESSION.
 *
 * Every body is checked: its size against Content-Length / Content-Range / X-Original-Length, and its FNV-1a hash
 * against X-Body-FNV (both sent by qa/n/winhttp-local-server.py). Only loopback hosts are accepted, so it never
 * loads DE's servers. One JSON line per URL, then a summary line. Exit: 0 all complete, 1 a transfer failed or was
 * incomplete, 2 bad arguments.
 *
 * Copyright (C) 2026 Warzag contributors. Licensed under the GNU General Public License v3.0 (see LICENSE).
 */
#include <windows.h>
#include <winhttp.h>
#include <stdint.h>
#include <stdlib.h>
#include <wchar.h>
#include "jsonline.h"

static uint64_t fnv1a(uint64_t h, const unsigned char *p, DWORD n)
{
    for (DWORD i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001b3ull; }
    return h;
}

static uint64_t header_u64(HINTERNET req, const WCHAR *name, BOOL *found)
{
    WCHAR buf[64];
    DWORD size = sizeof(buf);
    *found = WinHttpQueryHeaders(req, WINHTTP_QUERY_CUSTOM, name, buf, &size, WINHTTP_NO_HEADER_INDEX);
    return *found ? _wcstoui64(buf, NULL, 0) : 0;
}

struct result
{
    const char *stage;
    DWORD error;
    DWORD status;
    uint64_t bytes, expect, hash, expect_hash;
    int requests;
    double ms;
};

/* One request for [from, to] (to < 0: whole body) on an open connection; appends to the running hash. */
static BOOL fetch(HINTERNET conn, const WCHAR *path, BOOL secure, long long from, long long to, unsigned char *buf,
                  DWORD bufsize, struct result *r, uint64_t *total_out)
{
    HINTERNET req;
    WCHAR range[96];
    DWORD size = sizeof(r->status), got;
    BOOL ok = FALSE, found;

    if (!(req = WinHttpOpenRequest(conn, L"GET", path, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                   secure ? WINHTTP_FLAG_SECURE : 0)))
    { r->stage = "request"; r->error = GetLastError(); return FALSE; }
    if (to >= 0)
    {
        swprintf(range, ARRAYSIZE(range), L"Range: bytes=%lld-%lld", from, to);
        if (!WinHttpAddRequestHeaders(req, range, (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD))
        { r->stage = "headers"; r->error = GetLastError(); goto done; }
    }
    if (!WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0))
    { r->stage = "send"; r->error = GetLastError(); goto done; }
    if (!WinHttpReceiveResponse(req, NULL))
    { r->stage = "receive"; r->error = GetLastError(); goto done; }
    WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                        &r->status, &size, WINHTTP_NO_HEADER_INDEX);
    if (r->status != (to >= 0 ? 206u : 200u)) { r->stage = "http_status"; goto done; }
    if (total_out)
    {
        *total_out = header_u64(req, L"X-Original-Length", &found);
        r->expect_hash = header_u64(req, L"X-Body-FNV", &found);
    }
    r->requests++;
    for (;;)  /* the launcher's shape: WinHttpReadData until it returns no data */
    {
        if (!WinHttpReadData(req, buf, bufsize, &got)) { r->stage = "read"; r->error = GetLastError(); goto done; }
        if (!got) break;
        r->hash = fnv1a(r->hash, buf, got);
        r->bytes += got;
    }
    ok = TRUE;
done:
    WinHttpCloseHandle(req);
    return ok;
}

static BOOL loopback(const WCHAR *host)
{
    return !_wcsicmp(host, L"127.0.0.1") || !_wcsicmp(host, L"localhost") || !_wcsicmp(host, L"[::1]");
}

int wmain(int argc, WCHAR **argv)
{
    const WCHAR *urls[64];
    int nurls = 0, decompress = 0, failed = 0;
    long long range = 0;
    DWORD bufsize = 1 << 20;
    unsigned char *buf;
    HINTERNET session;
    LARGE_INTEGER freq, t0, t1, all0, all1;
    uint64_t total_bytes = 0;

    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    for (int i = 1; i < argc; i++)
    {
        if (!wcscmp(argv[i], L"--decompress")) decompress = 1;
        else if (!wcscmp(argv[i], L"--range") && i + 1 < argc) range = _wtoi64(argv[++i]);
        else if (!wcscmp(argv[i], L"--buffer") && i + 1 < argc) bufsize = (DWORD)_wtoi(argv[++i]);
        else if (!wcscmp(argv[i], L"--url") && i + 1 < argc && nurls < 64) urls[nurls++] = argv[++i];
        else
        {
            struct jsonline j = {0};
            jl_bool(&j, "ok", 0); jl_str(&j, "stage", "args");
            jl_print(&j, INVALID_HANDLE_VALUE);
            return 2;
        }
    }
    if (!nurls || bufsize < 1 || bufsize > (64u << 20) || range < 0) return 2;
    buf = malloc(bufsize);
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&all0);
    session = WinHttpOpen(L"Warzag-winhttp-loop/1.0", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME,
                          WINHTTP_NO_PROXY_BYPASS, 0);
    if (session)
    {
        WinHttpSetTimeouts(session, 15000, 15000, 30000, 30000);
        if (decompress)
        {
            DWORD flags = WINHTTP_DECOMPRESSION_FLAG_ALL;
            WinHttpSetOption(session, WINHTTP_OPTION_DECOMPRESSION, &flags, sizeof(flags));
        }
    }
    for (int u = 0; u < nurls; u++)
    {
        struct result r = { 0 };
        URL_COMPONENTS uc = { 0 };
        WCHAR host[256] = L"", path[1024] = L"";
        HINTERNET conn = NULL;
        struct jsonline j = { 0 };

        r.hash = 0xcbf29ce484222325ull;
        uc.dwStructSize = sizeof(uc);
        uc.lpszHostName = host; uc.dwHostNameLength = ARRAYSIZE(host);
        uc.lpszUrlPath = path; uc.dwUrlPathLength = ARRAYSIZE(path);
        QueryPerformanceCounter(&t0);
        if (!session) { r.stage = "open"; r.error = GetLastError(); }
        else if (!WinHttpCrackUrl(urls[u], 0, 0, &uc)) { r.stage = "url"; r.error = GetLastError(); }
        else if (!loopback(host)) r.stage = "not_loopback";
        else if (!(conn = WinHttpConnect(session, host, uc.nPort, 0))) { r.stage = "connect"; r.error = GetLastError(); }
        else if (!range)
        {
            if (fetch(conn, path, uc.nScheme == INTERNET_SCHEME_HTTPS, 0, -1, buf, bufsize, &r, &r.expect)
                && r.bytes != r.expect) r.stage = "incomplete";
        }
        else
        {
            /* first piece tells the total size; then the rest in order */
            if (fetch(conn, path, uc.nScheme == INTERNET_SCHEME_HTTPS, 0, range - 1, buf, bufsize, &r, &r.expect))
            {
                while (!r.stage && r.bytes < r.expect)
                {
                    long long from = (long long)r.bytes, to = from + range - 1;
                    if ((uint64_t)to >= r.expect) to = (long long)r.expect - 1;
                    if (!fetch(conn, path, uc.nScheme == INTERNET_SCHEME_HTTPS, from, to, buf, bufsize, &r, NULL)) break;
                }
                if (!r.stage && r.bytes != r.expect) r.stage = "incomplete";
            }
        }
        if (!r.stage && r.expect_hash && r.hash != r.expect_hash) r.stage = "corrupt";
        QueryPerformanceCounter(&t1);
        r.ms = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / (double)freq.QuadPart;
        if (conn) WinHttpCloseHandle(conn);
        jl_bool(&j, "ok", !r.stage);
        if (r.stage) jl_str(&j, "stage", r.stage);
        if (r.error) jl_int(&j, "error", r.error);
        jl_wstr(&j, "url", urls[u]);
        jl_int(&j, "status", r.status);
        jl_int(&j, "requests", r.requests);
        jl_int(&j, "bytes", (long long)r.bytes);
        jl_int(&j, "expected", (long long)r.expect);
        jl_bool(&j, "hash_ok", r.expect_hash && r.hash == r.expect_hash);
        jl_num(&j, "elapsed_ms", r.ms);
        jl_print(&j, INVALID_HANDLE_VALUE);
        failed |= r.stage != NULL;
        total_bytes += r.bytes;
    }
    QueryPerformanceCounter(&all1);
    {
        struct jsonline j = { 0 };
        double ms = (double)(all1.QuadPart - all0.QuadPart) * 1000.0 / (double)freq.QuadPart;
        jl_bool(&j, "summary", 1);
        jl_bool(&j, "ok", !failed);
        jl_int(&j, "files", nurls);
        jl_bool(&j, "decompress", decompress);
        jl_int(&j, "range", range);
        jl_int(&j, "bytes", (long long)total_bytes);
        jl_num(&j, "elapsed_ms", ms);
        jl_num(&j, "mb_per_s", ms > 0 ? (double)total_bytes / 1048576.0 / (ms / 1000.0) : 0);
        jl_print(&j, INVALID_HANDLE_VALUE);
    }
    if (session) WinHttpCloseHandle(session);
    return failed ? 1 : 0;
}
