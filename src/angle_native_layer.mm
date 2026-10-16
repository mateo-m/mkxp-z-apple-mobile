#include <TargetConditionals.h>
#import <Metal/Metal.h>

// ANGLE's GL_MAX_TEXTURE_SIZE can exceed the actual Metal device limit
// (e.g. ANGLE reports 16384 on simulator where Metal only supports 8192).
// Query the real limit by checking Metal GPU family support.
extern "C" int mkxp_getMetalMaxTextureSize(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return 4096;

#if TARGET_OS_SIMULATOR
    // Simulator Metal devices have stricter limits than the host GPU.
    // The GPU family checks report the host Mac's capabilities, not
    // the simulated device's. Hardcode the known simulator limit.
    return 8192;
#else
    // Real devices: use GPU family to determine the documented limit.
    // Apple3+ (A9 and later): 16384
    // Apple2 (A8): 8192
    // Apple1 (A7): 4096
    if ([device supportsFamily:MTLGPUFamilyApple3])
        return 16384;
    if ([device supportsFamily:MTLGPUFamilyApple2])
        return 8192;
    return 4096;
#endif
}
