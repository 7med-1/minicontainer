#!/bin/bash

CGROUP_BASE="/sys/fs/cgroup/minicontainer"

cgroup_create() {
    local name="$1"
    local path="$CGROUP_BASE/$name"

    # Create parent cgroup
    mkdir -p "$CGROUP_BASE" || return 1

    # Enable controllers for children
    echo '+cpu +memory +pids' \
        > "$CGROUP_BASE/cgroup.subtree_control" || return 1

    # Create container cgroup
    mkdir -p "$path" || return 1

    # Apply limits
    echo 104857600 > "$path/memory.max" || return 1
    echo 20 > "$path/pids.max" || return 1
    echo "50000 100000" > "$path/cpu.max" || return 1
}


cgroup_attach() {
    local name="$1"
    local pid="$2"
    local path="$CGROUP_BASE/$name"

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -d "$path" ]] || return 1

    echo "$pid" > "$path/cgroup.procs"
}

cgroup_kill() {
    local name="$1"
    local cg="$CGROUP_BASE/$name"

    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || return 2
    [[ -f "$cg/cgroup.kill" ]] || return 1

    printf '1\n' > "$cg/cgroup.kill" || return 1
}

cgroup_wait_empty() {
    local name="$1"
    local cg="$CGROUP_BASE/$name"
    local attempt

    for ((attempt=0; attempt<30; attempt++)); do
        if [[ -f "$cg/cgroup.events" ]] &&
           grep -qx 'populated 0' "$cg/cgroup.events"; then
            return 0
        fi

        sleep 0.1
    done

    echo "Error: cgroup $name is still populated" >&2
    return 1
}
