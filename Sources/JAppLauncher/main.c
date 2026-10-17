// The main executable of "JApp Runtime.app" and of every per-app bundle that
// JApp Runtime generates (see AppBundle.swift).
//
// macOS takes an app's name in the menu bar, Dock, ⌘-Tab, notifications and
// Activity Monitor from the bundle of its main executable. So each JApp gets a
// tiny bundle of its own whose executable is a copy of this launcher, and the
// launcher loads the one shared runtime library from JApp Runtime.app. App
// bundles therefore never contain runtime code and pick up runtime updates
// without being rebuilt.
//
// The library is looked up, in order:
//   1. ../Frameworks/ next to this executable  (JApp Runtime.app itself)
//   2. next to this executable                 (a development build in .build/)
//   3. the app bundle's JAppRuntimePath        (where JApp Runtime was when the bundle was made)
//   4. Launch Services, by bundle identifier   (JApp Runtime was moved)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LIBRARY_NAME "libJAppRuntimeCore.dylib"
#define RUNTIME_BUNDLE_ID "dev.japp.runtime"

typedef int (*RuntimeMain)(int argc, char **argv);

static void *load(const char *path) {
    if (access(path, R_OK) != 0) return NULL;
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) fprintf(stderr, "JApp: %s\n", dlerror());
    return handle;
}

static void *loadFromRuntimeApp(const char *app) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/Contents/Frameworks/" LIBRARY_NAME, app) >= (int)sizeof path) return NULL;
    return load(path);
}

static void *loadFromInfoPlist(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFTypeRef value = bundle ? CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("JAppRuntimePath")) : NULL;
    char app[PATH_MAX];
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()
        || !CFStringGetFileSystemRepresentation((CFStringRef)value, app, sizeof app)) return NULL;
    return loadFromRuntimeApp(app);
}

static void *loadFromLaunchServices(void) {
    CFArrayRef apps = LSCopyApplicationURLsForBundleIdentifier(CFSTR(RUNTIME_BUNDLE_ID), NULL);
    if (apps == NULL) return NULL;
    void *handle = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(apps) && handle == NULL; i++) {
        char app[PATH_MAX];
        if (CFURLGetFileSystemRepresentation((CFURLRef)CFArrayGetValueAtIndex(apps, i), true, (UInt8 *)app, sizeof app)) {
            handle = loadFromRuntimeApp(app);
        }
    }
    CFRelease(apps);
    return handle;
}

static void reportMissingRuntime(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFTypeRef name = bundle ? CFBundleGetValueForInfoDictionaryKey(bundle, kCFBundleNameKey) : NULL;
    CFStringRef message = CFStringCreateWithFormat(NULL, NULL,
        CFSTR("“%@” is a JApp and runs on JApp Runtime, which was not found on this Mac. Install JApp Runtime, then open the app again."),
        name && CFGetTypeID(name) == CFStringGetTypeID() ? (CFStringRef)name : CFSTR("This app"));
    CFOptionFlags response;
    CFUserNotificationDisplayAlert(0, kCFUserNotificationStopAlertLevel, NULL, NULL, NULL,
                                   CFSTR("JApp Runtime is missing"), message, CFSTR("OK"), NULL, NULL, &response);
    CFRelease(message);
}

int main(int argc, char **argv) {
    char raw[PATH_MAX], executable[PATH_MAX], directory[PATH_MAX];
    uint32_t size = sizeof raw;
    void *handle = NULL;
    if (_NSGetExecutablePath(raw, &size) == 0 && realpath(raw, executable) != NULL) {
        strlcpy(directory, executable, sizeof directory);
        char *slash = strrchr(directory, '/');
        if (slash != NULL) *slash = '\0';
        char path[PATH_MAX];
        if (snprintf(path, sizeof path, "%s/../Frameworks/" LIBRARY_NAME, directory) < (int)sizeof path) handle = load(path);
        if (handle == NULL && snprintf(path, sizeof path, "%s/" LIBRARY_NAME, directory) < (int)sizeof path) handle = load(path);
    }
    if (handle == NULL) handle = loadFromInfoPlist();
    if (handle == NULL) handle = loadFromLaunchServices();

    RuntimeMain runtimeMain = handle ? (RuntimeMain)dlsym(handle, "JAppRuntimeMain") : NULL;
    if (runtimeMain == NULL) {
        fprintf(stderr, "JApp: could not load " LIBRARY_NAME " from JApp Runtime.app\n");
        reportMissingRuntime();
        return 1;
    }
    return runtimeMain(argc, argv);
}
