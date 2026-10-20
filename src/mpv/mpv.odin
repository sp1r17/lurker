// Bindings for the parts of libmpv's client and render API (mpv/client.h,
// mpv/render.h, mpv/render_gl.h) that the app uses.
package mpv

import "core:c"

foreign import lib "system:mpv"

Handle :: struct {}
Render_Context :: struct {}

Error :: distinct c.int

Event_Id :: enum c.int {
	None               = 0,
	Shutdown           = 1,
	Log_Message        = 2,
	Get_Property_Reply = 3,
	Set_Property_Reply = 4,
	Command_Reply      = 5,
	Start_File         = 6,
	End_File           = 7,
	File_Loaded        = 8,
	Idle               = 11,
}

Event :: struct {
	event_id:       Event_Id,
	error:          Error,
	reply_userdata: u64,
	data:           rawptr,
}

Event_Log_Message :: struct {
	prefix:    cstring,
	level:     cstring,
	text:      cstring,
	log_level: c.int,
}

End_File_Reason :: enum c.int {
	EOF      = 0,
	Stop     = 2,
	Quit     = 3,
	Error    = 4,
	Redirect = 5,
}

Event_End_File :: struct {
	reason:            End_File_Reason,
	error:             Error,
	playlist_entry_id: i64,
	playlist_insert_id: i64,
	playlist_insert_num_entries: c.int,
}

Render_Param_Type :: enum c.int {
	Invalid             = 0,
	Api_Type            = 1,
	Opengl_Init_Params  = 2,
	Opengl_Fbo          = 3,
	Flip_Y              = 4,
	Advanced_Control    = 10,
}

Render_Param :: struct {
	type: Render_Param_Type,
	data: rawptr,
}

RENDER_API_TYPE_OPENGL :: "opengl"

Render_Update_Flag :: enum u64 {
	Frame = 0,
}
Render_Update_Flags :: bit_set[Render_Update_Flag;u64]

Opengl_Init_Params :: struct {
	get_proc_address:     proc "c" (ctx: rawptr, name: cstring) -> rawptr,
	get_proc_address_ctx: rawptr,
}

Opengl_Fbo :: struct {
	fbo:             c.int,
	w, h:            c.int,
	internal_format: c.int,
}

@(default_calling_convention = "c", link_prefix = "mpv_")
foreign lib {
	error_string :: proc(error: Error) -> cstring ---
	create :: proc() -> ^Handle ---
	initialize :: proc(ctx: ^Handle) -> Error ---
	terminate_destroy :: proc(ctx: ^Handle) ---
	set_option_string :: proc(ctx: ^Handle, name, data: cstring) -> Error ---
	set_property_string :: proc(ctx: ^Handle, name, data: cstring) -> Error ---
	// args is a nil-terminated array.
	command :: proc(ctx: ^Handle, args: [^]cstring) -> Error ---
	command_async :: proc(ctx: ^Handle, reply_userdata: u64, args: [^]cstring) -> Error ---
	request_log_messages :: proc(ctx: ^Handle, min_level: cstring) -> Error ---
	wait_event :: proc(ctx: ^Handle, timeout: f64) -> ^Event ---
	// cb is called from mpv's own threads, so it may only signal the main thread.
	set_wakeup_callback :: proc(ctx: ^Handle, cb: proc "c" (d: rawptr), d: rawptr) ---

	render_context_create :: proc(res: ^^Render_Context, mpv: ^Handle, params: [^]Render_Param) -> Error ---
	// callback is called from mpv's own threads, so it may only signal the main thread.
	render_context_set_update_callback :: proc(ctx: ^Render_Context, callback: proc "c" (d: rawptr), d: rawptr) ---
	render_context_update :: proc(ctx: ^Render_Context) -> Render_Update_Flags ---
	render_context_render :: proc(ctx: ^Render_Context, params: [^]Render_Param) -> Error ---
	render_context_report_swap :: proc(ctx: ^Render_Context) ---
	render_context_free :: proc(ctx: ^Render_Context) ---
}
