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
	url          string
	user_id      int               [toml: 'auth.user_id']
	auth_cookies map[string]string [toml: 'auth.cookies']
	day_offset   int
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
	components := name.split(' - ')

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

	mut req := http.new_request(.post, cfg.url, request_json) or {
		return error('make_request: could not create request!\n\n${err}')
	}

	req.cookies = cfg.auth_cookies.clone()
	req.add_header(.content_type, 'application/json')

	ret := req.do() or { return error('request failed to send (network connection?)\n\n${err}') }

	if ret.status_code != 200 {
		return error('request failed, missing auth cookies? (${ret.status_code}: ${ret.status_msg})')
	}

	mut data := json.decode(RawCalendar, ret.body) or {
		return error('malformed JSON response from server')
	}

	server_date := time.parse_rfc2822(ret.header.get(.date)!)!.add_days(cfg.day_offset)

	// `duration + 1 minute` to account for travel time
	time_discrepancy := (client_date - server_date + time.minute) / time.hour

	mut entries := data.d.map(CalendarEntry{
		name: it.name
		full_name: it.full_name
		start: time.parse_iso8601(it.start)!.add(time_discrepancy * time.hour)
		finish: time.parse_iso8601(it.finish)!.add(time_discrepancy * time.hour)
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
			if now <= entry.finish {
				return idx, Status.during
			}
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

fn (status CompassStatus) status() string {
	now := time.now().add_days(status.cfg.day_offset) // time.parse_iso8601('2023-02-16T03:50:00Z') or { panic(err) }

	if status.error != '' {
		return status.error
	}

	class, state := status.find_current_class(now)

	// <left> -> 10 min -> <right>
	// None -> 34 min -> Homeroom

	mut lhs := ''
	mut rhs := ''
	mut diff := time.Duration(0)

	rlock status.calendar {
		match state {
			.empty {
				return 'No classes!'
			}
			.before {
				next_up := status.calendar[0]

				lhs, diff, rhs = 'Before', next_up.start - now, next_up.name
			}
			.during {
				class_current := status.calendar[class]
				class_next_idx := class + 1

				next_up_name := if class_next_idx >= status.calendar.len {
					'Done with the day!'
				} else {
					status.calendar[class_next_idx].name
				}

				lhs, diff, rhs = class_current.name, class_current.finish - now, next_up_name
			}
			.after {
				return 'Done with the day!'
			}
		}
	}

	return '${lhs} 🠒 ${pretty_print_time(diff)} 🠒 ${rhs}'
}

fn (mut status CompassStatus) run() {
	status.refresh()
	spawn status.refresh_loop()

	for {
		println(status.status())
		time.sleep(500 * time.millisecond)
	}
}
