#import <Metal/Metal.h>

int okys_metal_queue_fence_wait(const void *queue_ptr) {
    @autoreleasepool {
        if (queue_ptr == 0) {
            return -1;
        }

        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)queue_ptr;
        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        if (command_buffer == nil) {
            return -2;
        }

        [command_buffer commit];
        [command_buffer waitUntilCompleted];
        return command_buffer.status == MTLCommandBufferStatusCompleted ? 0 : -3;
    }
}
