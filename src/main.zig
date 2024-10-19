const std = @import("std");
const c = @cImport({
    @cInclude("libs/stb_image.h");
    @cInclude("libs/stb_image_write.h");
});

const Allocator = std.mem.Allocator;

const JPEGHeader = [_]u8{ 0xFF, 0xD8, 0xFF };
const PNGHeader = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
const HeaderSize = 100; // Skip first 100 bytes to avoid corrupting file header

fn encodeMessage(allocator: Allocator, input_path: []const u8, output_path: []const u8, message: []const u8, key: []const u8) !void {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;

    const image_data = c.stbi_load(input_path.ptr, &width, &height, &channels, 0);
    if (image_data == null) return error.ImageLoadFailed;
    defer c.stbi_image_free(image_data);

    const image_size: usize = @intCast(width * height * channels);
    const output_data = try allocator.alloc(u8, image_size);
    defer allocator.free(output_data);
    std.mem.copy(u8, output_data, image_data[0..image_size]);

    const encrypted_message = try encryptMessage(allocator, message, key);
    defer allocator.free(encrypted_message);

    try hideData(output_data, encrypted_message);

    const output_path_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(output_path_z);

    const ext = std.fs.path.extension(output_path);
    var extMap = 0;
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) extMap = 1;
    if (std.mem.eql(u8, ext, ".png")) extMap = 2;

    if (extMap == 0) return error.UnsupportedImageFormat;

    const success = switch (std.fs.path.extension(output_path)) {
        1 => c.stbi_write_jpg(output_path_z.ptr, width, height, channels, output_data.ptr, 90) != 0,
        2 => c.stbi_write_png(output_path_z.ptr, width, height, channels, output_data.ptr, width * channels) != 0,
        else => return error.UnsupportedImageFormat,
    };

    if (!success) return error.ImageWriteFailed;
}

fn decodeMessage(allocator: Allocator, input_path: []const u8, key: []const u8) ![]u8 {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;

    const image_data = c.stbi_load(input_path.ptr, &width, &height, &channels, 0);
    if (image_data == null) return error.ImageLoadFailed;
    defer c.stbi_image_free(image_data);

    const image_size: usize = @intCast(width * height * channels);
    const encrypted_message = try extractData(allocator, image_data[0..image_size]);
    defer allocator.free(encrypted_message);

    return decryptMessage(allocator, encrypted_message, key);
}

fn encryptMessage(allocator: Allocator, message: []const u8, key: []const u8) ![]u8 {
    var encrypted = try allocator.alloc(u8, message.len);
    for (message, 0..) |char, i| {
        encrypted[i] = char ^ key[i % key.len];
    }
    return encrypted;
}

fn decryptMessage(allocator: Allocator, encrypted: []const u8, key: []const u8) ![]u8 {
    var decrypted = try allocator.alloc(u8, encrypted.len);
    for (encrypted, 0..) |char, i| {
        decrypted[i] = char ^ key[i % key.len];
    }
    return decrypted;
}

fn hideData(image: []u8, data: []const u8) !void {
    const total_bits = data.len * 8;
    var bit_index: usize = 0;

    for (image[HeaderSize..], HeaderSize..) |*byte, i| {
        std.debug.print("Byte {d} {b}\n", .{ i, byte.* });

        if (bit_index >= total_bits) break;

        const data_byte = data[bit_index / 8];
        const bit: u3 = @intCast((data_byte >> @intCast(7 - (bit_index % 8))) & 1);

        byte.* = (byte.* & 0xFE) | bit;
        bit_index += 1;
    }

    if (bit_index < total_bits) {
        return error.ImageTooSmall;
    }
}

fn extractData(allocator: Allocator, image: []const u8) ![]u8 {
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    var current_byte: u8 = 0;
    var bit_count: u3 = 0;

    for (image[HeaderSize..]) |byte| {
        current_byte = (current_byte << 1) | (byte & 1);
        bit_count += 1;

        if (bit_count == 8) {
            try data.append(current_byte);
            current_byte = 0;
            bit_count = 0;

            if (data.items[data.items.len - 1] == 0) {
                break;
            }
        }
    }

    return data.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) {
        std.debug.print("Usage: {} <encode/decode> <input_file> <output_file> <key> [message]\n", .{args[0]});
        return;
    }

    const mode = args[1];
    const input_file_path = args[2];
    const output_file_path = args[3];
    const key = args[4];

    if (std.mem.eql(u8, mode, "encode")) {
        if (args.len < 6) {
            std.debug.print("Error: Message required for encoding\n", .{});
            return;
        }
        const message = args[5];
        try encodeMessage(allocator, input_file_path, output_file_path, message, key);
    } else if (std.mem.eql(u8, mode, "decode")) {
        const message = try decodeMessage(allocator, input_file_path, key);
        defer allocator.free(message);
        std.debug.print("Decoded message: {s}\n", .{message});
    } else {
        std.debug.print("Error: Invalid mode. Use 'encode' or 'decode'\n", .{});
    }
}
