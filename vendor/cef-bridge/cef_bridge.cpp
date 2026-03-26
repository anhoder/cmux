// CEF bridge: OWL-style OSR architecture.
// Uses offscreen rendering with IOSurface delivery for compositor-safe rendering.

#include "cef_bridge.h"
#include <cstdlib>
#include <cstring>
#include <cstdio>

#ifdef CEF_BRIDGE_HAS_CEF

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_render_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

// -------------------------------------------------------------------
// BridgeClient: CefClient + all handlers including CefRenderHandler
// -------------------------------------------------------------------

struct BridgeBrowser;

class BridgeClient : public CefClient,
                     public CefRenderHandler,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefDisplayHandler,
                     public CefKeyboardHandler,
                     public CefFocusHandler,
                     public CefContextMenuHandler {
public:
    explicit BridgeClient(const cef_bridge_client_callbacks* cbs)
        : callbacks_(*cbs) {}

    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }

    // -- CefRenderHandler (OSR) --

    void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
        int w = 800, h = 600;
        if (callbacks_.on_get_view_rect) {
            callbacks_.on_get_view_rect(owner_, &w, &h, callbacks_.user_data);
        }
        rect.Set(0, 0, w, h);
    }

    bool GetScreenInfo(CefRefPtr<CefBrowser> browser,
                       CefScreenInfo& screen_info) override {
        float scale = 2.0f;
        if (callbacks_.on_get_screen_info) {
            callbacks_.on_get_screen_info(owner_, &scale, callbacks_.user_data);
        }
        screen_info.device_scale_factor = scale;
        return true;
    }

    void OnPaint(CefRefPtr<CefBrowser> browser,
                 PaintElementType type,
                 const RectList& dirtyRects,
                 const void* buffer,
                 int width, int height) override {
        static int paint_count = 0;
        if (++paint_count <= 3) {
            fprintf(stderr, "[CEF bridge] OnPaint type=%d %dx%d buffer=%p\n",
                    type, width, height, buffer);
            fflush(stderr);
        }
        if (type != PET_VIEW) return;
        if (callbacks_.on_paint) {
            callbacks_.on_paint(owner_, buffer, width, height, callbacks_.user_data);
        }
    }

    void OnAcceleratedPaint(CefRefPtr<CefBrowser> browser,
                            PaintElementType type,
                            const RectList& dirtyRects,
                            const CefAcceleratedPaintInfo& info) override {
        static int apaint_count = 0;
        if (++apaint_count <= 3) {
            fprintf(stderr, "[CEF bridge] OnAcceleratedPaint type=%d surface=%p\n",
                    type, info.shared_texture_io_surface);
            fflush(stderr);
        }
        if (type != PET_VIEW) return;
        if (callbacks_.on_accelerated_paint) {
            callbacks_.on_accelerated_paint(
                owner_,
                info.shared_texture_io_surface,
                0, 0,
                callbacks_.user_data
            );
        }
    }

    bool OnCursorChange(CefRefPtr<CefBrowser> browser,
                        CefCursorHandle cursor,
                        cef_cursor_type_t type,
                        const CefCursorInfo& custom_cursor_info) override {
        if (callbacks_.on_cursor_change) {
            callbacks_.on_cursor_change(owner_, static_cast<int>(type),
                                        callbacks_.user_data);
        }
        return false;
    }

    // -- CefDisplayHandler --

    void OnTitleChange(CefRefPtr<CefBrowser> browser,
                       const CefString& title) override {
        if (callbacks_.on_title_change) {
            std::string t = title.ToString();
            callbacks_.on_title_change(owner_, t.c_str(), callbacks_.user_data);
        }
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString& url) override {
        if (frame->IsMain() && callbacks_.on_url_change) {
            std::string u = url.ToString();
            callbacks_.on_url_change(owner_, u.c_str(), callbacks_.user_data);
        }
    }

    // -- CefLoadHandler --

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool isLoading, bool canGoBack,
                              bool canGoForward) override {
        if (callbacks_.on_loading_state_change) {
            callbacks_.on_loading_state_change(owner_, isLoading, canGoBack,
                                               canGoForward, callbacks_.user_data);
        }
    }

    // -- CefLifeSpanHandler --

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       int popup_id,
                       const CefString& target_url,
                       const CefString& target_frame_name,
                       WindowOpenDisposition target_disposition,
                       bool user_gesture,
                       const CefPopupFeatures& popupFeatures,
                       CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client,
                       CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info,
                       bool* no_javascript_access) override {
        if (callbacks_.on_popup_request) {
            std::string url = target_url.ToString();
            bool allow = callbacks_.on_popup_request(owner_, url.c_str(),
                                                      callbacks_.user_data);
            return !allow;
        }
        return true;
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        cef_browser_ = browser;
        fprintf(stderr, "[CEF bridge] OnAfterCreated (OSR)\n");
        fflush(stderr);
        // Kick rendering: tell CEF the view is visible and sized
        browser->GetHost()->WasResized();
        browser->GetHost()->SetFocus(true);
        browser->GetHost()->Invalidate(PET_VIEW);
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        cef_browser_ = nullptr;
    }

    // -- CefContextMenuHandler (OSR: suppress native menu) --

    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefContextMenuParams> params,
                             CefRefPtr<CefMenuModel> model) override {
        // Clear the default context menu. In OSR mode, CEF can't display
        // a native menu (no NSWindow). Clearing prevents a crash.
        model->Clear();
    }

    // -- CefKeyboardHandler --

    bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                       const CefKeyEvent& event,
                       CefEventHandle os_event,
                       bool* is_keyboard_shortcut) override {
        if (event.modifiers & EVENTFLAG_COMMAND_DOWN) {
            *is_keyboard_shortcut = true;
        }
        return false;
    }

    void SetOwner(cef_bridge_browser_t owner) { owner_ = owner; }
    CefRefPtr<CefBrowser> GetBrowser() { return cef_browser_; }

private:
    cef_bridge_client_callbacks callbacks_;
    cef_bridge_browser_t owner_ = nullptr;
    CefRefPtr<CefBrowser> cef_browser_;
    IMPLEMENT_REFCOUNTING(BridgeClient);
};

// -------------------------------------------------------------------
// BridgeApp
// -------------------------------------------------------------------

class BridgeApp : public CefApp,
                  public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }

    void OnBeforeCommandLineProcessing(
        const CefString& process_type,
        CefRefPtr<CefCommandLine> command_line) override {
        command_line->AppendSwitch("use-mock-keychain");
        // Single-process for now (helper subprocess crashes on CEF 146).
        // TODO: fix helper, remove --single-process for process isolation.
        command_line->AppendSwitch("single-process");
    }

private:
    IMPLEMENT_REFCOUNTING(BridgeApp);
};

struct BridgeBrowser {
    CefRefPtr<BridgeClient> client;
};

// -------------------------------------------------------------------
// Global state
// -------------------------------------------------------------------

static bool g_initialized = false;

static char* bridge_strdup(const char* s) {
    if (!s) return nullptr;
    size_t len = strlen(s) + 1;
    char* copy = static_cast<char*>(malloc(len));
    if (copy) memcpy(copy, s, len);
    return copy;
}

// -------------------------------------------------------------------
// Lifecycle
// -------------------------------------------------------------------

int cef_bridge_initialize(
    const char* framework_path,
    const char* helper_path,
    const char* cache_root
) {
    if (g_initialized) return CEF_BRIDGE_OK;
    if (!framework_path || !helper_path || !cache_root)
        return CEF_BRIDGE_ERR_INVALID;

    static CefScopedLibraryLoader library_loader;
    if (!library_loader.LoadInMain()) {
        fprintf(stderr, "[CEF bridge] LoadInMain failed\n");
        return CEF_BRIDGE_ERR_FAILED;
    }

    CefMainArgs main_args(0, nullptr);
    CefSettings settings;
    settings.no_sandbox = true;
    settings.external_message_pump = true;
    settings.multi_threaded_message_loop = false;
    settings.windowless_rendering_enabled = true;
    settings.persist_session_cookies = false;

    CefString(&settings.framework_dir_path) =
        std::string(framework_path) + "/Chromium Embedded Framework.framework";
    CefString(&settings.browser_subprocess_path) = helper_path;
    CefString(&settings.cache_path) = cache_root;

    CefRefPtr<BridgeApp> app(new BridgeApp());

    fprintf(stderr, "[CEF bridge] CefInitialize (OSR mode)...\n");
    fflush(stderr);

    if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
        fprintf(stderr, "[CEF bridge] CefInitialize FAILED\n");
        return CEF_BRIDGE_ERR_FAILED;
    }

    fprintf(stderr, "[CEF bridge] CefInitialize OK\n");
    g_initialized = true;
    return CEF_BRIDGE_OK;
}

void cef_bridge_do_message_loop_work(void) {
    if (!g_initialized) return;
    CefDoMessageLoopWork();
}

void cef_bridge_shutdown(void) {
    if (!g_initialized) return;
    CefShutdown();
    g_initialized = false;
}

bool cef_bridge_is_initialized(void) { return g_initialized; }

// -------------------------------------------------------------------
// Browser (OSR)
// -------------------------------------------------------------------

cef_bridge_browser_t cef_bridge_browser_create(
    const char* initial_url,
    int width, int height,
    const cef_bridge_client_callbacks* callbacks
) {
    if (!g_initialized || !callbacks) return nullptr;

    auto* bb = new BridgeBrowser();
    bb->client = new BridgeClient(callbacks);
    bb->client->SetOwner(bb);

    CefWindowInfo window_info;
    window_info.windowless_rendering_enabled = true;
    window_info.shared_texture_enabled = true;
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    window_info.bounds = {0, 0, width, height};

    CefBrowserSettings browser_settings;

    std::string url = initial_url ? initial_url : "about:blank";

    fprintf(stderr, "[CEF bridge] CreateBrowser OSR %dx%d url=%s\n",
            width, height, url.c_str());
    fflush(stderr);

    bool ok = CefBrowserHost::CreateBrowser(
        window_info, bb->client, url, browser_settings, nullptr, nullptr);

    fprintf(stderr, "[CEF bridge] CreateBrowser returned %d\n", ok);
    fflush(stderr);

    if (!ok) {
        delete bb;
        return nullptr;
    }
    return bb;
}

void cef_bridge_browser_destroy(cef_bridge_browser_t browser) {
    if (!browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (b) b->GetHost()->CloseBrowser(true);
    delete bb;
}

// -------------------------------------------------------------------
// Navigation
// -------------------------------------------------------------------

#define GET_BROWSER(browser) \
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT; \
    auto* bb = static_cast<BridgeBrowser*>(browser); \
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser(); \
    if (!b) return CEF_BRIDGE_ERR_FAILED;

int cef_bridge_browser_load_url(cef_bridge_browser_t browser, const char* url) {
    GET_BROWSER(browser);
    b->GetMainFrame()->LoadURL(url);
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_go_back(cef_bridge_browser_t browser) {
    GET_BROWSER(browser); b->GoBack(); return CEF_BRIDGE_OK;
}

int cef_bridge_browser_go_forward(cef_bridge_browser_t browser) {
    GET_BROWSER(browser); b->GoForward(); return CEF_BRIDGE_OK;
}

int cef_bridge_browser_reload(cef_bridge_browser_t browser) {
    GET_BROWSER(browser); b->Reload(); return CEF_BRIDGE_OK;
}

int cef_bridge_browser_stop(cef_bridge_browser_t browser) {
    GET_BROWSER(browser); b->StopLoad(); return CEF_BRIDGE_OK;
}

int cef_bridge_browser_set_zoom(cef_bridge_browser_t browser, double level) {
    GET_BROWSER(browser); b->GetHost()->SetZoomLevel(level); return CEF_BRIDGE_OK;
}

int cef_bridge_browser_execute_js(cef_bridge_browser_t browser, const char* script) {
    GET_BROWSER(browser);
    b->GetMainFrame()->ExecuteJavaScript(script, "", 0);
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_show_devtools(cef_bridge_browser_t browser) {
    GET_BROWSER(browser);
    CefWindowInfo wi;
    CefBrowserSettings bs;
    b->GetHost()->ShowDevTools(wi, nullptr, bs, CefPoint());
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_close_devtools(cef_bridge_browser_t browser) {
    GET_BROWSER(browser);
    b->GetHost()->CloseDevTools();
    return CEF_BRIDGE_OK;
}

void cef_bridge_browser_set_hidden(cef_bridge_browser_t browser, bool hidden) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (b) b->GetHost()->WasHidden(hidden);
}

void cef_bridge_browser_notify_resized(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (b) b->GetHost()->WasResized();
}

void cef_bridge_browser_invalidate(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (b) b->GetHost()->Invalidate(PET_VIEW);
}

int cef_bridge_browser_find(cef_bridge_browser_t browser, const char* text,
                             bool forward, bool case_sensitive) {
    GET_BROWSER(browser);
    b->GetHost()->Find(text, forward, !case_sensitive, false);
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_stop_finding(cef_bridge_browser_t browser) {
    GET_BROWSER(browser);
    b->GetHost()->StopFinding(true);
    return CEF_BRIDGE_OK;
}

// -------------------------------------------------------------------
// Input forwarding
// -------------------------------------------------------------------

void cef_bridge_browser_send_mouse_click(
    cef_bridge_browser_t browser,
    int x, int y, int button_type, bool mouse_up,
    int click_count, uint32_t modifiers
) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return;

    CefMouseEvent event;
    event.x = x;
    event.y = y;
    event.modifiers = modifiers;
    auto btn = static_cast<CefBrowserHost::MouseButtonType>(button_type);
    b->GetHost()->SendMouseClickEvent(event, btn, mouse_up, click_count);
}

void cef_bridge_browser_send_mouse_move(
    cef_bridge_browser_t browser,
    int x, int y, bool mouse_leave, uint32_t modifiers
) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return;

    CefMouseEvent event;
    event.x = x;
    event.y = y;
    event.modifiers = modifiers;
    b->GetHost()->SendMouseMoveEvent(event, mouse_leave);
}

void cef_bridge_browser_send_mouse_wheel(
    cef_bridge_browser_t browser,
    int x, int y, int delta_x, int delta_y, uint32_t modifiers
) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return;

    CefMouseEvent event;
    event.x = x;
    event.y = y;
    event.modifiers = modifiers;
    b->GetHost()->SendMouseWheelEvent(event, delta_x, delta_y);
}

void cef_bridge_browser_send_key_event(
    cef_bridge_browser_t browser,
    int event_type, int windows_key_code, int native_key_code,
    uint32_t modifiers, uint16_t character,
    uint16_t unmodified_character, bool is_system_key
) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return;

    CefKeyEvent event;
    event.type = static_cast<cef_key_event_type_t>(event_type);
    event.windows_key_code = windows_key_code;
    event.native_key_code = native_key_code;
    event.modifiers = modifiers;
    event.character = character;
    event.unmodified_character = unmodified_character;
    event.is_system_key = is_system_key;
    b->GetHost()->SendKeyEvent(event);
}

void cef_bridge_browser_send_focus(cef_bridge_browser_t browser, bool focus) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (b) b->GetHost()->SetFocus(focus);
}

// -------------------------------------------------------------------
// Utility
// -------------------------------------------------------------------

void cef_bridge_free_string(char* str) { free(str); }

char* cef_bridge_get_version(void) {
    return bridge_strdup("146.0.6-osr");
}

#else // Stubs

static char* bridge_strdup(const char* s) {
    if (!s) return nullptr;
    size_t len = strlen(s) + 1;
    char* copy = static_cast<char*>(malloc(len));
    if (copy) memcpy(copy, s, len);
    return copy;
}

int cef_bridge_initialize(const char* a, const char* b, const char* c) { return CEF_BRIDGE_ERR_NOT_INIT; }
void cef_bridge_do_message_loop_work(void) {}
void cef_bridge_shutdown(void) {}
bool cef_bridge_is_initialized(void) { return false; }

cef_bridge_browser_t cef_bridge_browser_create(const char* u, int w, int h, const cef_bridge_client_callbacks* c) { return nullptr; }
void cef_bridge_browser_destroy(cef_bridge_browser_t b) {}

int cef_bridge_browser_load_url(cef_bridge_browser_t b, const char* u) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_go_back(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_go_forward(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_reload(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_stop(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_set_zoom(cef_bridge_browser_t b, double l) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_execute_js(cef_bridge_browser_t b, const char* s) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_show_devtools(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_close_devtools(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
void cef_bridge_browser_set_hidden(cef_bridge_browser_t b, bool h) {}
void cef_bridge_browser_notify_resized(cef_bridge_browser_t b) {}
void cef_bridge_browser_invalidate(cef_bridge_browser_t b) {}
int cef_bridge_browser_find(cef_bridge_browser_t b, const char* t, bool f, bool c) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_stop_finding(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }

void cef_bridge_browser_send_mouse_click(cef_bridge_browser_t b, int x, int y, int bt, bool mu, int cc, uint32_t m) {}
void cef_bridge_browser_send_mouse_move(cef_bridge_browser_t b, int x, int y, bool ml, uint32_t m) {}
void cef_bridge_browser_send_mouse_wheel(cef_bridge_browser_t b, int x, int y, int dx, int dy, uint32_t m) {}
void cef_bridge_browser_send_key_event(cef_bridge_browser_t b, int et, int wk, int nk, uint32_t m, uint16_t c, uint16_t uc, bool sk) {}
void cef_bridge_browser_send_focus(cef_bridge_browser_t b, bool f) {}

void cef_bridge_free_string(char* s) { free(s); }
char* cef_bridge_get_version(void) { return bridge_strdup("0.0.0-stub"); }

#endif

// Debug: install signal handlers to log crashes
#include <signal.h>
#include <execinfo.h>
#include <unistd.h>

static void crash_handler(int sig) {
    void* bt[30];
    int count = backtrace(bt, 30);
    backtrace_symbols_fd(bt, count, STDERR_FILENO);
    _exit(128 + sig);
}

__attribute__((constructor))
static void install_crash_handlers(void) {
    signal(SIGSEGV, crash_handler);
    signal(SIGBUS, crash_handler);
    signal(SIGABRT, crash_handler);
}
