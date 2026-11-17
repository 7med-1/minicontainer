#!/bin/bash

network_create() {
    local name="$1"
    local subnet="$2"

    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 2

    local bridge="br-$name"
    local dir="$MC_NETWORK_DIR/$name"

    # MVP: support 10.x.x.0/24 networks only
    if [[ ! "$subnet" =~ ^(10\.[0-9]{1,3}\.[0-9]{1,3})\.0/24$ ]]; then
        echo "Error: expected a 10.x.x.0/24 subnet" >&2
        return 2
    fi

    local prefix="${BASH_REMATCH[1]}"
    local gateway="$prefix.1/24"

    [[ ! -e "$dir" ]] || {
        echo "Error: network already exists" >&2
        return 1
    }

    mkdir -p "$dir/containers" || return 1

    ip link add "$bridge" type bridge || return 1
    ip addr add "$gateway" dev "$bridge" || return 1
    ip link set "$bridge" up || return 1

    printf '%s\n' "$subnet" > "$dir/subnet"
    printf '%s\n' "$gateway" > "$dir/gateway"
    printf '%s\n' "$bridge" > "$dir/bridge"

    echo "Created network: $name"
}


network_command() {
    local action="$1"
    shift

    case "$action" in
        create)
            if [[ $# -ne 3 || "$2" != "--subnet" ]]; then
                echo "Usage: mc network create NAME --subnet CIDR" >&2
                return 2
            fi

            network_create "$1" "$3"
            ;;
        *)
            echo "Unknown network command: $action" >&2
            return 2
            ;;
    esac
}

network_allocate_ip() {
    local network="$1"
    local dir="$MC_NETWORK_DIR/$network"
    local subnet prefix candidate used file i

    [[ -f "$dir/subnet" ]] || return 1

    read -r subnet < "$dir/subnet"
    prefix="${subnet%.0/24}"

    for ((i=2; i<=254; i++)); do
        candidate="$prefix.$i"
        used=0

        for file in "$dir"/containers/*; do
            [[ -f "$file" ]] || continue
            [[ "$file" == *.veth ]] && continue

            if [[ "$(<"$file")" == "$candidate" ]]; then
                used=1
                break
            fi
        done

        if (( used == 0 )); then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    echo "Error: no available IP addresses" >&2
    return 1
}
network_connect() {
    local network="$1"
    local name="$2"

    local dir="$MC_NETWORK_DIR/$network"
    local state_dir="$MC_STATE_DIR/$name"
    local pid starttime container_ip bridge host_veth

    [[ "$network" =~ ^[a-zA-Z0-9_-]+$ ]] || return 2
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 2

    [[ -f "$dir/bridge" && -f "$state_dir/pid" &&
       -f "$state_dir/starttime" ]] || return 1

    [[ ! -e "$dir/containers/$name" ]] || {
        echo "Container already connected" >&2
        return 1
    }

    read -r pid < "$state_dir/pid"
    read -r starttime < "$state_dir/starttime"
    read -r bridge < "$dir/bridge"

    process_is_same "$pid" "$starttime" || return 1

    # Refuse containers that already have eth0
    if nsenter -t "$pid" -n -- ip link show eth0 &>/dev/null; then
        echo "Container already has eth0" >&2
        return 1
    fi

    container_ip=$(network_allocate_ip "$network") || return 1

    # Unique interface name (Linux limit: 15 characters)
    host_veth="vm${pid}"
    host_veth="${host_veth:0:15}"

    ip link add "$host_veth" type veth peer name mcpeer || return 1

    # Configure host endpoint
    ip link set "$host_veth" master "$bridge" || return 1
    ip link set "$host_veth" up || return 1

    # Move peer into container
    ip link set mcpeer netns "$pid" || return 1

    nsenter -t "$pid" -n -- ip link set mcpeer name eth0 || return 1
    nsenter -t "$pid" -n -- ip addr add "$container_ip/24" dev eth0 || return 1
    nsenter -t "$pid" -n -- ip link set eth0 up || return 1
    nsenter -t "$pid" -n -- ip link set lo up || return 1

    printf '%s\n' "$container_ip" > "$dir/containers/$name"

    echo "Connected $name to $network ($container_ip)"

    printf '%s\n' "$host_veth" > "$dir/containers/$name.veth"
}

network_tree() {
    local dir network bridge gateway file name ip

    echo "Host"

    for dir in "$MC_NETWORK_DIR"/*/; do
        [[ -d "$dir" ]] || continue

        network=$(basename "$dir")

        [[ -f "$dir/bridge" && -f "$dir/gateway" ]] || continue

        read -r bridge < "$dir/bridge"
        read -r gateway < "$dir/gateway"

        printf '├── %s  %s\n' "$bridge" "$gateway"

        for file in "$dir"/containers/*; do
            [[ -f "$file" ]] || continue
            [[ "$file" == *.veth ]] && continue
        
            name=$(basename "$file")
            read -r ip < "$file"
        
            printf '│   ├── %-15s %s\n' "$name" "$ip"
        done
    done
}



network_disconnect() {
    local network="$1"
    local name="$2"
    local dir="$MC_NETWORK_DIR/$network/containers"
    local host_veth

    [[ "$network" =~ ^[a-zA-Z0-9_-]+$ ]] || return 2
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 2

    [[ -f "$dir/$name" && -f "$dir/$name.veth" ]] || {
        echo "Error: connection not found" >&2
        return 1
    }

    read -r host_veth < "$dir/$name.veth"

    # Delete host endpoint (also removes container endpoint)
    ip link delete "$host_veth" || return 1

    # Release saved IP allocation
    rm -f "$dir/$name" "$dir/$name.veth"

    echo "Disconnected $name from $network"
}


network_remove() {
    local name="$1"
    local dir="$MC_NETWORK_DIR/$name"
    local bridge file

    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 2
    [[ -f "$dir/bridge" ]] || return 1

    # Check for connected containers
    for file in "$dir"/containers/*; do
        [[ -f "$file" ]] || continue
        [[ "$file" == *.veth ]] && continue

        echo "Error: network has connected containers" >&2
        return 1
    done

    read -r bridge < "$dir/bridge"

    ip link delete "$bridge" || return 1
    rm -r "$dir" || return 1

    echo "Removed network: $name"
}

network_disconnect_container() {
    local name="$1"
    local dir network

    for dir in "$MC_NETWORK_DIR"/*/; do
        [[ -d "$dir" ]] || continue

        network="${dir%/}"
        network="${network##*/}"

        if [[ -f "$dir/containers/$name" ]]; then
            network_disconnect "$network" "$name" || return 1
        fi
    done
}
