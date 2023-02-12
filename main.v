import os
import toml
import cli
import term

const default_config_path = os.join_path_single(os.config_dir()!, 'compass_status.toml')

fn print_default_config(cmd cli.Command)! {
}

fn get_config(path string) !CompassRequestConfig {
	config := os.read_file(path) or {
		return error('failed to read config file at `${path}`')
	}

	doc := toml.parse_text(config) or { return error('failed to parse configuration\n${err}') }

	mut cfg := doc.reflect[CompassRequestConfig]()

	if cfg.refresh_mins == 0 {
		cfg.refresh_mins = 20
	}

	return cfg
}

fn run_status(cmd cli.Command)! {
	config_path := cmd.flags.get_string('config')!

	mut status := CompassStatus{
		cfg: get_config(config_path)!
	}

	status.run()
}

fn left_align(str string, real_len int, padded_len int) string {
	if real_len < padded_len {
		return ' '.repeat(padded_len - real_len) + str
	}
	return str
}

fn run_request(cmd cli.Command)! {
	config_path := cmd.flags.get_string('config')!

	mut status := CompassStatus{
		cfg: get_config(config_path)!
	}

	status.refresh()
	if status.error != '' {
		return error(status.error)
	}
	rlock status.calendar {
		divider := term.dim('|')
		for entry in status.calendar {
			diff := pretty_print_time(entry.finish - entry.start)

			mut class := "${entry.class.name:-7} "

			mut teacher := ""
			mut teacherl := 0

			if entry.class.teacher_old != '' {
				teacher += "${term.strikethrough(term.dim(entry.class.teacher_old))} "
				teacherl += entry.class.teacher_old.len + 1
			}
			teacher += "${entry.class.teacher} "
			teacherl += entry.class.teacher.len + 1
			
			class += left_align(teacher, teacherl, 10)
			class += "${entry.class.room} "
			if entry.class.room_old != '' {
				class += "${term.strikethrough(term.dim(entry.class.room_old))} "
			}

			text := "${diff:4} ${divider} ${entry.start.hhmm()} - ${entry.finish.hhmm()} ${divider} ${class}"
			println(text)
		}

		if status.calendar.len == 0 {
			println("Nothing for today!")
		}
	}
}

fn main() {
	mut app := cli.Command{
		name: 'compass-status'
		description: 'An application to scrape a Compass calendar and display it to a status bar.'
		disable_man: true
		posix_mode: true
		commands: [
			cli.Command{
				name: 'run'
				description: 'Run the status bar.'
				disable_man: true
				posix_mode: true
				execute: run_status
			},
			cli.Command{
				name: 'request'
				description: 'Run a single request, print out diagnostic information.'
				disable_man: true
				posix_mode: true
				execute: run_request
			},
			cli.Command{
				name: 'config'
				description: 'Print out configuration.'
				disable_man: true
				posix_mode: true
				execute: fn (cmd cli.Command)! {
					config_path := cmd.flags.get_string('config')!

					cfg := get_config(config_path)!
					println(cfg)
				}
			},
			cli.Command{
				name: 'print-default'
				description: 'Print an example configuration to stdout.'
				disable_man: true
				posix_mode: true
				execute: print_default_config
			},
		]
		flags: [
			cli.Flag{
				flag: .string
				name: 'config'
				global: true
				default_value: [default_config_path]
			},
		]
	}
	app.setup()
	app.parse(os.args)
}
