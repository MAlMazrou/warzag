/*
 * wz-d3d11-pso-reject: a pipeline that Metal rejects must not leave a freed NSError in a DXMT worker's autorelease
 * pool (wz-n-dxmt-0002). qa/n/pso-reject.sh runs it.
 *
 * The vertex shader writes SV_Position and TEXCOORD0, the pixel shader reads TEXCOORD0 and TEXCOORD1. Both are
 * compiled at run time with D3DCompile (d3dcompiler_47.dll, loaded like d3d11.dll). DXMT converts each shader on its
 * own, so Metal refuses to link them. One draw into an offscreen render target makes DXMT compile that pipeline on a
 * worker thread; Metal returns an NSError and DXMT drops the draw (the read-back pixel keeps the clear colour). A
 * second draw with a pixel shader that reads TEXCOORD0 only must link on the same workers and render the vertex
 * shader's red. Then the program releases everything, so the device's worker threads exit and drain their
 * autorelease pools, waits until they have, and prints one JSON line.
 *
 *   wz-d3d11-pso-reject.exe [--pipelines N] [--frames N] [--out <file>]
 *
 *   --pipelines N  draw with N different blend states, so DXMT compiles N rejected pipelines (1-960, default 1)
 *   --frames N     first present N frames to a 640x360 window (default 0: no window), then set a debug name on a
 *                  resource, for which DXMT pushes and pops an autorelease pool on this thread: with
 *                  OBJC_PRINT_POOL_HIGHWATER=YES, objc then reports what presenting left in this thread's pool
 *
 * Exit status: 0 every stage passed (whether Metal rejected the pipeline is "draw_dropped", whether the linked
 * pipeline rendered is "linked_drawn"); 1 a stage failed ({"ok":false,"stage":...,"hresult":...}); 2 bad arguments.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <stdlib.h>
#include <string.h>

#include "../common/jsonline.h"

#define RT_SIZE 16
#define WINDOW_WIDTH 640
#define WINDOW_HEIGHT 360
#define MAX_PIPELINES 960
#define MAX_FRAMES 100000
#define CLEAR_PIXEL 0xFF00FF00u /* R8G8B8A8_UNORM green {0, 1, 0, 1} read as a little-endian 32-bit word */
#define LINKED_PIXEL 0xFF0000FFu /* R8G8B8A8_UNORM red {1, 0, 0, 1}: what the vertex shader passes in TEXCOORD0 */

static const char usage[] =
    "usage: wz-d3d11-pso-reject.exe [--pipelines N] [--frames N] [--out <file>]\n"
    "  --pipelines N  draw with N different blend states: N rejected pipelines (1-960, default 1)\n"
    "  --frames N     first present N frames to a window, then make DXMT pop a pool on this thread (default 0)\n"
    "  --out <file>   also write the JSON line to <file>, a Windows path such as Z:\\tmp\\pso.json\n";

/* The VS writes o0 (SV_Position) and o1 (TEXCOORD0); the PS reads v1 (TEXCOORD0) and v2 (TEXCOORD1). DXMT names the
   interpolants after their registers, so the fragment function's v2 input has no vertex output and Metal rejects the
   pipeline. */
static const char vs_source[] =
    "struct vs_out { float4 position : SV_Position; float4 t0 : TEXCOORD0; };\n"
    "vs_out main(uint id : SV_VertexID)\n"
    "{\n"
    "    vs_out o;\n"
    "    float2 uv = float2((id << 1) & 2, id & 2);\n"
    "    o.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);\n"
    "    o.t0 = float4(1.0, 0.0, 0.0, 1.0);\n"
    "    return o;\n"
    "}\n";

static const char ps_source[] =
    "struct ps_in { float4 position : SV_Position; float4 t0 : TEXCOORD0; float4 t1 : TEXCOORD1; };\n"
    "float4 main(ps_in i) : SV_Target\n"
    "{\n"
    "    return i.t0 + i.t1;\n"
    "}\n";

/* The same vertex shader with a pixel shader that reads TEXCOORD0 only: Metal links this pair, and its draw paints the
   vertex shader's red. */
static const char ps_linked_source[] =
    "struct ps_in { float4 position : SV_Position; float4 t0 : TEXCOORD0; };\n"
    "float4 main(ps_in i) : SV_Target\n"
    "{\n"
    "    return i.t0;\n"
    "}\n";

struct options
{
    unsigned int pipelines;
    unsigned int frames;
    const WCHAR *out;
};

struct gfx
{
    HWND hwnd;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps, *ps_linked;
    ID3D11Texture2D *target, *staging;
    ID3D11RenderTargetView *rtv;
    IDXGISwapChain *swapchain;
    ID3D11RenderTargetView *back_rtv;
};

struct result
{
    const char *stage; /* first failed stage; NULL when everything passed */
    HRESULT hr;
    const char *compiler;
    const char *d3d11_impl;
    char compile_error[256];
    unsigned int pipelines_drawn;
    unsigned int frames_done;
    BOOL have_pixel;
    UINT32 pixel;
    BOOL have_linked_pixel;
    UINT32 linked_pixel;
    BOOL pool_probe;
    BOOL device_released, workers_reaped;
};

static BOOL failed(struct result *r, const char *stage, HRESULT hr)
{
    if (SUCCEEDED(hr)) return FALSE;
    r->stage = stage;
    r->hr = hr;
    return TRUE;
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

/* As wz-d3d11-smoke: DXMT's d3d11.dll imports winemetal.dll, Wine's own imports wined3d.dll. */
static const char *implementation(void)
{
    HMODULE module = GetModuleHandleW(L"d3d11.dll");

    if (module_imports(module, "winemetal.dll")) return "dxmt";
    if (module_imports(module, "wined3d.dll")) return "wined3d";
    return "other";
}

/* Both DLLs are loaded at run time, so a missing one is a result line instead of a loader error before wmain. */
static HRESULT load_functions(PFN_D3D11_CREATE_DEVICE *create, pD3DCompile *compile, struct result *r)
{
    static const WCHAR *const compilers[] = {L"d3dcompiler_47.dll", L"d3dcompiler_43.dll"};
    static const char *const compiler_names[] = {"d3dcompiler_47", "d3dcompiler_43"};
    HMODULE module = LoadLibraryW(L"d3d11.dll");
    unsigned int i;

    if (!module) return HRESULT_FROM_WIN32(GetLastError());
    /* Via void (*)(void), which GCC accepts as a cast to any function pointer type without a warning. */
    *create = (PFN_D3D11_CREATE_DEVICE)(void (*)(void))GetProcAddress(module, "D3D11CreateDevice");
    if (!*create) return HRESULT_FROM_WIN32(GetLastError());
    for (i = 0; i < ARRAYSIZE(compilers); i++)
    {
        if (!(module = LoadLibraryW(compilers[i]))) continue;
        if ((*compile = (pD3DCompile)(void (*)(void))GetProcAddress(module, "D3DCompile")))
        {
            r->compiler = compiler_names[i];
            return S_OK;
        }
    }
    return HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
}

static HRESULT compile(pD3DCompile fn, const char *source, const char *target, ID3DBlob **code, struct result *r)
{
    ID3DBlob *errors = NULL;
    HRESULT hr = fn(source, strlen(source), NULL, NULL, NULL, "main", target, 0, 0, code, &errors);

    if (errors)
    {
        size_t n = ID3D10Blob_GetBufferSize(errors);

        if (FAILED(hr) && n)
        {
            if (n >= sizeof(r->compile_error)) n = sizeof(r->compile_error) - 1;
            memcpy(r->compile_error, ID3D10Blob_GetBufferPointer(errors), n);
            r->compile_error[n] = 0;
        }
        ID3D10Blob_Release(errors);
    }
    return hr;
}

static HRESULT create_shaders(pD3DCompile fn, struct gfx *g, struct result *r)
{
    ID3DBlob *vs_code = NULL, *ps_code = NULL, *ps_linked_code = NULL;
    HRESULT hr;

    if (SUCCEEDED(hr = compile(fn, vs_source, "vs_5_0", &vs_code, r)) &&
        SUCCEEDED(hr = compile(fn, ps_source, "ps_5_0", &ps_code, r)) &&
        SUCCEEDED(hr = compile(fn, ps_linked_source, "ps_5_0", &ps_linked_code, r)) &&
        SUCCEEDED(hr = ID3D11Device_CreateVertexShader(g->device, ID3D10Blob_GetBufferPointer(vs_code),
                                                       ID3D10Blob_GetBufferSize(vs_code), NULL, &g->vs)) &&
        SUCCEEDED(hr = ID3D11Device_CreatePixelShader(g->device, ID3D10Blob_GetBufferPointer(ps_code),
                                                      ID3D10Blob_GetBufferSize(ps_code), NULL, &g->ps)))
        hr = ID3D11Device_CreatePixelShader(g->device, ID3D10Blob_GetBufferPointer(ps_linked_code),
                                            ID3D10Blob_GetBufferSize(ps_linked_code), NULL, &g->ps_linked);
    if (vs_code) ID3D10Blob_Release(vs_code);
    if (ps_code) ID3D10Blob_Release(ps_code);
    if (ps_linked_code) ID3D10Blob_Release(ps_linked_code);
    return hr;
}

static HRESULT create_target(struct gfx *g)
{
    D3D11_TEXTURE2D_DESC desc = {0};
    HRESULT hr;

    desc.Width = RT_SIZE;
    desc.Height = RT_SIZE;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    if (FAILED(hr = ID3D11Device_CreateTexture2D(g->device, &desc, NULL, &g->target))) return hr;
    if (FAILED(hr = ID3D11Device_CreateRenderTargetView(g->device, (ID3D11Resource *)g->target, NULL, &g->rtv)))
        return hr;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    return ID3D11Device_CreateTexture2D(g->device, &desc, NULL, &g->staging);
}

/* The i-th of MAX_PIPELINES different blend states (15 write masks x 8 x 8 blend factors): each is another pipeline. */
static void blend_desc(unsigned int i, D3D11_BLEND_DESC *desc)
{
    static const D3D11_BLEND factors[8] =
    {
        D3D11_BLEND_ONE, D3D11_BLEND_ZERO, D3D11_BLEND_SRC_ALPHA, D3D11_BLEND_INV_SRC_ALPHA,
        D3D11_BLEND_DEST_ALPHA, D3D11_BLEND_INV_DEST_ALPHA, D3D11_BLEND_SRC_COLOR, D3D11_BLEND_DEST_COLOR,
    };

    memset(desc, 0, sizeof(*desc));
    desc->RenderTarget[0].BlendEnable = TRUE;
    desc->RenderTarget[0].RenderTargetWriteMask = (UINT8)(i % 15 + 1);
    desc->RenderTarget[0].SrcBlend = factors[i / 15 % 8];
    desc->RenderTarget[0].DestBlend = factors[i / 120 % 8];
    desc->RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    desc->RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    desc->RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO;
    desc->RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
}

/* Copies the render target to the staging texture and reads its centre pixel. Map waits for the GPU, and DXMT encodes
   a draw only once its pipeline is compiled (or rejected), so every pipeline drawn so far has been compiled by then. */
static HRESULT read_centre_pixel(struct gfx *g, UINT32 *pixel)
{
    D3D11_MAPPED_SUBRESOURCE mapped;
    HRESULT hr;

    ID3D11DeviceContext_CopyResource(g->context, (ID3D11Resource *)g->staging, (ID3D11Resource *)g->target);
    if (FAILED(hr = ID3D11DeviceContext_Map(g->context, (ID3D11Resource *)g->staging, 0, D3D11_MAP_READ, 0, &mapped)))
        return hr;
    *pixel = *(const UINT32 *)((const BYTE *)mapped.pData + (RT_SIZE / 2) * mapped.RowPitch + (RT_SIZE / 2) * 4);
    ID3D11DeviceContext_Unmap(g->context, (ID3D11Resource *)g->staging, 0);
    return S_OK;
}

/* Draws the mismatched pair once per blend state, then reads back the centre pixel. */
static HRESULT draw_rejected(const struct options *o, struct gfx *g, struct result *r)
{
    static const float green[4] = {0.0f, 1.0f, 0.0f, 1.0f};
    D3D11_VIEWPORT viewport = {0.0f, 0.0f, (float)RT_SIZE, (float)RT_SIZE, 0.0f, 1.0f};
    unsigned int i;
    HRESULT hr;

    ID3D11DeviceContext_ClearRenderTargetView(g->context, g->rtv, green);
    ID3D11DeviceContext_OMSetRenderTargets(g->context, 1, &g->rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(g->context, 1, &viewport);
    ID3D11DeviceContext_IASetPrimitiveTopology(g->context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(g->context, g->vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(g->context, g->ps, NULL, 0);
    for (i = 0; i < o->pipelines; i++)
    {
        ID3D11BlendState *blend;
        D3D11_BLEND_DESC desc;

        blend_desc(i, &desc);
        if (FAILED(hr = ID3D11Device_CreateBlendState(g->device, &desc, &blend))) return hr;
        ID3D11DeviceContext_OMSetBlendState(g->context, blend, NULL, 0xffffffff);
        ID3D11DeviceContext_Draw(g->context, 3, 0);
        ID3D11BlendState_Release(blend);
        r->pipelines_drawn = i + 1;
    }
    if (FAILED(hr = read_centre_pixel(g, &r->pixel))) return hr;
    r->have_pixel = TRUE;
    return S_OK;
}

/* Draws the pair that links (no blending) over a fresh clear and reads back the centre pixel: the vertex shader's red
   when the pipeline compiled and rendered. */
static HRESULT draw_linked(struct gfx *g, struct result *r)
{
    static const float green[4] = {0.0f, 1.0f, 0.0f, 1.0f};
    HRESULT hr;

    ID3D11DeviceContext_ClearRenderTargetView(g->context, g->rtv, green);
    ID3D11DeviceContext_OMSetBlendState(g->context, NULL, NULL, 0xffffffff);
    ID3D11DeviceContext_PSSetShader(g->context, g->ps_linked, NULL, 0);
    ID3D11DeviceContext_Draw(g->context, 3, 0);
    if (FAILED(hr = read_centre_pixel(g, &r->linked_pixel))) return hr;
    r->have_linked_pixel = TRUE;
    return S_OK;
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

/* --frames: a window, a legacy swap chain and N cleared, presented frames (DXMT queries the display for the layer on
   every Present, on this thread). */
static HRESULT present_frames(const struct options *o, struct gfx *g, struct result *r)
{
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT rect = {0, 0, WINDOW_WIDTH, WINDOW_HEIGHT};
    DXGI_SWAP_CHAIN_DESC desc = {0};
    WNDCLASSEXW wc = {0};
    IDXGIDevice *dxgi_device;
    IDXGIAdapter *adapter;
    IDXGIFactory *factory;
    ID3D11Texture2D *buffer;
    unsigned int i;
    HRESULT hr;

    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = L"WarzagD3D11PsoReject";
    if (!RegisterClassExW(&wc)) return HRESULT_FROM_WIN32(GetLastError());
    AdjustWindowRect(&rect, style, FALSE);
    g->hwnd = CreateWindowExW(0, wc.lpszClassName, L"Warzag D3D11 PSO reject test", style, CW_USEDEFAULT,
                              CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top, NULL, NULL, wc.hInstance,
                              NULL);
    if (!g->hwnd) return HRESULT_FROM_WIN32(GetLastError());
    ShowWindow(g->hwnd, SW_SHOW);
    pump_messages();

    if (FAILED(hr = ID3D11Device_QueryInterface(g->device, &IID_IDXGIDevice, (void **)&dxgi_device))) return hr;
    hr = IDXGIDevice_GetAdapter(dxgi_device, &adapter);
    IDXGIDevice_Release(dxgi_device);
    if (FAILED(hr)) return hr;
    hr = IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory, (void **)&factory);
    IDXGIAdapter_Release(adapter);
    if (FAILED(hr)) return hr;
    desc.BufferDesc.Width = WINDOW_WIDTH;
    desc.BufferDesc.Height = WINDOW_HEIGHT;
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 1;
    desc.OutputWindow = g->hwnd;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    hr = IDXGIFactory_CreateSwapChain(factory, (IUnknown *)g->device, &desc, &g->swapchain);
    IDXGIFactory_Release(factory);
    if (FAILED(hr)) return hr;
    if (FAILED(hr = IDXGISwapChain_GetBuffer(g->swapchain, 0, &IID_ID3D11Texture2D, (void **)&buffer))) return hr;
    hr = ID3D11Device_CreateRenderTargetView(g->device, (ID3D11Resource *)buffer, NULL, &g->back_rtv);
    ID3D11Texture2D_Release(buffer);
    if (FAILED(hr)) return hr;

    for (i = 0; i < o->frames; i++)
    {
        const float colour[4] = {(float)(i % 120) / 120.0f, 0.2f, 0.4f, 1.0f};

        pump_messages();
        ID3D11DeviceContext_ClearRenderTargetView(g->context, g->back_rtv, colour);
        if (FAILED(hr = IDXGISwapChain_Present(g->swapchain, 1, 0))) return hr;
        r->frames_done = i + 1;
    }
    /* DXMT pushes an autorelease pool for a debug name and pops it again: objc's pool high-water report
       (OBJC_PRINT_POOL_HIGHWATER) then counts what this thread's implicit pool holds. */
    hr = ID3D11RenderTargetView_SetPrivateData(g->back_rtv, &WKPDID_D3DDebugObjectName, 13, "wz-pool-probe");
    r->pool_probe = SUCCEEDED(hr);
    return hr;
}

static DWORD WINAPI exiting_thread(void *arg)
{
    (void)arg;
    return 0;
}

/* Wine signals an exiting thread's handle when it closes its server connection; its pthread TSD destructors, among
   them objc's pool drain, run after that. Every exiting Wine thread first joins the thread that exited before it
   (exit_thread()'s pthread_join), so once a new thread has exited, every earlier one has finished exiting. */
static BOOL reap_exited_threads(void)
{
    HANDLE thread = CreateThread(NULL, 0, exiting_thread, NULL, 0, NULL);
    DWORD wait;

    if (!thread) return FALSE;
    wait = WaitForSingleObject(thread, 30000);
    CloseHandle(thread);
    return wait == WAIT_OBJECT_0;
}

static void run(const struct options *o, struct gfx *g, struct result *r)
{
    static const D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    PFN_D3D11_CREATE_DEVICE create = NULL;
    pD3DCompile compile_fn = NULL;

    if (failed(r, "load", load_functions(&create, &compile_fn, r))) return;
    if (failed(r, "d3d11_create_device", create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &level, 1,
                                                 D3D11_SDK_VERSION, &g->device, NULL, &g->context)))
        return;
    r->d3d11_impl = implementation();
    if (o->frames && failed(r, "present", present_frames(o, g, r))) return;
    if (failed(r, "shaders", create_shaders(compile_fn, g, r))) return;
    if (failed(r, "render_target", create_target(g))) return;
    if (failed(r, "draw", draw_rejected(o, g, r))) return;
    failed(r, "draw_linked", draw_linked(g, r));
}

/* Releases everything, the device last, so DXMT destroys it and joins its pipeline workers; then makes sure those
   threads have finished exiting before the process does. */
static void teardown(struct gfx *g, struct result *r)
{
    if (g->context)
    {
        ID3D11DeviceContext_ClearState(g->context);
        ID3D11DeviceContext_Flush(g->context);
    }
    if (g->back_rtv) ID3D11RenderTargetView_Release(g->back_rtv);
    if (g->swapchain) IDXGISwapChain_Release(g->swapchain);
    if (g->rtv) ID3D11RenderTargetView_Release(g->rtv);
    if (g->staging) ID3D11Texture2D_Release(g->staging);
    if (g->target) ID3D11Texture2D_Release(g->target);
    if (g->vs) ID3D11VertexShader_Release(g->vs);
    if (g->ps) ID3D11PixelShader_Release(g->ps);
    if (g->ps_linked) ID3D11PixelShader_Release(g->ps_linked);
    if (g->context) ID3D11DeviceContext_Release(g->context);
    if (g->device)
    {
        ID3D11Device_Release(g->device);
        r->device_released = TRUE;
    }
    if (g->hwnd) DestroyWindow(g->hwnd);
    r->workers_reaped = reap_exited_threads();
    if (!r->workers_reaped && !r->stage) failed(r, "reap_threads", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
}

static void print_result(const struct options *o, const struct result *r, HANDLE out)
{
    struct jsonline j = {0};

    jl_bool(&j, "ok", !r->stage);
    if (r->stage)
    {
        jl_str(&j, "stage", r->stage);
        jl_hex(&j, "hresult", (unsigned long)r->hr, 8);
        if (r->compile_error[0]) jl_str(&j, "compile_error", r->compile_error);
    }
    if (r->compiler) jl_str(&j, "compiler", r->compiler);
    if (r->d3d11_impl) jl_str(&j, "d3d11_impl", r->d3d11_impl);
    jl_int(&j, "pipelines", o->pipelines);
    jl_int(&j, "pipelines_drawn", r->pipelines_drawn);
    if (r->have_pixel)
    {
        jl_hex(&j, "pixel", r->pixel, 8);
        /* the clear colour survived: Metal rejected the pipeline and DXMT dropped the draw */
        jl_bool(&j, "draw_dropped", r->pixel == CLEAR_PIXEL);
    }
    if (r->have_linked_pixel)
    {
        jl_hex(&j, "linked_pixel", r->linked_pixel, 8);
        /* the pipeline that links rendered the vertex shader's red */
        jl_bool(&j, "linked_drawn", r->linked_pixel == LINKED_PIXEL);
    }
    jl_int(&j, "frames", r->frames_done);
    if (o->frames) jl_bool(&j, "pool_probe", r->pool_probe);
    jl_bool(&j, "device_released", r->device_released);
    jl_bool(&j, "workers_reaped", r->workers_reaped);
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
        if (!value) return -1;
        if (!wcscmp(arg, L"--pipelines") && parse_uint(value, 1, MAX_PIPELINES, &o->pipelines)) i++;
        else if (!wcscmp(arg, L"--frames") && parse_uint(value, 0, MAX_FRAMES, &o->frames)) i++;
        else if (!wcscmp(arg, L"--out")) o->out = argv[++i];
        else return -1;
    }
    return 0;
}

int wmain(int argc, WCHAR **argv)
{
    struct options o = {.pipelines = 1};
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
    /* The point of the test is the teardown (the pipeline workers' exit), so the line comes after it; a process that
       dies there leaves no line, and qa/n/pso-reject.sh reports that. */
    teardown(&g, &r);
    print_result(&o, &r, out);
    if (out != INVALID_HANDLE_VALUE) CloseHandle(out);
    return r.stage ? 1 : 0;
}
