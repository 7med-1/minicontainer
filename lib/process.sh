#!/bin/bash

execute_command() {

	local name="$1"
	shift

	"$@" &

	local pid=$!


	if ! process_save_pid "$name" "$pid"; then
		echo "Error: faild to save the process stat" >&2
		return 1
	fi

	echo "Process PID: $pid"
}


process_save_pid() {

	local name="$1"
    local pid="$2"
	local starttime
	local process_dir="$MC_STATE_DIR/$name" 

	mkdir -p "$process_dir" || return 1

	starttime=$(process_get_starttime "$pid") || return 1

	printf '%s\n' "$pid" > "$process_dir/pid" || return 1
	printf '%s\n' "$starttime" > "$process_dir/starttime" || return 1
}

process_get_starttime() {

	local pid="$1"

	[[ -r "/proc/$pid/stat" ]] || return 1

	awk '{print $22}' "/proc/$pid/stat" 

}

process_is_same() {
    local pid="$1"
    local expected_starttime="$2"
    local current_starttime

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$expected_starttime" =~ ^[0-9]+$ ]] || return 1

    current_starttime=$(process_get_starttime "$pid") || return 1

    [[ "$current_starttime" == "$expected_starttime" ]] || return 1

    kill -0 "$pid" 2>/dev/null
}


process_stop() {
    local name="$1"
    local state_dir="$MC_STATE_DIR/$name"
    local pid saved_starttime

    [[ -d "$state_dir" ]] || return 1

    read -r pid < "$state_dir/pid" || return 1
    read -r saved_starttime < "$state_dir/starttime" || return 1

	if ! process_is_same "$pid" "$saved_starttime"; then
	    echo "Process is not running or identity changed" >&2
	    return 1
	fi
	    
    kill -TERM "$pid" || return 1
	echo "process is killed"
    
}



process_stop_namespace() {
    local name="$1"
    local dir="$MC_STATE_DIR/$name"
    local pid starttime 

    [[ -f "$dir/pid" && -f "$dir/starttime" ]] || return 1

    read -r pid < "$dir/pid" || return 1
    read -r starttime < "$dir/starttime" || return 1

    if ! process_is_same "$pid" "$starttime"; then
        echo "Container is stopped or identity changed" >&2
        return 1
    fi

    # Only after process_is_same has verified PID and starttime
    kill -KILL "$pid" || return 1

    local cg="$CGROUP_BASE/$name"
    
    if [[ -d "$cg" ]]; then
        cgroup_kill "$name" || return 1
        cgroup_wait_empty "$name" || return 1
    else
        kill -KILL "$pid" || return 1
    fi
    
    echo "Container stopped: $name"
    
    # Don't claim success until termination is verified
    for attempt in {1..20}; do
        if ! process_is_same "$pid" "$starttime"; then
            echo "Container stopped: $name"
            return 0
        fi
        sleep 0.1
    done
    
    echo "Error: container did not stop" >&2
    return 1
}
