import time
import net.http
import json
import strconv

struct RawCalendar {
mut:
	d []RawCalendarEntry
}

struct RawCalendarEntry {
	start             string
	finish            string
	name              string [json: title]
	full_name         string [json: longTitleWithoutTime]
	background_colour string [json: backgroundColor]
}

struct ClassEntry {
	name        string
	room        string
	room_old    string
	teacher     string
	teacher_old string
}

struct CalendarEntry {
	name      string
	full_name string
	start     time.Time
	finish    time.Time
	class     ClassEntry
	colour    int
}

struct CompassRequestConfig {
	url                    string
	user_id                int               [toml: 'auth.user_id']
	auth_cookies           map[string]string [toml: 'auth.cookies']
	day_offset             int
	msg_no_classes         string            [toml: 'messages.no_classes']
	msg_before_all_classes string            [toml: 'messages.before_all_classes']
	msg_after_all_classes  string            [toml: 'messages.after_all_classes']
	msg_recess             string            [toml: 'messages.recess']
mut:
	refresh_mins int
}

struct CompassStatus {
	cfg CompassRequestConfig
mut:
	calendar shared []CalendarEntry
	error    string
}

// (room, old room)
fn handle_changes(name string) (string, string) {
	if name.starts_with('<strike>') {
		return name.all_after('&nbsp; '), name.all_after('<strike>').all_before('</strike>')
	}
	return name, ''
}

fn parse_into_class_entry(name string) ClassEntry {
	mut components := name.split(' - ')
	if components.len == 2 {
		components << components[1].split(', ')
	}

	room, room_old := handle_changes(components[1])
	teacher, teacher_old := handle_changes(components[2])

	return ClassEntry{
		name: components[0]
		room: room
		room_old: room_old
		teacher: teacher
		teacher_old: teacher_old
	}
}

fn make_request(cfg CompassRequestConfig) ![]CalendarEntry {
	client_date := time.now().add_days(cfg.day_offset)
	formatted_date := client_date.get_fmt_date_str(.hyphen, .yyyymmdd)

	request_json := '{"userId":${cfg.user_id},"startDate":"${formatted_date}","endDate":"${formatted_date}","page":1,"start":0,"limit":25}'

	mut req := http.new_request(.post, cfg.url, request_json) or { panic('unreachable') }

	req.cookies = cfg.auth_cookies.clone()
	req.add_header(.content_type, 'application/json')

	ret := req.do() or { return error('request failed to send (network connection?) ${err}') }

	if ret.status_code != 200 {
		return error('request failed, missing auth cookies? (${ret.status_code}: ${ret.status_msg})')
	}

	mut data := json.decode(RawCalendar, ret.body) or {
		return error('malformed JSON response from server')
	}

	server_date := time.parse_rfc2822(ret.header.get(.date)!)!.add_days(cfg.day_offset)

	// `duration - 1 minute` to account for travel time
	hr_discrepancy := (time.now() - server_date + time.minute) / time.hour

	mut entries := data.d.map(CalendarEntry{
		name: it.name
		full_name: it.full_name
		start: time.parse_iso8601(it.start)!.add(hr_discrepancy * time.hour)
		finish: time.parse_iso8601(it.finish)!.add(hr_discrepancy * time.hour)
		colour: int(strconv.common_parse_int(it.background_colour[1..], 16, 32, true,
			true)!)
		class: parse_into_class_entry(it.full_name)
	})
	entries.sort(a.start < b.start)

	return entries
}

fn (mut status CompassStatus) refresh() {
	lock status.calendar {
		entries := make_request(status.cfg) or {
			status.error = err.str()
			status.calendar.clear()
			return
		}

		status.error = ''
		status.calendar = entries
	}
}

fn (mut status CompassStatus) refresh_loop() {
	for {
		time.sleep(status.cfg.refresh_mins * time.minute)
		status.refresh()
	}
}

enum Status {
	empty
	before
	recess
	during
	after
}

fn (status CompassStatus) find_current_class(now time.Time) (int, Status) {
	rlock status.calendar {
		// No classes for today.
		if status.calendar.len == 0 {
			return -1, Status.empty
		}
		// Before all classes.
		if now < status.calendar[0].start {
			return -1, Status.before
		}

		// During a current class.
		for idx, entry in status.calendar {
			if now <= entry.finish && now >= entry.start {
				return idx, Status.during
			}
		}

		// Still inside calendar, but not inside a current event.
		if now < status.calendar.last().finish {
			return -1, Status.recess
		}
	}
	// After all classes.
	return -1, Status.after
}

// TODO: configure the current message retured whilst being in a certain state
//
// TODO: ablity to configure status messages, the left hand side and right hand side.
//       a programatic way, like string interp, to construct them.
//
// TODO: the status message must be padded on both sides, to ensure that the
//       elapsed time is centered!

fn pretty_print_time(current_time time.Duration) string {
	if current_time > time.hour {
		return '${current_time / time.hour}h'
	}
	if current_time > time.minute {
		return '${current_time / time.minute}m'
	}
	return '${current_time / time.second}s'
}

fn generate_next_up(class ClassEntry) string {
	mut ret := '${class.name} (${class.room}'
	if class.room_old != '' {
		ret += ', old ${class.room_old}'
	}
	ret += ' + ${class.teacher}'
	if class.teacher_old != '' {
		ret += ', old ${class.teacher_old}'
	}
	ret += ')'

	return ret
}

fn (status CompassStatus) status() string {
	now := time.now() //.add(-8 * time.hour) //.add_days(status.cfg.day_offset)

	if status.error != '' {
		return status.error
	}

	class, state := status.find_current_class(now)

	// <left> -> 10 min -> <right>
	// None -> 34 min -> Homeroom

	mut lhs := ''
	mut rhs := ''
	mut diff := time.Duration(0)

	// msg_no_classes
	// msg_before_all_classes
	// msg_after_all_classes
	// msg_recess

	rlock status.calendar {
		match state {
			.empty {
				return status.cfg.msg_no_classes
			}
			.before {
				next_up := status.calendar[0]

				lhs, diff, rhs = status.cfg.msg_before_all_classes, next_up.start - now, generate_next_up(next_up.class)
			}
			.during {
				class_current := status.calendar[class]
				class_next_idx := class + 1

				next_up_name := if class_next_idx >= status.calendar.len {
					status.cfg.msg_after_all_classes
				} else {
					generate_next_up(status.calendar[class_next_idx].class)
				}

				lhs, diff, rhs = generate_next_up(class_current.class), class_current.finish - now, next_up_name
			}
			.recess {
				return status.cfg.msg_recess
			}
			.after {
				return status.cfg.msg_after_all_classes
			}
		}
	}

	return '${lhs} - ${pretty_print_time(diff)} - ${rhs}'
}

fn (mut status CompassStatus) run() {
	status.refresh()
	spawn status.refresh_loop()

	for {
		println(status.status())
		time.sleep(500 * time.millisecond)
	}
}
