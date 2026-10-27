// Chromium sub-process entry point (renderer, GPU, network, plugin, alerts, and the code-sign
// clone cleanup). build-app.sh copies this one executable into each `Yardlet Helper (<kind>).app`.
// Like the main process it opens the CEF framework at run time; the macOS sandbox is entered first.
// In a renderer it also reports the page's focused password fields to the browser host (FocusedField.c).

#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include "include/cef_sandbox_mac.h"

#include "FocusedField.h"

static const char kFrameworkRelativePath[] =
    "../../../Chromium Embedded Framework.framework/Chromium Embedded Framework";
static const char kSandboxRelativePath[] =
    "../../../Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib";
static const char kFrameworkDirectoryRelativePath[] = "../../../Chromium Embedded Framework.framework";
static const char kHostBundleRelativePath[] = "../../../../..";

static void *open_library(const char *directory, const char *relative_path) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/%s", directory, relative_path);
    void *library = dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    if (library == NULL) fprintf(stderr, "Yardlet Helper: dlopen %s: %s\n", path, dlerror());
    return library;
}

// CEF gives the sub-processes it starts --framework-dir-path and --main-bundle-path. Chromium starts
// one more itself as the browser exits, the code-sign clone cleanup, which outlives the browser to
// delete its temporary clone of the bundle. Without the two switches CEF takes the outermost app in
// this executable's path, Yardlet.app, for the main bundle, finds no framework there and stops on a
// CHECK (SIGTRAP) before the cleanup runs. The browser host bundle holds the framework and helpers,
// so a missing switch gets the path CEF would have given.
static void add_path_switch(char *arguments[], int *count, const char *name, const char *directory,
                            const char *relative_path, char *storage, size_t capacity) {
    size_t length = strlen(name);
    for (int index = 1; index < *count; index++) {
        if (strncmp(arguments[index], name, length) == 0 && arguments[index][length] == '=') return;
    }
    char relative[PATH_MAX], resolved[PATH_MAX];
    snprintf(relative, sizeof(relative), "%s/%s", directory, relative_path);
    if (realpath(relative, resolved) == NULL) return;
    snprintf(storage, capacity, "%s=%s", name, resolved);
    arguments[(*count)++] = storage;
}

int main(int argc, char *argv[]) {
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return 1;
    char directory[PATH_MAX];
    strlcpy(directory, dirname(executable), sizeof(directory));

    char *arguments[argc + 3];
    for (int index = 0; index < argc; index++) arguments[index] = argv[index];
    int count = argc;
    static char framework_switch[PATH_MAX + 32], bundle_switch[PATH_MAX + 32];
    add_path_switch(arguments, &count, "--framework-dir-path", directory, kFrameworkDirectoryRelativePath,
                    framework_switch, sizeof(framework_switch));
    add_path_switch(arguments, &count, "--main-bundle-path", directory, kHostBundleRelativePath, bundle_switch,
                    sizeof(bundle_switch));
    arguments[count] = NULL;

    void *sandbox = open_library(directory, kSandboxRelativePath);
    if (sandbox == NULL) return 1;
    __typeof__(&cef_sandbox_initialize) sandbox_initialize =
        (__typeof__(&cef_sandbox_initialize))dlsym(sandbox, "cef_sandbox_initialize");
    __typeof__(&cef_sandbox_destroy) sandbox_destroy =
        (__typeof__(&cef_sandbox_destroy))dlsym(sandbox, "cef_sandbox_destroy");
    void *sandbox_context = sandbox_initialize ? sandbox_initialize(count, arguments) : NULL;
    if (sandbox_context == NULL) {
        fprintf(stderr, "Yardlet Helper: sandbox initialization failed\n");
        return 1;
    }

    void *framework = open_library(directory, kFrameworkRelativePath);
    if (framework == NULL) return 1;
    __typeof__(&cef_api_hash) api_hash = (__typeof__(&cef_api_hash))dlsym(framework, "cef_api_hash");
    __typeof__(&cef_execute_process) execute_process =
        (__typeof__(&cef_execute_process))dlsym(framework, "cef_execute_process");
    if (api_hash == NULL || execute_process == NULL) return 1;
    const char *hash = api_hash(CEF_API_VERSION, 0);
    if (hash == NULL || strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
        fprintf(stderr, "Yardlet Helper: CEF API hash mismatch\n");
        return 1;
    }

    cef_main_args_t main_arguments = {count, arguments};
    int exit_code = execute_process(&main_arguments, yardlet_helper_app(framework), NULL);
    if (sandbox_destroy) sandbox_destroy(sandbox_context);
    return exit_code;
}
