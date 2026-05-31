//! Internal diagnostic counters for ignored or malformed caller input. These
//! stay behind the C ABI until the public error-reporting shape is deliberate.

pub const DiagnosticKind = enum {
    invalid_image_id,
    invalid_image_data,
    out_of_range_image_rect,
    out_of_range_path_slice,
    unbalanced_restore,
    malformed_command_stream,
};

pub const Diagnostics = struct {
    invalid_image_id: u32 = 0,
    invalid_image_data: u32 = 0,
    out_of_range_image_rect: u32 = 0,
    out_of_range_path_slice: u32 = 0,
    unbalanced_restore: u32 = 0,
    malformed_command_stream: u32 = 0,

    pub fn record(self: *Diagnostics, kind: DiagnosticKind) void {
        switch (kind) {
            .invalid_image_id => self.invalid_image_id += 1,
            .invalid_image_data => self.invalid_image_data += 1,
            .out_of_range_image_rect => self.out_of_range_image_rect += 1,
            .out_of_range_path_slice => self.out_of_range_path_slice += 1,
            .unbalanced_restore => self.unbalanced_restore += 1,
            .malformed_command_stream => self.malformed_command_stream += 1,
        }
    }

    pub fn count(self: Diagnostics, kind: DiagnosticKind) u32 {
        return switch (kind) {
            .invalid_image_id => self.invalid_image_id,
            .invalid_image_data => self.invalid_image_data,
            .out_of_range_image_rect => self.out_of_range_image_rect,
            .out_of_range_path_slice => self.out_of_range_path_slice,
            .unbalanced_restore => self.unbalanced_restore,
            .malformed_command_stream => self.malformed_command_stream,
        };
    }
};
