#!/bin/bash

namespace_launch() {
    local name="$1"
    shift
    
    local state_dir="$MC_STATE_DIR/$name"
    local fifo="$state_dir/ready"
    
    mkdir -p "$state_dir" || return 1
    
    # Remove a FIFO left by a previous failed launch
    if [[ -p "$fifo" ]]; then
        rm "$fifo" || return 1
    fi
    
    mkfifo -m 600 "$fifo" || return 1

    cgroup_create "$name" || return 1

    unshare \
        --pid --fork --net --mount --mount-proc --uts --kill-child \
        -- bash ./lib/container-init.sh "$MC_ROOTFS" "$fifo" "$@" &

    local launcher_pid=$!

    printf 'launcher PID: %s\n' "$launcher_pid"

    local child_pid=""
    
    for attempt in {1..30}; do
        if [[ -r "/proc/$launcher_pid/task/$launcher_pid/children" ]]; then
            read -r child_pid < \
                "/proc/$launcher_pid/task/$launcher_pid/children"
        fi
    
        [[ -n "$child_pid" ]] && break
    
        sleep 0.05
    done

    if [[ ! "$child_pid" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: failed to discover namespace child" >&2
        kill "$launcher_pid" 2>/dev/null
        return 1
    fi


	if ! cgroup_attach "$name" "$child_pid"; then
	    echo "Error: cgroup attachment failed" >&2
	    kill -KILL "$child_pid" 2>/dev/null
	    rm -f "$fifo"
	    return 1
	fi 
	     

    # Verify it really entered a nested PID namespace
    local nspid_line
    nspid_line=$(grep '^NSpid:' "/proc/$child_pid/status") || return 1
    
    printf 'Namespace PID mapping: %s\n' "$nspid_line"
    
    # Save the actual child PID and its start time
    if ! process_save_pid "$name" "$child_pid"; then
        echo "Error: failed to save container state" >&2
        kill "$launcher_pid" 2>/dev/null
        return 1
    fi
    
    # Also save launcher PID for later cleanup
    local state_dir="$MC_STATE_DIR/$name"
    printf '%s\n' "$launcher_pid" > "$state_dir/launcher_pid" || return 1
    
    printf 'Container host PID: %s\n' "$child_pid"

    printf 'GO\n' > "$fifo"
    
}


namespace_exec() {
    local pid="$1"
    shift

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1

    nsenter \
        --target "$pid" \
        --mount --pid --uts --net \
        --root="/proc/$pid/root" \
        --wd=/ \
        -- "$@"
}
