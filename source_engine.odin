package main

import "core:strings"
import "core:mem"
import "base:intrinsics"
import "core:testing"
import "core:log"
import "core:slice"
import "core:unicode/utf8"
import "base:runtime"


Vtable :: struct {
    func: rawptr
}

BaseVtable :: struct {
    vtable: ^Vtable,
}

InterfaceEntry :: struct #packed {
    createFn: proc "c" () -> i64,       // Function pointer returning i64 (8 bytes)
    name: cstring,                      // Pointer to unsigned 8-bit integer (8 bytes)
    next: rawptr,                       // Void pointer (8 bytes)
}

call_vfunc :: proc ($T: typeid, instance: ^BaseVtable, index: int, args: ..any) -> T {
    vtable := instance.vtable
    fn := cast(^proc "c" (..any) -> T)(mem.ptr_offset(vtable, index))
    return fn^(args)
}

find_interface :: proc(head: rawptr, target_name: string) -> (ptr: ^BaseVtable, ok: bool) #optional_ok {
    current := transmute(^InterfaceEntry)head

    for current != nil {
        if current.name != nil {
            current_name := string(current.name)

            if strings.compare(current_name[:len(target_name)], target_name) == 0 {
                temp := current.createFn()
                ptr  = transmute(^BaseVtable)temp
                return ptr, true
            }

            current = transmute(^InterfaceEntry)current.next
        }
    }

    return nil, false
}


SendPropType :: enum i64 {
    DPT_Int = 0,
    DPT_Float,
    DPT_Vector,
    DPT_VectorXY, // Only encodes the XY of a vector, ignores Z
    DPT_String,
    DPT_Array,  // An array of the base types (can't be of datatables).
    DPT_DataTable,
    DPT_Int64,
    DPT_NUMSendPropTypes
}

DVariant :: struct #packed {
    v: struct #raw_union {
        f32,
        i32,
        cstring,
        uintptr,
        [3]f32,
        i64,
    },
    type: SendPropType
}

RecvProxyData :: struct {
    prop: ^RecvProp,
    value: DVariant,
    element: i64,
    object_id: i64,
}

ArrayProp :: struct #packed {
    unkn0:      i64,
    x, y, z:    f64
}

RecvProp :: struct #packed {
    name: cstring,
    type: i32,
    flag: i32,
    buffer_size: i32,
    inside_array: i32,
    extra_data: rawptr,
    array_prop: ^ArrayProp,
    fn_ptr0: rawptr,
    fn_ptr1: rawptr,
    fn_ptr2: rawptr,
    data_table: ^RecvTable,
    offset: i32,
    stride: i32,
    elements: i32,
    parent_array_prop_name: cstring,
    str_len: i32
}
#assert(size_of(RecvProp) == 0x60)


RecvTable :: struct #packed {
    props: ^RecvTable,
    num_props: i64,
    decoder: uintptr,
    name: cstring,
    initialized: i64,
    virtual: i64
}
#assert(size_of(RecvTable) == 0x30)

ClientClass :: struct {
    create_fn: rawptr,
    create_event_fn: rawptr,
    name: cstring,
    table: ^RecvTable,
    next: ^ClientClass,
    id: i64,
}

NetvarManager :: struct {
    offsets: map[string]i32,
    key_to_free: string
}

netvar_manager_init :: proc(manager: ^NetvarManager, client_class_head: ^ClientClass) {
    manager.offsets = make(map[string]i32)

    p_class := client_class_head

    for p_class != nil {
        if p_class.table != nil {
            dump_table(manager, p_class.table)
        }
        //log.infof("table: %x", p_class.table)
        p_class = p_class.next
    }
}

netvar_manager_deinit :: proc(manager: ^NetvarManager) {
    delete(manager.offsets)
    delete(manager.key_to_free)
}

get_offset :: proc(manager: ^NetvarManager, table_name, prop_name: string) -> i32 {
    key := strings.concatenate({table_name, ".", prop_name})
    defer delete(key)
    return manager.offsets[key] or_else 0
}

@(private)
dump_table :: proc(manager: ^NetvarManager, table: ^RecvTable, offset: i32 = 0) {
    for i in 0..<table.num_props {
        prop := cast(^RecvProp)mem.ptr_offset(table.props, i)
        
        if prop == nil {
            continue
        }

        if prop.elements == 0 && prop.stride == 0 { //should be 0 if invalid, -1 has been observed for valid ones
            continue
        }

        if prop.type == 6 && prop.data_table != nil {
            data_name := string(prop.data_table.name)
            if data_name[:1] == "D" {
                dump_table(manager, prop.data_table, offset + prop.offset)
            }
        }

        table_name := runtime.cstring_to_string(table.name)
        prop_name := runtime.cstring_to_string(prop.name)

        if strings.compare(prop_name, "baseclass") == 0 {
            continue
        }

        layout := [?]string {table_name, ".", prop_name}
        key := strings.concatenate(layout[:])

        manager.offsets[key] = offset + prop.offset
        manager.key_to_free = key
    }
}
