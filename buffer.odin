package nor

import "base:runtime"
import "core:io"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"

Buffer :: struct {
	arena: vmem.Arena,
	buf:   Gap_Buffer,
}

buffer_init :: proc(b: ^Buffer) -> runtime.Allocator_Error {
	if err := vmem.arena_init_growing(&b.arena); err != nil {
		return err
	}
	context.allocator = vmem.arena_allocator(&b.arena)
	gap_buffer_init(&b.buf)
	return nil
}

buffer_destroy :: proc(b: ^Buffer) {
	vmem.arena_destroy(&b.arena)
	b.buf = {}
}


when ODIN_TEST {
	DEFAULT_GAP :: 10 * runtime.Byte
} else {
	DEFAULT_GAP :: 1 * runtime.Kilobyte
}

// A UTF-8 encoded, growable [gap buffer](https://en.wikipedia.org/wiki/Gap_buffer).
Gap_Buffer :: struct {
	data:      [dynamic]byte,
	gap_start: int,
	gap_end:   int,
}

gap_buffer_init :: proc(b: ^Gap_Buffer) {
	b.data = make([dynamic]byte, DEFAULT_GAP)
	b.gap_start = 0
	b.gap_end = DEFAULT_GAP
}

gap_buffer_from_reader :: proc(b: ^Gap_Buffer, r: io.Reader) {
	panic("TODO")
}

gap_buffer_destroy :: proc(b: ^Gap_Buffer) -> runtime.Allocator_Error {
	if err := delete(b.data); err != nil {
		return err
	}
	b^ = {}
	return nil
}

gap_buffer_insert :: proc(b: ^Gap_Buffer, s: string) {
	gap_size := _gap_buffer_gap_size(b)
	if len(s) >= gap_size {
		// grow
		old_len := len(b.data)
		grow_by := max(DEFAULT_GAP, len(s) - gap_size + DEFAULT_GAP)
		new_len := max(old_len * 2, old_len + grow_by)

		non_zero_resize(&b.data, new_len)

		suffix_len := old_len - b.gap_end
		if suffix_len > 0 {
			old_suffix := b.data[b.gap_end:old_len]
			b.gap_end = new_len - suffix_len
			copy(b.data[b.gap_end:], old_suffix)
		} else {
			b.gap_end = new_len
		}
	}

	copy(b.data[b.gap_start:], s)
	b.gap_start += len(s)
}

// Positive `len`: Delete from the left of the gap
// Negative `len`: Delete from the right of the gap
gap_buffer_delete :: proc(b: ^Gap_Buffer, count: int) {
	if count > 0 {
		b.gap_start -= min(b.gap_start, count)
	} else if count < 0 {
		b.gap_end += min(len(b.data) - b.gap_end, -count)
	}
}

gap_buffer_move_to :: proc(b: ^Gap_Buffer, offset: int) {
	offset := clamp(offset, 0, len(b.data) - _gap_buffer_gap_size(b))

	if offset < b.gap_start {
		delta := b.gap_start - offset
		copy(b.data[b.gap_end - delta:b.gap_end], b.data[b.gap_start - delta:b.gap_start])
		b.gap_start -= delta
		b.gap_end -= delta
	} else {
		delta := offset - b.gap_start
		copy(b.data[b.gap_start:b.gap_start + delta], b.data[b.gap_end:b.gap_end + delta])
		b.gap_start += delta
		b.gap_end += delta
	}
}

gap_buffer_clear :: proc(b: ^Gap_Buffer) {
	slice.zero(b.data[:])
	b.gap_start = 0
	b.gap_end = len(b.data)
}

gap_buffer_parts :: proc(b: ^Gap_Buffer) -> (before, after: string) {
	return string(b.data[:b.gap_start]), string(b.data[b.gap_end:])
}

// Returns a newly allocated string representing the buffer's "real" contents
gap_buffer_to_string :: proc(b: ^Gap_Buffer) -> string {
	before, after := gap_buffer_parts(b)
	return strings.concatenate({before, after})
}

gap_buffer_byte_at :: proc(b: ^Gap_Buffer, i: int) -> Maybe(byte) {
	switch i {
	case 0 ..< b.gap_start:
		before, _ := gap_buffer_parts(b)
		return before[i]
	case b.gap_end ..< len(b.data):
		_, after := gap_buffer_parts(b)
		return after[b.gap_end + i]
	case:
		return nil
	}
}

gap_buffer_len :: proc(b: ^Gap_Buffer) -> int {
	return len(b.data) - _gap_buffer_gap_size(b)
}

_gap_buffer_gap_size :: proc(b: ^Gap_Buffer) -> int {
	return b.gap_end - b.gap_start
}

@(private = "file")
_gap_buffer_expect :: proc(
	t: ^testing.T,
	b: ^Gap_Buffer,
	args: ..string,
	loc := #caller_location,
) {
	s := gap_buffer_to_string(b)
	defer delete(s)

	if len(args) == 0 {
		testing.expect_value(t, s, "", loc = loc)
		return
	}

	if len(args) == 1 {
		testing.expect_value(t, s, args[0], loc = loc)
		return
	}

	expected := strings.concatenate(args)
	defer delete(expected)
	testing.expect_value(t, s, expected, loc = loc)
}

@(test)
test_gap_buffer_init :: proc(t: ^testing.T) {
	b := Gap_Buffer{}
	testing.expect_value(t, len(b.data), 0)
	testing.expect_value(t, b.gap_start, 0)
	testing.expect_value(t, b.gap_end, 0)

	gap_buffer_init(&b)
	defer gap_buffer_destroy(&b)

	testing.expect_value(t, len(b.data), DEFAULT_GAP)
	testing.expect_value(t, b.gap_start, 0)
	testing.expect_value(t, b.gap_end, DEFAULT_GAP)
	_gap_buffer_expect(t, &b)
}

@(test)
test_gap_buffer_insert :: proc(t: ^testing.T) {
	gap_sized_str := strings.repeat("_", DEFAULT_GAP)
	defer delete(gap_sized_str)

	b := Gap_Buffer{}
	gap_buffer_init(&b)
	defer gap_buffer_destroy(&b)

	HEAD :: "foo"

	// insert at start
	{
		gap_buffer_insert(&b, HEAD)
		_gap_buffer_expect(t, &b, HEAD)
		testing.expect_value(t, b.gap_start, len(HEAD))
		testing.expect_value(t, b.gap_end, DEFAULT_GAP)
	}

	// insert larger than gap
	{
		gap_buffer_insert(&b, gap_sized_str)
		_gap_buffer_expect(t, &b, HEAD, gap_sized_str)
	}

	MID :: "mid"
	HALF_GAP :: DEFAULT_GAP / 2

	// insert in the middle
	{
		mid_offset := len(HEAD) + HALF_GAP
		gap_buffer_move_to(&b, mid_offset)
		gap_buffer_insert(&b, MID)
		_gap_buffer_expect(t, &b, HEAD, gap_sized_str[:HALF_GAP], MID, gap_sized_str[HALF_GAP:])
	}

	// insert at end
	{
		TAIL :: "end"

		gap_buffer_move_to(&b, gap_buffer_len(&b))
		gap_buffer_insert(&b, TAIL)
		_gap_buffer_expect(
			t,
			&b,
			HEAD,
			gap_sized_str[:HALF_GAP],
			MID,
			gap_sized_str[HALF_GAP:],
			TAIL,
		)
	}

	// TODO: utf8
}

@(test)
test_gap_buffer_delete :: proc(t: ^testing.T) {
	S := "foo"
	MID :: "bar"

	b := Gap_Buffer{}
	gap_buffer_init(&b)
	defer gap_buffer_destroy(&b)

	// delete from empty
	{
		gap_buffer_delete(&b, 500)
		_gap_buffer_expect(t, &b)
	}

	// start: delete exact
	{
		gap_buffer_insert(&b, S)
		gap_buffer_delete(&b, len(S))
		_gap_buffer_expect(t, &b)
	}

	// start: delete less than contents
	{
		gap_buffer_insert(&b, S)
		gap_buffer_delete(&b, len(S) - 2)
		_gap_buffer_expect(t, &b, S[:2])
	}

	// start: delete more than contents
	{
		gap_buffer_move_to(&b, gap_buffer_len(&b))
		gap_buffer_insert(&b, S)
		gap_buffer_delete(&b, len(S) + 2)
		_gap_buffer_expect(t, &b)
	}

	// mid: delete exact
	{
		gap_buffer_clear(&b)
		gap_buffer_insert(&b, S)
		gap_buffer_insert(&b, MID)
		gap_buffer_move_to(&b, len(S))
		gap_buffer_delete(&b, -len(MID))
		_gap_buffer_expect(t, &b, S)
	}

	// mid: delete less than exact
	{
		gap_buffer_clear(&b)
		gap_buffer_insert(&b, S)
		gap_buffer_insert(&b, MID)
		gap_buffer_move_to(&b, len(S))
		gap_buffer_delete(&b, -1)
		_gap_buffer_expect(t, &b, S, MID[1:])
	}

	// mid: delete more than exact
	{
		gap_buffer_clear(&b)
		gap_buffer_insert(&b, S)
		gap_buffer_insert(&b, MID)
		gap_buffer_move_to(&b, len(S))
		gap_buffer_delete(&b, -(len(MID) + 2))
		_gap_buffer_expect(t, &b, S)
	}

	// end: delete exact
	{
		gap_buffer_clear(&b)
		gap_buffer_insert(&b, S)
		gap_buffer_insert(&b, MID)
		gap_buffer_move_to(&b, gap_buffer_len(&b))
		gap_buffer_delete(&b, len(S) + len(MID))
		_gap_buffer_expect(t, &b)
	}

	// end: delete less than exact
	{
		gap_buffer_clear(&b)
		gap_buffer_insert(&b, S)
		gap_buffer_insert(&b, MID)
		gap_buffer_move_to(&b, gap_buffer_len(&b))
		gap_buffer_delete(&b, len(S) + len(MID) - 2)
		_gap_buffer_expect(t, &b, S[:2])
	}

	// end: delete more than exact
	{
		gap_buffer_clear(&b)
		gap_buffer_insert(&b, S)
		gap_buffer_insert(&b, MID)
		gap_buffer_move_to(&b, gap_buffer_len(&b))
		gap_buffer_delete(&b, len(S) + len(MID) + 2)
		_gap_buffer_expect(t, &b)
	}
}


// @(test)
// test_gap_buffer_at :: proc(t: ^testing.T) {
// 	panic("TODO: byte_at")
// 	// panic("TODO: rune_at")
// }


// @(test)
// test_gap_buffer_byte_iterator :: proc(t: ^testing.T) {
// 	panic("TODO")
// }


// @(test)
// test_gap_buffer_rune_iterator :: proc(t: ^testing.T) {
// 	panic("TODO")
// }
