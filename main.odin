package main

import "core:thread"
import "base:runtime"
import win "core:sys/windows"
import "core:mem"
import "core:log"
import "core:fmt"
import "base:intrinsics"
import "core:os"
import "core:unicode/utf16"

draw_text :: proc (hdc: win.HDC, x, y: i32, text: string) {
    win.SetBkMode(hdc, .TRANSPARENT)
    win.SetTextColor(hdc, win.RGB(255, 255, 255))
    complete := win.utf8_to_wstring(text)
    win.TextOutW(hdc, x, y, complete, i32(len(text)))
}

draw_rectangle :: proc(hdc: win.HDC, x, y, width, height: i32, color: win.COLORREF) {
    rect := win.RECT{left = x, top = y, right = x + width, bottom = y + height}
    brush := win.CreateSolidBrush(color)
    win.FillRect(hdc, &rect, brush)
    win.DeleteObject(win.HGDIOBJ(brush))
}

draw_menu :: proc(hdc: win.HDC) {
    draw_text(hdc, 10, 10, "hello")
}

render_data :: struct {
    mapped_buffer: rawptr,
    buffer_2: rawptr,
    current_width: i32,
    current_height: i32,
    mdc: win.HDC,
    hdc: win.HDC,
    bitmap: win.HBITMAP,
}
data: render_data

gdi_render_begin :: proc(hwnd: win.HWND) {
    data.hdc = win.GetDC(hwnd)
    data.mdc = win.CreateCompatibleDC(data.hdc)

    rect: win.RECT
    win.GetClientRect(hwnd, &rect)
    width:i32 = rect.right - rect.left
    height:i32 = rect.bottom - rect.top 

    info: win.BITMAPINFO
    info.bmiHeader.biSize = size_of(win.BITMAPINFOHEADER)
    info.bmiHeader.biWidth = width
    info.bmiHeader.biHeight = -height
    info.bmiHeader.biPlanes = 1
    info.bmiHeader.biBitCount = 32
    info.bmiHeader.biCompression = win.BI_RGB
    info.bmiHeader.biSizeImage = u32(width * height * 8)
    data.bitmap = win.CreateDIBSection(data.hdc, &info, win.DIB_RGB_COLORS, &data.mapped_buffer, nil, 0)
    win.SelectObject(data.mdc, win.HGDIOBJ(data.bitmap))
    win.SelectObject(data.mdc, win.GetStockObject(win.DC_BRUSH))

    data.current_width = width
    data.current_height = height
}

gdi_render_frame :: proc() {
    draw_menu(data.hdc)

    //copy image to back buffer
    win.BitBlt(data.mdc, 0, 0, data.current_width, data.current_height, data.hdc, 0, 0, win.SRCCOPY)

    draw_menu(data.mdc)

    //copy image to front buffer
    win.BitBlt(data.hdc, 0, 0, data.current_width, data.current_height, data.mdc, 0, 0, win.SRCCOPY)
}

gdi_render_end :: proc() {
    if data.mdc != nil {
        win.SelectObject(data.mdc, win.GetStockObject(21))
        win.DeleteObject(win.HGDIOBJ(data.bitmap))
        win.DeleteObject(win.HGDIOBJ(data.mdc))
        win.DeleteDC(data.hdc)
    }
}

tt :: proc(t: ^thread.Thread) {
    defer thread.destroy(t)

    when ODIN_DEBUG {
        if !win.AllocConsole() {
            win.MessageBoxW(nil, win.L("Failed to allocate console"), win.L("LLLLL"), win.MB_OK)
        }
        defer win.FreeConsole()

        stdout := os.Handle(win.GetStdHandle(win.STD_OUTPUT_HANDLE))
        context.logger = log.create_file_logger(stdout, lowest = .Info, opt = {.Level})
    } else {
        context.logger = log.nil_logger()
    }

    data := render_data{}

    client, client_size := get_module("client.dll")
    interface_head := find(client, client_size, "4C 8B 0D ? ? ? ? 4C 8B D2")

    iclient := find_interface(get_absolute(interface_head, 3, 7), "VClient0")
    client_head := cast(^ClientClass)call_vfunc(uintptr, iclient, 8, 0)

    mgr: NetvarManager
    netvar_manager_init(&mgr, client_head)
    defer netvar_manager_deinit(&mgr)

    for k, v in mgr.offsets {
        log.infof("%s -> %x", k, v)
    }
    
    hwnd := win.FindWindowA("Valve001", nil)
    for {
        gdi_render_begin(hwnd)
        gdi_render_frame()
        gdi_render_end()
    }
}

main :: proc () {
    t := thread.create(tt)
    thread.start(t)
}
