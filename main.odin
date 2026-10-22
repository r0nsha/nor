package nor

import "core:fmt"
import "core:io"
import "core:os"

main :: proc() {
	term_enable_raw_mode()
	defer term_disable_raw_mode()

	in_stream := os.to_stream(os.stdin)
	for {
		ch, sz, err := io.read_rune(in_stream)
		if err != nil do continue
		fmt.printf("{}", ch)
	}
}
