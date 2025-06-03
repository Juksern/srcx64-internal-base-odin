package main

import win "core:sys/windows"
import "core:bytes"
import "core:strings"
import "core:slice"
import "core:mem"
import "core:strconv"
import "core:testing"
import "core:log"

import intr "base:intrinsics"

check_memory :: proc(ptr: rawptr, size: uint) -> bool {
    mbi: win.MEMORY_BASIC_INFORMATION

    result := win.VirtualQuery(ptr, &mbi, size_of(win.MEMORY_BASIC_INFORMATION))

    if result == 0 {
        return false
    }

    return mbi.State == win.MEM_COMMIT && (mbi.Protect & (win.PAGE_READONLY | win.PAGE_READWRITE)) != 0
}

pointerhook :: proc(old_ptr: ^rawptr, new_ptr: rawptr) -> rawptr {
    if old_ptr == nil {
        return nil
    }

    if !check_memory(old_ptr, size_of(rawptr)) {
        return nil
    }

    old_backup: win.DWORD
    win.VirtualProtect(old_ptr, size_of(rawptr), win.PAGE_EXECUTE_READWRITE, &old_backup)

    original := old_ptr^
    for intr.atomic_exchange(old_ptr, new_ptr) == original {}
    
    win.VirtualProtect(old_ptr, size_of(rawptr), old_backup, &old_backup)

    return original
}

//defaulted to mov r9, cs:nextInterface - 7 instructions, target at 3
get_absolute :: proc(target: uintptr, offset, length: int) -> rawptr {
    offset_addr := cast(^i32)(uintptr(target) + uintptr(offset))
    rel_offset := offset_addr^
    absolute := cast(^rawptr)(uintptr(target) + uintptr(length) + uintptr(rel_offset))
    return absolute^
}

get_executable :: proc() -> win.HMODULE {
    return win.GetModuleHandleA(nil)
}

get_module :: proc(module: string) -> (base: uintptr, size: u32) {
    c_string := strings.clone_to_cstring(module)
    defer delete(c_string)

    return get_module_interal(win.GetModuleHandleA(c_string))
}

get_module_interal :: proc(module: win.HMODULE) -> (base: uintptr, size: u32) {
    if module == nil {
        //log.error("invalid module")
        return 0, 0
    }

    dosHeader := cast(^win.IMAGE_DOS_HEADER)module

    if dosHeader.e_magic != 0x5A4D {
        //log.error("invalid dosHeader")
        return 0, 0
    }

    //log.infof("dosHeader.e_magic: %x", dosHeader.e_magic)

    ntHeader := cast(^win.IMAGE_NT_HEADERS64)(uintptr(dosHeader) + uintptr(dosHeader.e_lfanew))

    if ntHeader.Signature != 0x00004550 {
        //log.error("invalid ntHeader")
        return 0, 0
    }

    //log.infof("ntHeader.Signature: %x", ntHeader.Signature)

    base = uintptr(ntHeader.OptionalHeader.ImageBase)
    size = ntHeader.OptionalHeader.SizeOfImage
    return base, size
}

find :: proc(start: uintptr, length: u32, pattern: string) -> (address: uintptr, ok: bool) #optional_ok {
    pattern_bytes := build_pattern(pattern)
    defer delete(pattern_bytes)

    if len(pattern_bytes) > int(length) {
        return 0, false
    }

    memory_ptr := transmute(^u8)start

    for i: uintptr = 0; i <= uintptr(int(length) - len(pattern_bytes)); i += 1 {
        match := true
        for j in 0..<len(pattern_bytes) {
            current_byte := mem.ptr_offset(memory_ptr, i + uintptr(j))^

            if pattern_bytes[j] != -1 && u8(pattern_bytes[j]) != current_byte {
                match = false
                break
            }
        }
        if match {
            //log.infof("found \"{}\" @ %x", pattern, start + uintptr(i))
            return start + uintptr(i), true
        }
    }

    //log.warnf("no matching patterns found for \"{}\"", pattern)
    return 0, false
}

@(private)
build_pattern :: proc(patternStr: string) -> [dynamic]i16 {
    fixed, allocation := strings.remove_all(patternStr, " ")
    defer if allocation {
        delete(fixed)
    }

    pattern: [dynamic]i16

    for i := 0; i < len(fixed); i += 1 {
        if fixed[i] == '?' {
            append(&pattern, cast(i16)-1)
        } else {
            if i + 1 >= len(fixed) { break }
            value, _ := strconv.parse_u64(fixed[i:i+2], 16)
            append(&pattern, cast(i16)value)
            i += 1
        }
    }
    return pattern
}

@(test)
scan_test :: proc(t: ^testing.T) {
    size := 1024 * 1024
    data, _ := mem.alloc_bytes_non_zeroed(size)
    defer delete(data)

    data[40] = 0xDE
    data[42] = 0xAD
    data[99] = 0xBE
    data[101] = 0xEF

    address := find(uintptr(&data[0]), u32(len(data)), "DE ? AD")
    address2 := find(uintptr(&data[0]), u32(len(data)), "? BE ? EF")
    address3 := find(uintptr(&data[0]), u32(len(data)), "? 13 37 ?") or_else 1337
    address4 := find(uintptr(&data[0]), u32(len(data)), "? ? ? ?")

    testing.expect_value(t, address, uintptr(&data[40]))
    testing.expect_value(t, address2, uintptr(&data[98]))
    testing.expect_value(t, address3, 1337)
    testing.expect_value(t, address4, uintptr(&data[0]))
}

@(test)
sig_test :: proc(t: ^testing.T) {
    mod, mod_size := get_module_interal(get_executable())
    address, ok := find(mod, mod_size, "2E 70 64 61")
    address1, ok1 := find(mod, mod_size, "50 45")

    log.infof("module base: %x mod: %x address: %x address1: %x", get_executable(), mod, address - mod, address1 - mod)

    testing.expect(t, ok == true, "didn't find address")
    testing.expect(t, ok1 == true, "didn't find address1")
    testing.expect(t, mod_size != 0, "didn't get image size")
}

@(test)
ptr_test :: proc(t: ^testing.T) {
    var1 := 1337
    var1_ptr := &var1

    var2 := 7331
    var2_ptr := &var2

    old := pointerhook(cast(^rawptr)&var1_ptr, rawptr(var2_ptr))
    testing.expect_value(t, var1_ptr^, 7331)
    
    _ = pointerhook(cast(^rawptr)&var1_ptr, old)
    testing.expect_value(t, var1_ptr^, 1337)
}