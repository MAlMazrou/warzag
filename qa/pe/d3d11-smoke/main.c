/*
 * wz-d3d11-smoke: does Direct3D 11 reach the screen on this runtime, and through which implementation?
 *
 * Opens a 1280x720 window, creates a D3D11 device and a DXGI swap chain (flip-discard, falling back to the legacy
 * discard model), clears the back buffer to an animated colour and presents N frames. Prints exactly one JSON line
 * on stdout (and to --out) with the DXGI adapter, the feature level, the swap effect, which implementation is
 * really behind d3d11.dll and dxgi.dll, and frame-time statistics. ClearRenderTargetView is the only drawing, with
 * no shaders, so the same binary runs on DXMT and wined3d alike.
 *
 *   wz-d3d11-smoke.exe [--frames N] [--sync-interval 0-4] [--fullscreen] [--discard] [--out <file>]
 *
 * Exit status: 0 passed; 1 a stage failed ({"ok":false,"stage":...,"hresult":...}); 2 bad arguments.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdlib.h>
#include <string.h>

#include "../common/jsonline.h"

#define WINDOW_WIDTH 1280
#define WINDOW_HEIGHT 720
#define DEFAULT_FRAMES 300
#define MAX_FRAMES 1000000

static const char usage[] =
    "usage: wz-d3d11-smoke.exe [--frames N] [--sync-interval 0-4] [--fullscreen] [--discard] [--out <file>]\n"
    "  --frames N          frames to present, 2-1000000 (default 300)\n"
    "  --sync-interval S   Present() sync interval: 1 waits for vertical blank (default), 0 does not\n"
    "  --fullscreen        DXGI full screen on the primary monitor at its current mode instead of a window\n"
    "  --discard           only the legacy DISCARD swap effect, skipping the FLIP_DISCARD attempt\n"
    "  --out <file>        also write the JSON line to <file>, a Windows path such as Z:\\tmp\\smoke.json\n";

struct options
{
    unsigned int frames;
    unsigned int sync_interval;
    BOOL fullscreen;
    BOOL discard;
    const WCHAR *out;
};

struct gfx
{
    HWND hwnd;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGIAdapter *adapter;
    IDXGIFactory *factory;
    IDXGISwapChain *swapchain;
    ID3D11RenderTargetView *rtv;
    BOOL in_fullscreen;
};

/* Everything the run learns. It is printed whether the run passed or not, so a failure still shows how far it got. */
struct result
{
    const char *stage; /* first failed stage; NULL when everything passed */
    HRESULT hr;
    HRESULT removed_reason;
    BOOL have_device, have_adapter;
    D3D_FEATURE_LEVEL level;
    DXGI_ADAPTER_DESC adapter;
    const char *d3d11_impl, *dxgi_impl;
    const char *swapchain;
    HRESULT flip_hr; /* why flip-discard was refused, when the run fell back to discard */
    UINT width, height;
    unsigned int frames_done;
    double first_frame_ms, avg_ms, min_ms, max_ms, p99_ms;
};

static BOOL window_closed;

/* Records the first failure; returns TRUE when hr is one. */
static BOOL failed(struct result *r, const char *stage, HRESULT hr)
{
    if (SUCCEEDED(hr)) return FALSE;
    r->stage = stage;
    r->hr = hr;
    return TRUE;
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    /* Closing the window ends the run early; main() tears everything down in order. */
    if (msg == WM_CLOSE)
    {
        window_closed = TRUE;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static void pump_messages(void)
{
    MSG msg;

    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

static HRESULT create_window(const struct options *o, struct gfx *g, UINT *width, UINT *height)
{
    DWORD style = o->fullscreen ? WS_POPUP : WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT rect = {0, 0, WINDOW_WIDTH, WINDOW_HEIGHT};
    WNDCLASSEXW wc = {0};
    int x = CW_USEDEFAULT, y = CW_USEDEFAULT;

    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = L"WarzagD3D11Smoke";
    if (!RegisterClassExW(&wc)) return HRESULT_FROM_WIN32(GetLastError());

    /* Full screen covers the primary monitor at its current size, so DXGI never has to switch display modes. */
    if (o->fullscreen)
    {
        SetRect(&rect, 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
        x = y = 0;
    }
    *width = rect.right - rect.left;
    *height = rect.bottom - rect.top;
    if (!o->fullscreen) AdjustWindowRect(&rect, style, FALSE);

    g->hwnd = CreateWindowExW(0, wc.lpszClassName, L"Warzag D3D11 smoke test", style, x, y,
                              rect.right - rect.left, rect.bottom - rect.top, NULL, NULL, wc.hInstance, NULL);
    if (!g->hwnd) return HRESULT_FROM_WIN32(GetLastError());
    ShowWindow(g->hwnd, SW_SHOW);
    pump_messages();
    return S_OK;
}

/*
 * d3d11.dll is loaded at run time rather than imported. With an import, a missing d3d11.dll, or a missing import of
 * its own (DXMT's winemetal.dll in a prefix without its system32 placeholder), stops the process before wmain, so
 * there would be no result line at all.
 */
static HRESULT load_d3d11(PFN_D3D11_CREATE_DEVICE *create)
{
    HMODULE module = LoadLibraryW(L"d3d11.dll");

    if (!module) return HRESULT_FROM_WIN32(GetLastError());
    /* Via void (*)(void), which GCC accepts as a cast to any function pointer type without a warning. */
    *create = (PFN_D3D11_CREATE_DEVICE)(void (*)(void))GetProcAddress(module, "D3D11CreateDevice");
    return *create ? S_OK : HRESULT_FROM_WIN32(GetLastError());
}

static HRESULT create_device(PFN_D3D11_CREATE_DEVICE create, struct gfx *g, struct result *r)
{
    static const D3D_FEATURE_LEVEL levels[] =
    {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
    };
    HRESULT hr;

    hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, ARRAYSIZE(levels), D3D11_SDK_VERSION, &g->device,
                &r->level, &g->context);
    /* Runtimes that predate D3D 11.1 reject the whole list when it names 11_1. */
    if (hr == E_INVALIDARG)
        hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels + 1, ARRAYSIZE(levels) - 1, D3D11_SDK_VERSION,
                    &g->device, &r->level, &g->context);
    r->have_device = SUCCEEDED(hr);
    return hr;
}

/* The adapter the device really runs on, and the factory that owns it (swap chains must come from that one). */
static HRESULT get_adapter(struct gfx *g, struct result *r)
{
    IDXGIDevice *dxgi_device;
    HRESULT hr;

    if (FAILED(hr = ID3D11Device_QueryInterface(g->device, &IID_IDXGIDevice, (void **)&dxgi_device))) return hr;
    hr = IDXGIDevice_GetAdapter(dxgi_device, &g->adapter);
    IDXGIDevice_Release(dxgi_device);
    if (FAILED(hr)) return hr;
    if (FAILED(hr = IDXGIAdapter_GetDesc(g->adapter, &r->adapter))) return hr;
    r->have_adapter = TRUE;
    return IDXGIAdapter_GetParent(g->adapter, &IID_IDXGIFactory, (void **)&g->factory);
}

static BOOL module_imports(HMODULE module, const char *dll)
{
    const BYTE *base = (const BYTE *)module;
    const IMAGE_NT_HEADERS *nt;
    const IMAGE_DATA_DIRECTORY *dir;
    const IMAGE_IMPORT_DESCRIPTOR *imp;

    if (!module) return FALSE;
    nt = (const IMAGE_NT_HEADERS *)(base + ((const IMAGE_DOS_HEADER *)base)->e_lfanew);
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir->VirtualAddress) return FALSE;
    for (imp = (const IMAGE_IMPORT_DESCRIPTOR *)(base + dir->VirtualAddress); imp->Name; imp++)
        if (!_stricmp((const char *)(base + imp->Name), dll)) return TRUE;
    return FALSE;
}

/*
 * Which implementation is really behind d3d11.dll or dxgi.dll. Under Wine every builtin reports a
 * C:\windows\system32 path, so look at what the loaded module links against: DXMT's DLLs import winemetal.dll and
 * Wine's own import wined3d.dll. Anything else (Microsoft's own DLLs on Windows) is "other".
 */
static const char *implementation(const WCHAR *dll)
{
    HMODULE module = GetModuleHandleW(dll);

    if (module_imports(module, "winemetal.dll")) return "dxmt";
    if (module_imports(module, "wined3d.dll")) return "wined3d";
    return "other";
}

static HRESULT create_swapchain(struct gfx *g, struct result *r, UINT width, UINT height, BOOL try_flip)
{
    DXGI_SWAP_CHAIN_DESC legacy = {0};
    IDXGIFactory2 *factory2;
    HRESULT hr = S_OK;

    /* Flip-discard first: the model current D3D11 games use (it needs DXGI 1.2 and at least two buffers). */
    if (try_flip && SUCCEEDED(hr = IDXGIFactory_QueryInterface(g->factory, &IID_IDXGIFactory2, (void **)&factory2)))
    {
        DXGI_SWAP_CHAIN_DESC1 desc = {0};
        IDXGISwapChain1 *swapchain1;

        desc.Width = width;
        desc.Height = height;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        hr = IDXGIFactory2_CreateSwapChainForHwnd(factory2, (IUnknown *)g->device, g->hwnd, &desc, NULL, NULL,
                                                  &swapchain1);
        IDXGIFactory2_Release(factory2);
        if (SUCCEEDED(hr))
        {
            g->swapchain = (IDXGISwapChain *)swapchain1; /* IDXGISwapChain1 extends IDXGISwapChain */
            r->swapchain = "flip_discard";
            return hr;
        }
    }
    r->flip_hr = hr;

    /* The legacy blit model that older D3D11 games still use. */
    legacy.BufferDesc.Width = width;
    legacy.BufferDesc.Height = height;
    legacy.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    legacy.SampleDesc.Count = 1;
    legacy.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    legacy.BufferCount = 1;
    legacy.OutputWindow = g->hwnd;
    legacy.Windowed = TRUE;
    legacy.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    hr = IDXGIFactory_CreateSwapChain(g->factory, (IUnknown *)g->device, &legacy, &g->swapchain);
    if (SUCCEEDED(hr)) r->swapchain = "discard";
    return hr;
}

static HRESULT enter_fullscreen(struct gfx *g)
{
    HRESULT hr = IDXGISwapChain_SetFullscreenState(g->swapchain, TRUE, NULL);

    if (FAILED(hr)) return hr;
    g->in_fullscreen = TRUE;
    /* Zero sizes: match the buffers to whatever the full-screen window ended up as. */
    return IDXGISwapChain_ResizeBuffers(g->swapchain, 0, 0, 0, DXGI_FORMAT_UNKNOWN, 0);
}

static HRESULT create_render_target(struct gfx *g, struct result *r)
{
    D3D11_TEXTURE2D_DESC desc;
    ID3D11Texture2D *buffer;
    HRESULT hr;

    if (FAILED(hr = IDXGISwapChain_GetBuffer(g->swapchain, 0, &IID_ID3D11Texture2D, (void **)&buffer))) return hr;
    ID3D11Texture2D_GetDesc(buffer, &desc);
    r->width = desc.Width;
    r->height = desc.Height;
    hr = ID3D11Device_CreateRenderTargetView(g->device, (ID3D11Resource *)buffer, NULL, &g->rtv);
    ID3D11Texture2D_Release(buffer);
    return hr;
}

/* 0 -> 1 -> 0 over each unit interval. */
static float triangle(float x)
{
    x -= (float)(int)x;
    return x < 0.5f ? 2.0f * x : 2.0f - 2.0f * x;
}

static int compare_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;

    return (x > y) - (x < y);
}

/* Frame i's time runs from the return of Present i-1 to the return of Present i. Frame 0 carries one-off costs
   (swap chain and pipeline setup), so it is reported on its own and left out of the statistics. */
static void frame_stats(struct result *r, double *ms, unsigned int count)
{
    double sum = 0.0;
    unsigned int i, n = count ? count - 1 : 0;

    if (!count) return;
    r->first_frame_ms = ms[0];
    if (!n) return;
    qsort(ms + 1, n, sizeof(*ms), compare_double);
    for (i = 1; i <= n; i++) sum += ms[i];
    r->avg_ms = sum / n;
    r->min_ms = ms[1];
    r->max_ms = ms[n];
    r->p99_ms = ms[(99ull * n + 99) / 100]; /* nearest rank: index ceil(0.99 n) in the 1-based tail */
}

static HRESULT render(struct gfx *g, const struct options *o, struct result *r)
{
    LARGE_INTEGER freq, prev, now;
    double *ms = malloc(o->frames * sizeof(*ms));
    HRESULT hr = S_OK;
    unsigned int i;

    if (!ms) return E_OUTOFMEMORY;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&prev);
    for (i = 0; i < o->frames; i++)
    {
        float t = (float)i / 180.0f; /* one full colour cycle every 180 frames, 3 s at 60 Hz */
        const float colour[4] = {triangle(t), triangle(t + 1.0f / 3.0f), triangle(t + 2.0f / 3.0f), 1.0f};

        pump_messages();
        if (window_closed)
        {
            hr = E_ABORT;
            break;
        }
        ID3D11DeviceContext_ClearRenderTargetView(g->context, g->rtv, colour);
        hr = IDXGISwapChain_Present(g->swapchain, o->sync_interval, 0);
        if (FAILED(hr))
        {
            if (hr == DXGI_ERROR_DEVICE_REMOVED) r->removed_reason = ID3D11Device_GetDeviceRemovedReason(g->device);
            break;
        }
        QueryPerformanceCounter(&now);
        ms[i] = (double)(now.QuadPart - prev.QuadPart) * 1000.0 / (double)freq.QuadPart;
        prev = now;
        r->frames_done = i + 1;
    }
    if (SUCCEEDED(hr)) frame_stats(r, ms, r->frames_done);
    free(ms);
    return hr;
}

static void run(const struct options *o, struct gfx *g, struct result *r)
{
    PFN_D3D11_CREATE_DEVICE create = NULL;
    UINT width = 0, height = 0;
    HRESULT hr;

    if (failed(r, "d3d11_load", load_d3d11(&create))) return;
    if (failed(r, "window", create_window(o, g, &width, &height))) return;
    if (failed(r, "d3d11_create_device", create_device(create, g, r))) return;
    if (failed(r, "dxgi_adapter", get_adapter(g, r))) return;
    r->d3d11_impl = implementation(L"d3d11.dll");
    r->dxgi_impl = implementation(L"dxgi.dll");
    if (failed(r, "swapchain", create_swapchain(g, r, width, height, !o->discard))) return;
    /* Keep Alt+Enter from switching modes in the middle of a measurement. */
    IDXGIFactory_MakeWindowAssociation(g->factory, g->hwnd, DXGI_MWA_NO_ALT_ENTER);
    if (o->fullscreen && failed(r, "fullscreen", enter_fullscreen(g))) return;
    if (failed(r, "render_target", create_render_target(g, r))) return;
    hr = render(g, o, r);
    failed(r, hr == E_ABORT ? "window_closed" : "present", hr);
}

static void cleanup(struct gfx *g)
{
    /* DXGI requires leaving full-screen state before the swap chain goes away. */
    if (g->in_fullscreen) IDXGISwapChain_SetFullscreenState(g->swapchain, FALSE, NULL);
    if (g->rtv) ID3D11RenderTargetView_Release(g->rtv);
    if (g->swapchain) IDXGISwapChain_Release(g->swapchain);
    if (g->factory) IDXGIFactory_Release(g->factory);
    if (g->adapter) IDXGIAdapter_Release(g->adapter);
    if (g->context)
    {
        ID3D11DeviceContext_ClearState(g->context);
        ID3D11DeviceContext_Release(g->context);
    }
    if (g->device) ID3D11Device_Release(g->device);
    if (g->hwnd) DestroyWindow(g->hwnd);
}

static void print_result(const struct options *o, const struct result *r, HANDLE out)
{
    struct jsonline j = {0};
    char level[8];

    jl_bool(&j, "ok", !r->stage);
    if (r->stage)
    {
        jl_str(&j, "stage", r->stage);
        jl_hex(&j, "hresult", (unsigned long)r->hr, 8);
        if (r->removed_reason) jl_hex(&j, "device_removed_reason", (unsigned long)r->removed_reason, 8);
    }
    if (r->have_adapter)
    {
        jl_hex(&j, "vendor_id", r->adapter.VendorId, 4);
        jl_hex(&j, "device_id", r->adapter.DeviceId, 4);
        jl_wstr(&j, "adapter", r->adapter.Description);
    }
    if (r->have_device)
    {
        /* D3D_FEATURE_LEVEL_11_0 is 0xb000: major in bits 12-15, minor in bits 8-11. */
        unsigned int fl = (unsigned int)r->level;

        snprintf(level, sizeof(level), "%u_%u", (fl >> 12) & 0xf, (fl >> 8) & 0xf);
        jl_str(&j, "feature_level", level);
    }
    if (r->swapchain) jl_str(&j, "swapchain", r->swapchain);
    jl_int(&j, "frames", r->frames_done);
    if (!r->stage)
    {
        jl_num(&j, "avg_ms", r->avg_ms);
        jl_num(&j, "p99_ms", r->p99_ms);
        jl_num(&j, "min_ms", r->min_ms);
        jl_num(&j, "max_ms", r->max_ms);
        jl_num(&j, "first_frame_ms", r->first_frame_ms);
    }
    if (r->d3d11_impl)
    {
        jl_str(&j, "d3d11_impl", r->d3d11_impl);
        jl_str(&j, "dxgi_impl", r->dxgi_impl);
    }
    if (r->have_adapter) jl_int(&j, "dedicated_video_memory_mb", (long long)(r->adapter.DedicatedVideoMemory >> 20));
    if (r->width)
    {
        jl_int(&j, "width", r->width);
        jl_int(&j, "height", r->height);
    }
    jl_bool(&j, "fullscreen", o->fullscreen);
    jl_int(&j, "sync_interval", o->sync_interval);
    if (r->swapchain && FAILED(r->flip_hr)) jl_hex(&j, "flip_discard_hresult", (unsigned long)r->flip_hr, 8);
    jl_print(&j, out);
}

static BOOL parse_uint(const WCHAR *s, unsigned int min, unsigned int max, unsigned int *value)
{
    unsigned long v;
    WCHAR *end;

    if (*s < L'0' || *s > L'9') return FALSE;
    v = wcstoul(s, &end, 10);
    if (*end || v < min || v > max) return FALSE;
    *value = (unsigned int)v;
    return TRUE;
}

/* Returns 0 to run, 1 for --help, -1 for bad arguments. */
static int parse_args(int argc, WCHAR **argv, struct options *o)
{
    int i;

    for (i = 1; i < argc; i++)
    {
        const WCHAR *arg = argv[i], *value = i + 1 < argc ? argv[i + 1] : NULL;

        if (!wcscmp(arg, L"--help") || !wcscmp(arg, L"-h")) return 1;
        if (!wcscmp(arg, L"--fullscreen")) o->fullscreen = TRUE;
        else if (!wcscmp(arg, L"--discard")) o->discard = TRUE;
        else if (!value) return -1;
        else if (!wcscmp(arg, L"--frames") && parse_uint(value, 2, MAX_FRAMES, &o->frames)) i++;
        else if (!wcscmp(arg, L"--sync-interval") && parse_uint(value, 0, 4, &o->sync_interval)) i++;
        else if (!wcscmp(arg, L"--out")) o->out = argv[++i];
        else return -1;
    }
    return 0;
}

int wmain(int argc, WCHAR **argv)
{
    struct options o = {.frames = DEFAULT_FRAMES, .sync_interval = 1};
    struct result r = {0};
    struct gfx g = {0};
    HANDLE out = INVALID_HANDLE_VALUE;

    /* A test must never sit behind a crash or "insert disk" dialog. */
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);

    switch (parse_args(argc, argv, &o))
    {
    case 1:
        fputs(usage, stdout);
        return 0;
    case -1:
        fputs(usage, stderr);
        failed(&r, "args", E_INVALIDARG);
        print_result(&o, &r, out);
        return 2;
    }
    if (o.out && (out = jl_open_file(o.out)) == INVALID_HANDLE_VALUE)
    {
        failed(&r, "out_file", HRESULT_FROM_WIN32(GetLastError()));
        print_result(&o, &r, out);
        return 1;
    }

    run(&o, &g, &r);
    /* Print before teardown so a crash while releasing still leaves the result behind (and a non-zero exit). */
    print_result(&o, &r, out);
    cleanup(&g);
    if (out != INVALID_HANDLE_VALUE) CloseHandle(out);
    return r.stage ? 1 : 0;
}
