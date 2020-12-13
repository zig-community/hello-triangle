const std = @import("std");
const zwl = @import("zwl");
const gl = @import("gl");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const global_allocator = &gpa.allocator;

pub const WindowPlatform = zwl.Platform(.{
    .platforms_enabled = .{
        .x11 = false,
        .xlib = (std.builtin.os.tag == .linux),
        .wayland = false,
        .windows = (std.builtin.os.tag == .windows),
    },
    .backends_enabled = .{ .opengl = true },
    .single_window = true,
    .x11_use_xcb = false,
});

const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
};

pub fn main() !void {
    defer _ = gpa.deinit();

    // Initialize the window platform:

    var platform = try WindowPlatform.init(global_allocator, .{});
    defer platform.deinit();

    var window = try platform.createWindow(.{
        .title = "Hello Triangle",
        .width = 1280,
        .height = 720,
        .resizeable = false,
        .track_damage = true, // workaround for a ZWL bug
        .visible = true,
        .decorations = true,
        .track_mouse = false,
        .track_keyboard = true,
        .backend = zwl.Backend{ .opengl = .{ .major = 3, .minor = 3 } },
    });
    defer window.deinit();

    // Load the OpenGL function pointers
    try gl.load(window.platform, WindowPlatform.getOpenGlProcAddress);

    // Print information about the selected OpenGL context:
    std.log.info("OpenGL Version:  {}", .{std.mem.span(gl.getString(gl.VERSION))});
    std.log.info("OpenGL Vendor:   {}", .{std.mem.span(gl.getString(gl.VENDOR))});
    std.log.info("OpenGL Renderer: {}", .{std.mem.span(gl.getString(gl.RENDERER))});

    // Initialize and create the OpenGL structures:

    // compile the shader program
    const triangle_program = try compileShader(
        global_allocator,
        @embedFile("triangle.vert"),
        @embedFile("triangle.frag"),
    );
    defer gl.deleteProgram(triangle_program);

    // create the vertex buffer
    var vertex_buffer: gl.GLuint = 0;
    gl.genBuffers(1, &vertex_buffer);
    if (vertex_buffer == 0)
        return error.OpenGlFailure;
    defer gl.deleteBuffers(1, &vertex_buffer);

    {
        const vertices = [_]Vertex{
            Vertex{ // top
                .x = 0,
                .y = 0.5,
                .u = 1,
                .v = 0,
            },
            Vertex{ // bot left
                .x = -0.5,
                .y = -0.5,
                .u = 0,
                .v = 1,
            },
            Vertex{ // bot right
                .x = 0.5,
                .y = -0.5,
                .u = 1,
                .v = 1,
            },
        };

        gl.bindBuffer(gl.ARRAY_BUFFER, vertex_buffer);
        gl.bufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, gl.STATIC_DRAW);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    }

    // Create a vertex array that describes the vertex buffer layout
    var vao: gl.GLuint = 0;
    gl.genVertexArrays(1, &vao);
    if (vao == 0)
        return error.OpenGlFailure;
    defer gl.deleteVertexArrays(1, &vao);

    gl.bindVertexArray(vao);

    gl.enableVertexAttribArray(0); // Position attribute
    gl.enableVertexAttribArray(1); // UV attributte

    gl.bindBuffer(gl.ARRAY_BUFFER, vertex_buffer);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @intToPtr(?*const c_void, @byteOffsetOf(Vertex, "x")));
    gl.vertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @intToPtr(?*const c_void, @byteOffsetOf(Vertex, "u")));
    gl.bindBuffer(gl.ARRAY_BUFFER, 0);

    // Run the main loop:

    main_loop: while (true) {
        const event = try platform.waitForEvent();

        const repaint = switch (event) {
            .WindowResized => |win| blk: {
                const size = win.getSize();
                gl.viewport(0, 0, size[0], size[1]);
                break :blk true;
            },

            .WindowDestroyed, .ApplicationTerminated => break :main_loop,

            .WindowDamaged, .WindowVBlank => true,

            .KeyDown => |ev| blk: {
                // this is escape
                if (ev.scancode == 1)
                    break :main_loop;
                break :blk false;
            },

            else => false,
        };

        if (repaint) {
            gl.clearColor(0.3, 0.3, 0.3, 1.0);
            gl.clear(gl.COLOR_BUFFER_BIT);

            gl.useProgram(triangle_program);
            gl.bindVertexArray(vao);

            gl.drawArrays(gl.TRIANGLES, 0, 3);

            try window.present();
        }
    }

    return;
}

fn compileShader(allocator: *std.mem.Allocator, vertex_source: [:0]const u8, fragment_source: [:0]const u8) !gl.GLuint {
    var vertex_shader = try compilerShaderPart(allocator, gl.VERTEX_SHADER, vertex_source);
    defer gl.deleteShader(vertex_shader);

    var fragment_shader = try compilerShaderPart(allocator, gl.FRAGMENT_SHADER, fragment_source);
    defer gl.deleteShader(fragment_shader);

    const program = gl.createProgram();
    if (program == 0)
        return error.OpenGlFailure;
    errdefer gl.deleteProgram(program);

    gl.attachShader(program, vertex_shader);
    defer gl.detachShader(program, vertex_shader);

    gl.attachShader(program, fragment_shader);
    defer gl.detachShader(program, fragment_shader);

    gl.linkProgram(program);

    var link_status: gl.GLint = undefined;
    gl.getProgramiv(program, gl.LINK_STATUS, &link_status);

    if (link_status != gl.TRUE) {
        var info_log_length: gl.GLint = undefined;
        gl.getProgramiv(program, gl.INFO_LOG_LENGTH, &info_log_length);

        const info_log = try allocator.alloc(u8, @intCast(usize, info_log_length));
        defer allocator.free(info_log);

        gl.getProgramInfoLog(program, @intCast(c_int, info_log.len), null, info_log.ptr);

        std.log.info("failed to compile shader:\n{}", .{info_log});

        return error.InvalidShader;
    }

    return program;
}

fn compilerShaderPart(allocator: *std.mem.Allocator, shader_type: gl.GLenum, source: [:0]const u8) !gl.GLuint {
    var shader = gl.createShader(shader_type);
    if (shader == 0)
        return error.OpenGlFailure;
    errdefer gl.deleteShader(shader);

    var sources = [_][*c]const u8{source.ptr};
    var lengths = [_]gl.GLint{@intCast(gl.GLint, source.len)};

    gl.shaderSource(shader, 1, &sources, &lengths);

    gl.compileShader(shader);

    var compile_status: gl.GLint = undefined;
    gl.getShaderiv(shader, gl.COMPILE_STATUS, &compile_status);

    if (compile_status != gl.TRUE) {
        var info_log_length: gl.GLint = undefined;
        gl.getShaderiv(shader, gl.INFO_LOG_LENGTH, &info_log_length);

        const info_log = try allocator.alloc(u8, @intCast(usize, info_log_length));
        defer allocator.free(info_log);

        gl.getShaderInfoLog(shader, @intCast(c_int, info_log.len), null, info_log.ptr);

        std.log.info("failed to compile shader:\n{}", .{info_log});

        return error.InvalidShader;
    }

    return shader;
}
