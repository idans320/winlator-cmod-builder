#include <windows.h>
#include <d3d9.h>
#include <stdio.h>

LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY)
        PostQuitMessage(0);
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrev, LPSTR lpCmdLine, int nCmdShow) {
    FILE *log = fopen("Z:\\test_recovery.log", "w");
    if (!log) log = fopen("test_recovery.log", "w");
    if (!log) return 1;

    WNDCLASSW wc = {0};
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = L"DXVKRecoveryTest";
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassW(&wc);

    HWND hWnd = CreateWindowW(L"DXVKRecoveryTest", L"DXVK Recovery Test",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
        640, 480, NULL, NULL, hInstance, NULL);

    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) {
        fprintf(log, "FATAL: Direct3DCreate9 returned NULL\n");
        fclose(log);
        return 1;
    }

    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = 640;
    pp.BackBufferHeight = 480;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;

    IDirect3DDevice9 *device = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d,
        D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hWnd,
        D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(hr)) {
        fprintf(log, "FATAL: CreateDevice failed 0x%lx\n", hr);
        IDirect3D9_Release(d3d);
        fclose(log);
        return 1;
    }

    ShowWindow(hWnd, SW_SHOW);

    int failures = 0;
    int total = 2000;

    fprintf(log, "DXVK_RECOVERY_TEST frames=%d\n", total);
    fflush(log);

    for (int i = 0; i < total; i++) {
        hr = IDirect3DDevice9_BeginScene(device);
        if (FAILED(hr)) {
            fprintf(log, "FATAL: BeginScene failed at frame %d: 0x%lx\n", i, hr);
            break;
        }
        hr = IDirect3DDevice9_Clear(device, 0, NULL,
            D3DCLEAR_TARGET, D3DCOLOR_XRGB(0, 100, 200), 1.0f, 0);
        if (FAILED(hr)) {
            fprintf(log, "FATAL: Clear failed at frame %d: 0x%lx\n", i, hr);
            break;
        }
        hr = IDirect3DDevice9_EndScene(device);
        if (FAILED(hr)) {
            fprintf(log, "FATAL: EndScene failed at frame %d: 0x%lx\n", i, hr);
            break;
        }
        hr = IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
        if (FAILED(hr)) {
            failures++;
            if (failures <= 5 || failures % 100 == 0)
                fprintf(log, "frame %d: Present FAILED 0x%lx (failures=%d)\n", i, hr, failures);
        } else if (i < 5 || i == 95 || i == 100 || i == 105 || i % 500 == 0) {
            fprintf(log, "frame %d: OK (failures=%d)\n", i, failures);
        }
        fflush(log);

        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) {
                i = total;
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    fprintf(log, "DXVK_RECOVERY_TEST done: failures=%d/%d\n", failures, total);
    fflush(log);

    IDirect3DDevice9_Release(device);
    IDirect3D9_Release(d3d);
    DestroyWindow(hWnd);
    fclose(log);
    return failures > 0 ? 1 : 0;
}
