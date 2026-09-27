#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <cctype>

namespace fs = std::filesystem;
using namespace std::chrono_literals;

using InitFn = bool (*)(uint32_t, uint16_t, uint16_t, uint16_t, int, const char*);
using InitV2Fn = int (*)(uint32_t, uint16_t, uint16_t, int, const char*, const char*, void*);
using ShutdownFn = void (*)();
using RunCallbacksFn = void (*)();
using GetServerFn = void* (*)();
using LogOnAnonFn = void (*)(void*);
using LoggedOnFn = bool (*)(void*);
using GetUGCFn = void* (*)();
using ItemStateFn = uint32_t (*)(void*, uint64_t);
using DownloadItemFn = bool (*)(void*, uint64_t, bool);
using InstallInfoFn = bool (*)(void*, uint64_t, uint64_t*, char*, uint32_t, uint32_t*);
using DownloadInfoFn = bool (*)(void*, uint64_t, uint64_t*, uint64_t*);

template<typename T> static T get(void* h, const char* name) {
    return reinterpret_cast<T>(dlsym(h, name));
}

static bool copy_tree(const fs::path& src, const fs::path& dst) {
    std::error_code ec;
    fs::create_directories(dst, ec);
    if (ec) return false;
    for (const auto& e : fs::recursive_directory_iterator(
             src, fs::directory_options::skip_permission_denied, ec)) {
        if (ec) return false;
        auto rel = fs::relative(e.path(), src, ec);
        if (ec) return false;
        auto out = dst / rel;
        if (e.is_directory(ec)) {
            fs::create_directories(out, ec);
            if (ec) return false;
        } else if (e.is_regular_file(ec)) {
            fs::create_directories(out.parent_path(), ec);
            if (ec) return false;
            fs::copy_file(e.path(), out, fs::copy_options::overwrite_existing, ec);
            if (ec) return false;
        }
    }
    return true;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: steam-ugc-server <workshop_id> <output_dir>\n";
        return 2;
    }
    const uint64_t workshop = std::strtoull(argv[1], nullptr, 10);
    const fs::path output = fs::absolute(argv[2]);
    if (!workshop || !std::all_of(argv[1], argv[1] + std::strlen(argv[1]),
                                  [](unsigned char c) { return std::isdigit(c); })) {
        return 2;
    }
    fs::create_directories(output);

    void* lib = dlopen("libsteam_api.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        std::cerr << "steam_ugc: cannot load libsteam_api.so: " << dlerror() << "\n";
        return 3;
    }

    auto init = get<InitFn>(lib, "SteamInternal_GameServer_Init");
    auto initV2 = get<InitV2Fn>(lib, "SteamInternal_GameServer_Init_V2");
    auto shutdown = get<ShutdownFn>(lib, "SteamGameServer_Shutdown");
    auto callbacks = get<RunCallbacksFn>(lib, "SteamGameServer_RunCallbacks");
    auto server = get<GetServerFn>(lib, "SteamAPI_SteamGameServer_v014");
    if (!server) server = get<GetServerFn>(lib, "SteamAPI_SteamGameServer_v015");

    auto ugc = get<GetUGCFn>(lib, "SteamAPI_SteamGameServerUGC_v021");
    if (!ugc) ugc = get<GetUGCFn>(lib, "SteamAPI_SteamGameServerUGC_v020");
    if (!ugc) ugc = get<GetUGCFn>(lib, "SteamAPI_SteamGameServerUGC_v019");
    if (!ugc) ugc = get<GetUGCFn>(lib, "SteamAPI_SteamGameServerUGC_v018");
    if (!ugc) ugc = get<GetUGCFn>(lib, "SteamAPI_SteamGameServerUGC_v017");
    if (!ugc) ugc = get<GetUGCFn>(lib, "SteamAPI_SteamGameServerUGC_v016");

    if (!callbacks || !server || !ugc || (!init && !initV2)) {
        std::cerr << "steam_ugc: required Steam GameServer exports are missing\n";
        return 4;
    }

    fs::path runtime = fs::absolute(".");
    std::ofstream(runtime / "steam_appid.txt") << "431960\n";

    bool ok = false;
    if (init) {
        ok = init(0, 27015, 27016, 27017, 1, "1.0.0.0");
    } else {
        const char versions[] =
            "SteamUtils009\0SteamNetworkingUtils004\0SteamGameServer012\0"
            "SteamGameServerStats001\0STEAMHTTP_INTERFACE_VERSION003\0"
            "STEAMINVENTORY_INTERFACE_V003\0SteamNetworking006\0"
            "SteamNetworkingMessages002\0SteamNetworkingSockets012\0"
            "STEAMUGC_INTERFACE_VERSION021\0\0";
        ok = initV2(0, 27016, 27017, 1, "1.0.0.0", versions, nullptr) == 0;
    }
    if (!ok) {
        std::cerr << "steam_ugc: Steam GameServer initialization failed\n";
        return 5;
    }

    void* gs = server();
    auto logonAnon = get<LogOnAnonFn>(lib, "SteamAPI_ISteamGameServer_LogOnAnonymous");
    auto loggedOn = get<LoggedOnFn>(lib, "SteamAPI_ISteamGameServer_BLoggedOn");
    if (!gs || !logonAnon || !loggedOn) {
        std::cerr << "steam_ugc: GameServer login exports unavailable\n";
        if (shutdown) shutdown();
        return 6;
    }

    logonAnon(gs);
    for (int i = 0; i < 300 && !loggedOn(gs); ++i) {
        callbacks();
        std::this_thread::sleep_for(100ms);
    }
    if (!loggedOn(gs)) {
        std::cerr << "steam_ugc: anonymous game-server login failed\n";
        if (shutdown) shutdown();
        return 7;
    }

    void* u = ugc();
    auto state = get<ItemStateFn>(lib, "SteamAPI_ISteamUGC_GetItemState");
    auto download = get<DownloadItemFn>(lib, "SteamAPI_ISteamUGC_DownloadItem");
    auto install = get<InstallInfoFn>(lib, "SteamAPI_ISteamUGC_GetItemInstallInfo");
    auto info = get<DownloadInfoFn>(lib, "SteamAPI_ISteamUGC_GetItemDownloadInfo");
    if (!u || !state || !download || !install || !info) {
        std::cerr << "steam_ugc: UGC exports unavailable\n";
        if (shutdown) shutdown();
        return 8;
    }

    std::cerr << "steam_ugc: requesting anonymous Workshop download " << workshop << "\n";
    if (!download(u, workshop, true)) {
        std::cerr << "steam_ugc: DownloadItem returned false\n";
        if (shutdown) shutdown();
        return 9;
    }

    constexpr uint32_t INSTALLED = 4;
    for (int i = 0; i < 3600; ++i) {
        callbacks();

        uint64_t got = 0, total = 0;
        if (info(u, workshop, &got, &total) && total) {
            std::cerr << "steam_ugc: " << got << "/" << total << " bytes\r" << std::flush;
        }

        const uint32_t itemState = state(u, workshop);
        if (itemState & INSTALLED) {
            std::cerr << "\nsteam_ugc: Workshop item installed\n";
            char folder[4096]{};
            uint64_t size = 0;
            uint32_t timestamp = 0;
            if (!install(u, workshop, &size, folder, sizeof(folder), &timestamp) || !folder[0]) {
                std::cerr << "steam_ugc: GetItemInstallInfo failed\n";
                if (shutdown) shutdown();
                return 10;
            }

            std::cerr << "steam_ugc: source=" << folder << " size=" << size << "\n";
            const bool copied = copy_tree(folder, output);
            if (shutdown) shutdown();
            if (!copied) {
                std::cerr << "steam_ugc: failed to copy Workshop content\n";
                return 11;
            }
            return 0;
        }

        std::this_thread::sleep_for(500ms);
    }

    if (shutdown) shutdown();
    std::cerr << "\nsteam_ugc: Workshop download timed out\n";
    return 12;
}
