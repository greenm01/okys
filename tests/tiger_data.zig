const std = @import("std");
const testing = std.testing;

const tiger_data = @import("tiger_data");

test "Tiger benchmark data stream stays valid" {
    try testing.expectEqual(tiger_data.expected_command_count, tiger_data.commands.len);
    try testing.expectEqual(tiger_data.expected_point_count, tiger_data.points.len);

    var command_index: usize = 0;
    var point_index: usize = 0;
    var path_count: usize = 0;
    var fill_count: usize = 0;
    var even_odd_fill_count: usize = 0;
    var stroke_count: usize = 0;
    var move_count: usize = 0;
    var line_count: usize = 0;
    var cubic_count: usize = 0;
    var close_count: usize = 0;

    while (command_index < tiger_data.commands.len) {
        path_count += 1;

        const fill_mode = tiger_data.commands[command_index];
        command_index += 1;
        switch (fill_mode) {
            'N' => {},
            'F' => fill_count += 1,
            'E' => {
                fill_count += 1;
                even_odd_fill_count += 1;
            },
            else => return error.BadTigerFillCommand,
        }

        const stroke_mode = tiger_data.commands[command_index];
        command_index += 1;
        switch (stroke_mode) {
            'N' => {},
            'S' => stroke_count += 1,
            else => return error.BadTigerStrokeCommand,
        }

        const cap_mode = tiger_data.commands[command_index];
        command_index += 1;
        switch (cap_mode) {
            'B', 'R', 'S' => {},
            else => return error.BadTigerCapCommand,
        }

        const join_mode = tiger_data.commands[command_index];
        command_index += 1;
        switch (join_mode) {
            'M', 'R', 'B' => {},
            else => return error.BadTigerJoinCommand,
        }

        point_index += 8;
        const path_command_count: usize = @intFromFloat(tiger_data.points[point_index]);
        point_index += 1;

        var i: usize = 0;
        while (i < path_command_count) : (i += 1) {
            const path_command = tiger_data.commands[command_index];
            command_index += 1;
            switch (path_command) {
                'M' => {
                    move_count += 1;
                    point_index += 2;
                },
                'L' => {
                    line_count += 1;
                    point_index += 2;
                },
                'C' => {
                    cubic_count += 1;
                    point_index += 6;
                },
                'E' => close_count += 1,
                else => return error.BadTigerPathCommand,
            }
        }
    }

    try testing.expectEqual(tiger_data.expected_path_count, path_count);
    try testing.expectEqual(tiger_data.expected_fill_count, fill_count);
    try testing.expectEqual(tiger_data.expected_stroke_count, stroke_count);
    try testing.expectEqual(tiger_data.expected_even_odd_fill_count, even_odd_fill_count);
    try testing.expectEqual(@as(usize, 304), move_count);
    try testing.expectEqual(@as(usize, 156), line_count);
    try testing.expectEqual(@as(usize, 2222), cubic_count);
    try testing.expectEqual(@as(usize, 244), close_count);
    try testing.expectEqual(tiger_data.commands.len, command_index);
    try testing.expectEqual(tiger_data.points.len, point_index);
}
