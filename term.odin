package nor

import "base:runtime"
import "core:fmt"
import "core:sys/posix"
import "core:terminal/ansi"

@(private = "file")
orig_mode: posix.termios

@(private = "file")
raw_mode_active := false

term_enable_raw_mode :: proc() {
	if raw_mode_active do return

	res := posix.tcgetattr(posix.STDIN_FILENO, &orig_mode)
	assert(res == .OK)

	raw := orig_mode
	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag += {.OPOST}
	raw.c_cflag += {.CS8}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN} // Also .ISIG. Handle SIGINT and SIGTSTP
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 1

	res = posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)
	assert(res == .OK)

	fmt.print(ansi.CSI + ansi.DECASB_ENTER)
	fmt.print(ansi.CSI + "1;1" + ansi.CUP)

	deadly_signal :: proc "c" (sig: posix.Signal) {
		term_disable_raw_mode()

		action := posix.sigaction_t {
			sa_handler = auto_cast posix.SIG_DFL,
		}
		posix.sigemptyset(&action.sa_mask)
		posix.sigaction(sig, &action, nil)
		posix.raise(sig)
	}

	action := posix.sigaction_t {
		sa_handler = deadly_signal,
	}
	posix.sigemptyset(&action.sa_mask)
	sigs := []posix.Signal{.SIGTERM, .SIGINT, .SIGHUP}
	for sig in sigs {
		assert(posix.sigaction(sig, &action, nil) == .OK)
	}

	raw_mode_active = true
}

term_disable_raw_mode :: proc "c" () {
	if !raw_mode_active do return

	context = runtime.default_context()
	fmt.print(ansi.CSI + ansi.DECASB_EXIT)
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &orig_mode)
	raw_mode_active = false
}
