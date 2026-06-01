#define VK_USE_PLATFORM_WAYLAND_KHR
#include "okys.h"

#include <stdbool.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_wayland.h>

#define OKY_VK_MAX_IMAGES 8
#define OKY_VK_FRAMES 2

typedef struct OkyVkFrame {
    const void *render_image;
    const void *render_view;
    const void *depth_stencil_image;
    const void *depth_stencil_view;
    const void *render_finished_semaphore;
    const void *present_complete_semaphore;
    uint32_t width;
    uint32_t height;
    uint32_t image_index;
} OkyVkFrame;

typedef struct OkyVkHost OkyVkHost;

static void *oky_vk_lib;
static PFN_vkGetInstanceProcAddr oky_vkGetInstanceProcAddr;
static PFN_vkGetDeviceProcAddr oky_vkGetDeviceProcAddr;
static PFN_vkCreateInstance oky_vkCreateInstance;
static PFN_vkDestroyInstance oky_vkDestroyInstance;
static PFN_vkCreateWaylandSurfaceKHR oky_vkCreateWaylandSurfaceKHR;
static PFN_vkDestroySurfaceKHR oky_vkDestroySurfaceKHR;
static PFN_vkEnumeratePhysicalDevices oky_vkEnumeratePhysicalDevices;
static PFN_vkGetPhysicalDeviceQueueFamilyProperties oky_vkGetPhysicalDeviceQueueFamilyProperties;
static PFN_vkGetPhysicalDeviceSurfaceSupportKHR oky_vkGetPhysicalDeviceSurfaceSupportKHR;
static PFN_vkGetPhysicalDeviceSurfaceFormatsKHR oky_vkGetPhysicalDeviceSurfaceFormatsKHR;
static PFN_vkGetPhysicalDeviceSurfacePresentModesKHR oky_vkGetPhysicalDeviceSurfacePresentModesKHR;
static PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR oky_vkGetPhysicalDeviceSurfaceCapabilitiesKHR;
static PFN_vkGetPhysicalDeviceMemoryProperties oky_vkGetPhysicalDeviceMemoryProperties;
static PFN_vkCreateDevice oky_vkCreateDevice;
static PFN_vkDestroyDevice oky_vkDestroyDevice;
static PFN_vkGetDeviceQueue oky_vkGetDeviceQueue;
static PFN_vkCreateSwapchainKHR oky_vkCreateSwapchainKHR;
static PFN_vkDestroySwapchainKHR oky_vkDestroySwapchainKHR;
static PFN_vkGetSwapchainImagesKHR oky_vkGetSwapchainImagesKHR;
static PFN_vkCreateImageView oky_vkCreateImageView;
static PFN_vkDestroyImageView oky_vkDestroyImageView;
static PFN_vkCreateImage oky_vkCreateImage;
static PFN_vkDestroyImage oky_vkDestroyImage;
static PFN_vkGetImageMemoryRequirements oky_vkGetImageMemoryRequirements;
static PFN_vkAllocateMemory oky_vkAllocateMemory;
static PFN_vkFreeMemory oky_vkFreeMemory;
static PFN_vkBindImageMemory oky_vkBindImageMemory;
static PFN_vkCreateSemaphore oky_vkCreateSemaphore;
static PFN_vkDestroySemaphore oky_vkDestroySemaphore;
static PFN_vkAcquireNextImageKHR oky_vkAcquireNextImageKHR;
static PFN_vkQueuePresentKHR oky_vkQueuePresentKHR;
static PFN_vkQueueWaitIdle oky_vkQueueWaitIdle;
static PFN_vkDeviceWaitIdle oky_vkDeviceWaitIdle;

#define vkAcquireNextImageKHR oky_vkAcquireNextImageKHR
#define vkAllocateMemory oky_vkAllocateMemory
#define vkBindImageMemory oky_vkBindImageMemory
#define vkCreateDevice oky_vkCreateDevice
#define vkCreateImage oky_vkCreateImage
#define vkCreateImageView oky_vkCreateImageView
#define vkCreateInstance oky_vkCreateInstance
#define vkCreateSemaphore oky_vkCreateSemaphore
#define vkCreateSwapchainKHR oky_vkCreateSwapchainKHR
#define vkCreateWaylandSurfaceKHR oky_vkCreateWaylandSurfaceKHR
#define vkDestroyDevice oky_vkDestroyDevice
#define vkDestroyImage oky_vkDestroyImage
#define vkDestroyImageView oky_vkDestroyImageView
#define vkDestroyInstance oky_vkDestroyInstance
#define vkDestroySemaphore oky_vkDestroySemaphore
#define vkDestroySurfaceKHR oky_vkDestroySurfaceKHR
#define vkDestroySwapchainKHR oky_vkDestroySwapchainKHR
#define vkDeviceWaitIdle oky_vkDeviceWaitIdle
#define vkEnumeratePhysicalDevices oky_vkEnumeratePhysicalDevices
#define vkFreeMemory oky_vkFreeMemory
#define vkGetDeviceQueue oky_vkGetDeviceQueue
#define vkGetImageMemoryRequirements oky_vkGetImageMemoryRequirements
#define vkGetPhysicalDeviceMemoryProperties oky_vkGetPhysicalDeviceMemoryProperties
#define vkGetPhysicalDeviceQueueFamilyProperties oky_vkGetPhysicalDeviceQueueFamilyProperties
#define vkGetPhysicalDeviceSurfaceCapabilitiesKHR oky_vkGetPhysicalDeviceSurfaceCapabilitiesKHR
#define vkGetPhysicalDeviceSurfaceFormatsKHR oky_vkGetPhysicalDeviceSurfaceFormatsKHR
#define vkGetPhysicalDeviceSurfacePresentModesKHR oky_vkGetPhysicalDeviceSurfacePresentModesKHR
#define vkGetPhysicalDeviceSurfaceSupportKHR oky_vkGetPhysicalDeviceSurfaceSupportKHR
#define vkGetSwapchainImagesKHR oky_vkGetSwapchainImagesKHR
#define vkQueuePresentKHR oky_vkQueuePresentKHR
#define vkQueueWaitIdle oky_vkQueueWaitIdle

struct OkyVkHost {
    VkInstance instance;
    VkSurfaceKHR surface;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue queue;
    uint32_t queue_family_index;

    VkSurfaceFormatKHR surface_format;
    VkPresentModeKHR present_mode;
    VkSwapchainKHR swapchain;
    VkExtent2D extent;
    VkImage images[OKY_VK_MAX_IMAGES];
    VkImageView image_views[OKY_VK_MAX_IMAGES];
    uint32_t image_count;

    VkFormat depth_format;
    VkImage depth_image;
    VkDeviceMemory depth_memory;
    VkImageView depth_view;

    VkSemaphore image_available[OKY_VK_FRAMES];
    VkSemaphore render_finished[OKY_VK_FRAMES];
    uint32_t frame_index;
    uint32_t current_image_index;
};

static void okyVkHostDestroy(OkyVkHost *host);

static bool vk_ok(VkResult result, const char *label) {
    if (result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR) {
        return true;
    }
    fprintf(stderr, "okys vulkan host: %s failed: %d\n", label, (int)result);
    return false;
}

static bool load_global_vulkan(void) {
    if (oky_vkCreateInstance) return true;
    oky_vk_lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!oky_vk_lib) {
        fprintf(stderr, "okys vulkan host: could not open libvulkan.so.1\n");
        return false;
    }
    oky_vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(oky_vk_lib, "vkGetInstanceProcAddr");
    if (!oky_vkGetInstanceProcAddr) return false;
    oky_vkCreateInstance = (PFN_vkCreateInstance)oky_vkGetInstanceProcAddr(NULL, "vkCreateInstance");
    return oky_vkCreateInstance != NULL;
}

static bool load_instance_vulkan(OkyVkHost *host) {
    #define LOAD_INSTANCE(name) do { oky_##name = (PFN_##name)oky_vkGetInstanceProcAddr(host->instance, #name); if (!oky_##name) return false; } while (0)
    LOAD_INSTANCE(vkDestroyInstance);
    LOAD_INSTANCE(vkCreateWaylandSurfaceKHR);
    LOAD_INSTANCE(vkDestroySurfaceKHR);
    LOAD_INSTANCE(vkEnumeratePhysicalDevices);
    LOAD_INSTANCE(vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD_INSTANCE(vkGetPhysicalDeviceSurfaceSupportKHR);
    LOAD_INSTANCE(vkGetPhysicalDeviceSurfaceFormatsKHR);
    LOAD_INSTANCE(vkGetPhysicalDeviceSurfacePresentModesKHR);
    LOAD_INSTANCE(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    LOAD_INSTANCE(vkGetPhysicalDeviceMemoryProperties);
    LOAD_INSTANCE(vkCreateDevice);
    oky_vkGetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)oky_vkGetInstanceProcAddr(host->instance, "vkGetDeviceProcAddr");
    return oky_vkGetDeviceProcAddr != NULL;
    #undef LOAD_INSTANCE
}

static bool load_device_vulkan(OkyVkHost *host) {
    #define LOAD_DEVICE(name) do { oky_##name = (PFN_##name)oky_vkGetDeviceProcAddr(host->device, #name); if (!oky_##name) return false; } while (0)
    LOAD_DEVICE(vkDestroyDevice);
    LOAD_DEVICE(vkGetDeviceQueue);
    LOAD_DEVICE(vkCreateSwapchainKHR);
    LOAD_DEVICE(vkDestroySwapchainKHR);
    LOAD_DEVICE(vkGetSwapchainImagesKHR);
    LOAD_DEVICE(vkCreateImageView);
    LOAD_DEVICE(vkDestroyImageView);
    LOAD_DEVICE(vkCreateImage);
    LOAD_DEVICE(vkDestroyImage);
    LOAD_DEVICE(vkGetImageMemoryRequirements);
    LOAD_DEVICE(vkAllocateMemory);
    LOAD_DEVICE(vkFreeMemory);
    LOAD_DEVICE(vkBindImageMemory);
    LOAD_DEVICE(vkCreateSemaphore);
    LOAD_DEVICE(vkDestroySemaphore);
    LOAD_DEVICE(vkAcquireNextImageKHR);
    LOAD_DEVICE(vkQueuePresentKHR);
    LOAD_DEVICE(vkQueueWaitIdle);
    LOAD_DEVICE(vkDeviceWaitIdle);
    return true;
    #undef LOAD_DEVICE
}

static uint32_t clamp_u32(uint32_t value, uint32_t lo, uint32_t hi) {
    if (value < lo) return lo;
    if (hi > 0 && value > hi) return hi;
    return value;
}

static uint32_t find_memory_type(OkyVkHost *host, uint32_t type_bits, VkMemoryPropertyFlags flags) {
    VkPhysicalDeviceMemoryProperties props;
    vkGetPhysicalDeviceMemoryProperties(host->physical_device, &props);
    for (uint32_t i = 0; i < props.memoryTypeCount; i++) {
        if ((type_bits & (1u << i)) && (props.memoryTypes[i].propertyFlags & flags) == flags) {
            return i;
        }
    }
    return UINT32_MAX;
}

static bool create_instance(OkyVkHost *host) {
    if (!load_global_vulkan()) return false;
    const char *extensions[] = {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
        VK_EXT_DEBUG_UTILS_EXTENSION_NAME,
    };
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "okys-host",
        .applicationVersion = VK_MAKE_VERSION(0, 1, 0),
        .pEngineName = "okys",
        .engineVersion = VK_MAKE_VERSION(0, 1, 0),
        .apiVersion = VK_API_VERSION_1_3,
    };
    VkInstanceCreateInfo desc = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
        .enabledExtensionCount = (uint32_t)(sizeof(extensions) / sizeof(extensions[0])),
        .ppEnabledExtensionNames = extensions,
    };
    if (!vk_ok(vkCreateInstance(&desc, NULL, &host->instance), "vkCreateInstance")) return false;
    return load_instance_vulkan(host);
}

static bool create_wayland_surface(OkyVkHost *host, void *wl_display, void *wl_surface) {
    VkWaylandSurfaceCreateInfoKHR desc = {
        .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .display = wl_display,
        .surface = wl_surface,
    };
    return vk_ok(vkCreateWaylandSurfaceKHR(host->instance, &desc, NULL, &host->surface), "vkCreateWaylandSurfaceKHR");
}

static bool pick_device(OkyVkHost *host) {
    uint32_t physical_count = 0;
    if (!vk_ok(vkEnumeratePhysicalDevices(host->instance, &physical_count, NULL), "vkEnumeratePhysicalDevices") || physical_count == 0) {
        return false;
    }
    VkPhysicalDevice devices[32];
    if (physical_count > 32) physical_count = 32;
    if (!vk_ok(vkEnumeratePhysicalDevices(host->instance, &physical_count, devices), "vkEnumeratePhysicalDevices")) {
        return false;
    }
    for (uint32_t i = 0; i < physical_count; i++) {
        uint32_t family_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &family_count, NULL);
        VkQueueFamilyProperties families[64];
        if (family_count > 64) family_count = 64;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &family_count, families);
        for (uint32_t family = 0; family < family_count; family++) {
            VkBool32 present = VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(devices[i], family, host->surface, &present);
            if ((families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
                host->physical_device = devices[i];
                host->queue_family_index = family;
                return true;
            }
        }
    }
    fprintf(stderr, "okys vulkan host: no graphics+present Vulkan queue family found\n");
    return false;
}

static bool create_device(OkyVkHost *host) {
    const char *extensions[] = {
        VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME,
    };
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_desc = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = host->queue_family_index,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkPhysicalDeviceVulkan13Features vk13 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .synchronization2 = VK_TRUE,
        .dynamicRendering = VK_TRUE,
    };
    VkPhysicalDeviceDescriptorBufferFeaturesEXT descriptor_buffer = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT,
        .pNext = &vk13,
        .descriptorBuffer = VK_TRUE,
    };
    VkDeviceCreateInfo desc = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &descriptor_buffer,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_desc,
        .enabledExtensionCount = (uint32_t)(sizeof(extensions) / sizeof(extensions[0])),
        .ppEnabledExtensionNames = extensions,
    };
    if (!vk_ok(vkCreateDevice(host->physical_device, &desc, NULL, &host->device), "vkCreateDevice")) {
        return false;
    }
    if (!load_device_vulkan(host)) return false;
    vkGetDeviceQueue(host->device, host->queue_family_index, 0, &host->queue);
    return host->queue != VK_NULL_HANDLE;
}

static VkSurfaceFormatKHR choose_surface_format(OkyVkHost *host) {
    uint32_t count = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(host->physical_device, host->surface, &count, NULL);
    VkSurfaceFormatKHR formats[64];
    if (count > 64) count = 64;
    vkGetPhysicalDeviceSurfaceFormatsKHR(host->physical_device, host->surface, &count, formats);
    for (uint32_t i = 0; i < count; i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) return formats[i];
    }
    for (uint32_t i = 0; i < count; i++) {
        if (formats[i].format == VK_FORMAT_R8G8B8A8_UNORM) return formats[i];
    }
    return count > 0 ? formats[0] : (VkSurfaceFormatKHR){ VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR };
}

static VkPresentModeKHR choose_present_mode(OkyVkHost *host) {
    uint32_t count = 0;
    vkGetPhysicalDeviceSurfacePresentModesKHR(host->physical_device, host->surface, &count, NULL);
    VkPresentModeKHR modes[16];
    if (count > 16) count = 16;
    vkGetPhysicalDeviceSurfacePresentModesKHR(host->physical_device, host->surface, &count, modes);
    for (uint32_t i = 0; i < count; i++) {
        if (modes[i] == VK_PRESENT_MODE_MAILBOX_KHR) return modes[i];
    }
    return VK_PRESENT_MODE_FIFO_KHR;
}

static VkExtent2D choose_extent(VkSurfaceCapabilitiesKHR caps, uint32_t width, uint32_t height) {
    if (caps.currentExtent.width != UINT32_MAX) {
        return caps.currentExtent;
    }
    VkExtent2D extent = {
        .width = clamp_u32(width, caps.minImageExtent.width, caps.maxImageExtent.width),
        .height = clamp_u32(height, caps.minImageExtent.height, caps.maxImageExtent.height),
    };
    return extent;
}

static void destroy_swapchain_resources(OkyVkHost *host) {
    if (!host || !host->device) return;
    if (host->depth_view) vkDestroyImageView(host->device, host->depth_view, NULL);
    if (host->depth_image) vkDestroyImage(host->device, host->depth_image, NULL);
    if (host->depth_memory) vkFreeMemory(host->device, host->depth_memory, NULL);
    host->depth_view = VK_NULL_HANDLE;
    host->depth_image = VK_NULL_HANDLE;
    host->depth_memory = VK_NULL_HANDLE;
    for (uint32_t i = 0; i < host->image_count; i++) {
        if (host->image_views[i]) vkDestroyImageView(host->device, host->image_views[i], NULL);
        host->image_views[i] = VK_NULL_HANDLE;
        host->images[i] = VK_NULL_HANDLE;
    }
    host->image_count = 0;
    if (host->swapchain) vkDestroySwapchainKHR(host->device, host->swapchain, NULL);
    host->swapchain = VK_NULL_HANDLE;
}

static bool create_depth_target(OkyVkHost *host) {
    host->depth_format = VK_FORMAT_D32_SFLOAT_S8_UINT;
    VkImageCreateInfo image_desc = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = host->depth_format,
        .extent = { host->extent.width, host->extent.height, 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (!vk_ok(vkCreateImage(host->device, &image_desc, NULL, &host->depth_image), "vkCreateImage(depth)")) return false;
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(host->device, host->depth_image, &req);
    uint32_t memory_type = find_memory_type(host, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (memory_type == UINT32_MAX) return false;
    VkMemoryAllocateInfo alloc = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = memory_type,
    };
    if (!vk_ok(vkAllocateMemory(host->device, &alloc, NULL, &host->depth_memory), "vkAllocateMemory(depth)")) return false;
    if (!vk_ok(vkBindImageMemory(host->device, host->depth_image, host->depth_memory, 0), "vkBindImageMemory(depth)")) return false;
    VkImageViewCreateInfo view_desc = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = host->depth_image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = host->depth_format,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    return vk_ok(vkCreateImageView(host->device, &view_desc, NULL, &host->depth_view), "vkCreateImageView(depth)");
}

static bool create_swapchain(OkyVkHost *host, uint32_t width, uint32_t height) {
    VkSurfaceCapabilitiesKHR caps;
    if (!vk_ok(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(host->physical_device, host->surface, &caps), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")) {
        return false;
    }
    host->surface_format = choose_surface_format(host);
    host->present_mode = choose_present_mode(host);
    host->extent = choose_extent(caps, width, height);
    uint32_t min_images = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && min_images > caps.maxImageCount) min_images = caps.maxImageCount;
    if (min_images > OKY_VK_MAX_IMAGES) min_images = OKY_VK_MAX_IMAGES;
    VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if ((caps.supportedCompositeAlpha & alpha) == 0) {
        alpha = (VkCompositeAlphaFlagBitsKHR)(caps.supportedCompositeAlpha & -caps.supportedCompositeAlpha);
    }
    VkSwapchainCreateInfoKHR desc = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = host->surface,
        .minImageCount = min_images,
        .imageFormat = host->surface_format.format,
        .imageColorSpace = host->surface_format.colorSpace,
        .imageExtent = host->extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = alpha,
        .presentMode = host->present_mode,
        .clipped = VK_TRUE,
        .oldSwapchain = VK_NULL_HANDLE,
    };
    if (!vk_ok(vkCreateSwapchainKHR(host->device, &desc, NULL, &host->swapchain), "vkCreateSwapchainKHR")) return false;
    uint32_t image_count = OKY_VK_MAX_IMAGES;
    if (!vk_ok(vkGetSwapchainImagesKHR(host->device, host->swapchain, &image_count, host->images), "vkGetSwapchainImagesKHR")) return false;
    host->image_count = image_count;
    for (uint32_t i = 0; i < host->image_count; i++) {
        VkImageViewCreateInfo view_desc = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = host->images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = host->surface_format.format,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        if (!vk_ok(vkCreateImageView(host->device, &view_desc, NULL, &host->image_views[i]), "vkCreateImageView(color)")) return false;
    }
    return create_depth_target(host);
}

static bool create_semaphores(OkyVkHost *host) {
    VkSemaphoreCreateInfo desc = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    for (uint32_t i = 0; i < OKY_VK_FRAMES; i++) {
        if (!vk_ok(vkCreateSemaphore(host->device, &desc, NULL, &host->image_available[i]), "vkCreateSemaphore(image_available)")) return false;
        if (!vk_ok(vkCreateSemaphore(host->device, &desc, NULL, &host->render_finished[i]), "vkCreateSemaphore(render_finished)")) return false;
    }
    return true;
}

static OkyVkHost *okyVkHostCreateWayland(void *wl_display, void *wl_surface, uint32_t width, uint32_t height) {
    OkyVkHost *host = calloc(1, sizeof(OkyVkHost));
    if (!host) return NULL;
    if (!create_instance(host) ||
        !create_wayland_surface(host, wl_display, wl_surface) ||
        !pick_device(host) ||
        !create_device(host) ||
        !create_swapchain(host, width, height) ||
        !create_semaphores(host)) {
        okyVkHostDestroy(host);
        return NULL;
    }
    return host;
}

static void okyVkHostDestroy(OkyVkHost *host) {
    if (!host) return;
    if (host->device) vkDeviceWaitIdle(host->device);
    destroy_swapchain_resources(host);
    for (uint32_t i = 0; i < OKY_VK_FRAMES; i++) {
        if (host->image_available[i]) vkDestroySemaphore(host->device, host->image_available[i], NULL);
        if (host->render_finished[i]) vkDestroySemaphore(host->device, host->render_finished[i], NULL);
    }
    if (host->device) vkDestroyDevice(host->device, NULL);
    if (host->surface) vkDestroySurfaceKHR(host->instance, host->surface, NULL);
    if (host->instance) vkDestroyInstance(host->instance, NULL);
    free(host);
}

static int okyVkHostResize(OkyVkHost *host, uint32_t width, uint32_t height) {
    if (!host || width == 0 || height == 0) return 0;
    if (host->extent.width == width && host->extent.height == height) return 1;
    vkDeviceWaitIdle(host->device);
    destroy_swapchain_resources(host);
    return create_swapchain(host, width, height) ? 1 : 0;
}

static int okyVkHostBeginFrame(OkyVkHost *host, OkyVkFrame *frame) {
    if (!host || !frame || !host->swapchain) return 0;
    memset(frame, 0, sizeof(*frame));
    uint32_t slot = host->frame_index % OKY_VK_FRAMES;
    VkResult result = vkAcquireNextImageKHR(
        host->device,
        host->swapchain,
        UINT64_MAX,
        host->image_available[slot],
        VK_NULL_HANDLE,
        &host->current_image_index
    );
    if (result == VK_ERROR_OUT_OF_DATE_KHR) {
        return 0;
    }
    if (!vk_ok(result, "vkAcquireNextImageKHR")) return 0;
    frame->render_image = host->images[host->current_image_index];
    frame->render_view = host->image_views[host->current_image_index];
    frame->depth_stencil_image = host->depth_image;
    frame->depth_stencil_view = host->depth_view;
    frame->present_complete_semaphore = host->image_available[slot];
    frame->render_finished_semaphore = host->render_finished[slot];
    frame->width = host->extent.width;
    frame->height = host->extent.height;
    frame->image_index = host->current_image_index;
    return 1;
}

static int okyVkHostPresent(OkyVkHost *host, const OkyVkFrame *frame) {
    if (!host || !frame || !host->swapchain) return 0;
    VkSemaphore wait = (VkSemaphore)frame->render_finished_semaphore;
    VkSwapchainKHR swapchain = host->swapchain;
    uint32_t image_index = frame->image_index;
    VkPresentInfoKHR desc = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &wait,
        .swapchainCount = 1,
        .pSwapchains = &swapchain,
        .pImageIndices = &image_index,
    };
    VkResult result = vkQueuePresentKHR(host->queue, &desc);
    vkQueueWaitIdle(host->queue);
    host->frame_index = (host->frame_index + 1) % OKY_VK_FRAMES;
    return (result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR) ? 1 : 0;
}

static const void *okyVkHostInstance(OkyVkHost *host) { return host ? host->instance : NULL; }
static const void *okyVkHostPhysicalDevice(OkyVkHost *host) { return host ? host->physical_device : NULL; }
static const void *okyVkHostDevice(OkyVkHost *host) { return host ? host->device : NULL; }
static const void *okyVkHostQueue(OkyVkHost *host) { return host ? host->queue : NULL; }
static uint32_t okyVkHostQueueFamilyIndex(OkyVkHost *host) { return host ? host->queue_family_index : 0; }

static int okyVkHostColorFormatCode(OkyVkHost *host) {
    if (!host) return 0;
    switch (host->surface_format.format) {
        case VK_FORMAT_B8G8R8A8_UNORM: return 1;
        case VK_FORMAT_R8G8B8A8_UNORM: return 2;
        default: return 0;
    }
}

OKYplatformHost *okyPlatformHostCreateWayland(void *wl_display, void *wl_surface, uint32_t width, uint32_t height) {
    return (OKYplatformHost *)okyVkHostCreateWayland(wl_display, wl_surface, width, height);
}

void okyPlatformHostDestroy(OKYplatformHost *host) {
    okyVkHostDestroy((OkyVkHost *)host);
}

int okyPlatformHostResize(OKYplatformHost *host, uint32_t width, uint32_t height) {
    return okyVkHostResize((OkyVkHost *)host, width, height);
}

int okyPlatformHostBeginFrame(OKYplatformHost *host, OKYplatformFrame *frame) {
    return okyVkHostBeginFrame((OkyVkHost *)host, (OkyVkFrame *)frame);
}

int okyPlatformHostPresent(OKYplatformHost *host, const OKYplatformFrame *frame) {
    return okyVkHostPresent((OkyVkHost *)host, (const OkyVkFrame *)frame);
}

const void *okyPlatformHostVulkanInstance(OKYplatformHost *host) {
    return okyVkHostInstance((OkyVkHost *)host);
}

const void *okyPlatformHostVulkanPhysicalDevice(OKYplatformHost *host) {
    return okyVkHostPhysicalDevice((OkyVkHost *)host);
}

const void *okyPlatformHostVulkanDevice(OKYplatformHost *host) {
    return okyVkHostDevice((OkyVkHost *)host);
}

const void *okyPlatformHostVulkanQueue(OKYplatformHost *host) {
    return okyVkHostQueue((OkyVkHost *)host);
}

uint32_t okyPlatformHostVulkanQueueFamilyIndex(OKYplatformHost *host) {
    return okyVkHostQueueFamilyIndex((OkyVkHost *)host);
}

int okyPlatformHostColorFormatCode(OKYplatformHost *host) {
    return okyVkHostColorFormatCode((OkyVkHost *)host);
}
