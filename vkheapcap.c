/* Vulkan implicit layer: cap the size reported for host-visible (non
 * device-local) memory heaps. World Creator's HighVRamMode pre-allocates a
 * host pool sized to this heap (~47 GB of system RAM on NVIDIA), exhausting
 * memory under wine. The NVIDIA driver reports the heap size, so it can't be
 * capped from libc; this layer rewrites vkGetPhysicalDeviceMemoryProperties.
 * Enable with WC_HEAPCAP_ENABLE=1; size via VKHEAPCAP_GB (default 8).
 */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

static void lg(const char *fmt, ...) {
    if (!getenv("VKHEAPCAP_LOG")) return;
    FILE *f = fopen("/tmp/vkheapcap.log", "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fclose(f);
}

static PFN_vkGetInstanceProcAddr                  g_next_gipa   = 0;
static PFN_vkGetPhysicalDeviceMemoryProperties    g_next_gpdmp  = 0;
static PFN_vkGetPhysicalDeviceMemoryProperties2   g_next_gpdmp2 = 0;

static VkDeviceSize cap_bytes(void) {
    const char *e = getenv("VKHEAPCAP_GB");
    unsigned long long gb = e ? strtoull(e, 0, 10) : 8;
    if (!gb) gb = 8;
    return (VkDeviceSize)gb * 1024ULL * 1024ULL * 1024ULL;
}

static void cap_props(VkPhysicalDeviceMemoryProperties *p) {
    VkDeviceSize cap = cap_bytes();
    /* Cap device-local (VRAM) heaps too: HighVRamMode sizes a host-side mirror
     * to the VRAM heap, so leaving it uncapped lets the pool reach ~VRAM size.
     * VKHEAPCAP_VRAM_GB caps the device-local heaps; falls back to VKHEAPCAP_GB. */
    const char *ve = getenv("VKHEAPCAP_VRAM_GB");
    VkDeviceSize vcap = ve ? (VkDeviceSize)strtoull(ve, 0, 10) * 1024ULL * 1024ULL * 1024ULL : cap;
    if (vcap == 0) vcap = cap;
    for (uint32_t i = 0; i < p->memoryHeapCount; i++) {
        int devlocal = (p->memoryHeaps[i].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0;
        VkDeviceSize c = devlocal ? vcap : cap;
        lg("heap %u flags=%u size=%lluMB devlocal=%d cap=%lluMB\n", i, p->memoryHeaps[i].flags,
           (unsigned long long)(p->memoryHeaps[i].size >> 20), devlocal, (unsigned long long)(c >> 20));
        if (p->memoryHeaps[i].size > c) {
            p->memoryHeaps[i].size = c;
            lg("  -> capped heap %u to %lluMB\n", i, (unsigned long long)(c >> 20));
        }
    }
}

/* Cap the budget extension too: some apps size to heapBudget, not heap size. */
static void cap_budget(const VkPhysicalDeviceMemoryProperties *p, void *pNextChain) {
    VkDeviceSize cap = cap_bytes();
    const char *ve = getenv("VKHEAPCAP_VRAM_GB");
    VkDeviceSize vcap = ve ? (VkDeviceSize)strtoull(ve, 0, 10) * 1024ULL * 1024ULL * 1024ULL : cap;
    if (vcap == 0) vcap = cap;
    VkBaseOutStructure *s = (VkBaseOutStructure *)pNextChain;
    while (s) {
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT) {
            VkPhysicalDeviceMemoryBudgetPropertiesEXT *b = (VkPhysicalDeviceMemoryBudgetPropertiesEXT *)s;
            for (uint32_t i = 0; i < p->memoryHeapCount; i++) {
                VkDeviceSize c = (p->memoryHeaps[i].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) ? vcap : cap;
                lg("budget heap %u = %lluMB cap=%lluMB\n", i,
                   (unsigned long long)(b->heapBudget[i] >> 20), (unsigned long long)(c >> 20));
                if (b->heapBudget[i] > c) b->heapBudget[i] = c;
            }
        }
        s = s->pNext;
    }
}

static VKAPI_ATTR void VKAPI_CALL my_gpdmp(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties *props) {
    lg("== vkGetPhysicalDeviceMemoryProperties called ==\n");
    g_next_gpdmp(pd, props);
    cap_props(props);
}
static VKAPI_ATTR void VKAPI_CALL my_gpdmp2(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties2 *props) {
    lg("== vkGetPhysicalDeviceMemoryProperties2 called ==\n");
    g_next_gpdmp2(pd, props);
    cap_props(&props->memoryProperties);
    cap_budget(&props->memoryProperties, props->pNext);
}

static VKAPI_ATTR VkResult VKAPI_CALL my_CreateInstance(
        const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *alloc, VkInstance *inst) {
    VkLayerInstanceCreateInfo *lci = (VkLayerInstanceCreateInfo *)ci->pNext;
    while (lci && !(lci->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO
                    && lci->function == VK_LAYER_LINK_INFO))
        lci = (VkLayerInstanceCreateInfo *)lci->pNext;
    if (!lci) return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr next_gipa = lci->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    lci->u.pLayerInfo = lci->u.pLayerInfo->pNext;   /* advance the chain for the next layer */

    PFN_vkCreateInstance next_create = (PFN_vkCreateInstance)next_gipa(NULL, "vkCreateInstance");
    VkResult r = next_create(ci, alloc, inst);
    if (r != VK_SUCCESS) return r;

    g_next_gipa   = next_gipa;
    g_next_gpdmp  = (PFN_vkGetPhysicalDeviceMemoryProperties)next_gipa(*inst, "vkGetPhysicalDeviceMemoryProperties");
    g_next_gpdmp2 = (PFN_vkGetPhysicalDeviceMemoryProperties2)next_gipa(*inst, "vkGetPhysicalDeviceMemoryProperties2");
    if (!g_next_gpdmp2)
        g_next_gpdmp2 = (PFN_vkGetPhysicalDeviceMemoryProperties2)next_gipa(*inst, "vkGetPhysicalDeviceMemoryProperties2KHR");
    return VK_SUCCESS;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL VK_LAYER_WC_heapcap_GetInstanceProcAddr(VkInstance inst, const char *name) {
    if (!strcmp(name, "vkGetInstanceProcAddr"))                  return (PFN_vkVoidFunction)VK_LAYER_WC_heapcap_GetInstanceProcAddr;
    if (!strcmp(name, "vkCreateInstance"))                       return (PFN_vkVoidFunction)my_CreateInstance;
    if (!strcmp(name, "vkGetPhysicalDeviceMemoryProperties"))    return (PFN_vkVoidFunction)my_gpdmp;
    if (!strcmp(name, "vkGetPhysicalDeviceMemoryProperties2"))   return (PFN_vkVoidFunction)my_gpdmp2;
    if (!strcmp(name, "vkGetPhysicalDeviceMemoryProperties2KHR"))return (PFN_vkVoidFunction)my_gpdmp2;
    if (g_next_gipa) return g_next_gipa(inst, name);
    return 0;
}

VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *v) {
    if (v->loaderLayerInterfaceVersion > 2) v->loaderLayerInterfaceVersion = 2;
    v->pfnGetInstanceProcAddr       = VK_LAYER_WC_heapcap_GetInstanceProcAddr;
    v->pfnGetDeviceProcAddr         = 0;
    v->pfnGetPhysicalDeviceProcAddr = 0;
    return VK_SUCCESS;
}
