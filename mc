#!/bin/bash

source ./lib/config.sh
source ./lib/process.sh
source ./lib/namespaces.sh
source ./lib/cgroups.sh
source ./lib/network.sh

run_container() {
	if [[ $# -lt 2 || -z "$1" || -z "$2" ]]; then
		echo "Error: run requires NAME and COMMAND" >&2
		return 2
	else
		local name="$1"
		echo "Container name: $1"
		echo

		shift
		local command="$1"
		echo "Command: $1"

		shift
		echo
		local args=("$@")
		printf 'Argument: <%s>\n' "${args[@]}"


		namespace_launch "$name" "$command" "${args[@]}"
	fi
}


stop_container() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: ./mc stop NAME" >&2
        return 2
    fi

    local name="$1"

    network_disconnect_container "$name" || return 1

    process_stop_namespace "$name"
}

list_containers() {

	local dir name pid status

	printf '%-15s %-10s %-12s %s\n' \
	    "NAME" "PID" "STATUS" "STARTTIME"
	for dir in "$MC_STATE_DIR"/*/; do

		[[ -d "$dir" ]] || continue
		name=$(basename "$dir")
		if [[ ! -f "$dir/pid" ]]; then
			continue
		fi

		read -r pid < "$dir/pid" || continue

		[[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue

		local saved_starttime status

		if [[ -f "$dir/starttime" ]]; then
		    read -r saved_starttime < "$dir/starttime" || continue
		else
		    saved_starttime=""
		fi

		if process_is_same "$pid" "$saved_starttime"; then
		    status="RUNNING"
		else
		    status="STOPPED"
		fi

		printf '%-15s %-10s %-12s %s\n' \
		    "$name" "$pid" "$status" "$saved_starttime"
	done

	echo

}

exec_container() {


    if [[ $# -lt 2 ]]; then
        echo "Usage: ./mc exec NAME COMMAND [ARGS...]" >&2
        return 2
    fi
    name="$1"
    shift

    if [[ ! "$name" =~ ^[a-zA-z0-9][a-zA-Z0-9_-]*$ ]]; then
    	echo "Error: invalide container name" >&2
    	return 2
    fi

    local state_dir="$MC_STATE_DIR/$name"
    local pid starttime

    if [[ ! -f "$state_dir/pid" || ! -f "$state_dir/starttime" ]]; then
            echo "Error: container '$name' not found" >&2
            return 1
    fi

    read -r pid < "$state_dir/pid" || return 1
    read -r starttime < "$state_dir/starttime" || return 1

    if ! process_is_same "$pid" "$starttime"; then
    	echo "Error: container '$name' is not running" >&2
     	return 1
    fi
    namespace_exec "$pid" "$@"
}

network_command() {
    local action="$1"
    shift

    case "$action" in
        create)
            [[ $# -eq 3 && "$2" == "--subnet" ]] || return 2
            network_create "$1" "$3"
            ;;

        connect)
            [[ $# -eq 2 ]] || {
                echo "Usage: mc network connect NETWORK CONTAINER" >&2
                return 2
            }
            network_connect "$1" "$2"
            ;;
        tree)
        	network_tree
        	;;
       	disconnect)
       	    [[ $# -eq 2 ]] || return 2
       	    network_disconnect "$1" "$2"
       	    ;;
       	rm)
       		[[ $# -eq 1 ]] || return 1
       		network_remove "$1"
       		;;
        *)
            echo "Unknown network command: $action" >&2
            return 2
            ;;
    esac
}

remove_container() {
    [[ $# -eq 1 ]] || {
        echo "Usage: mc rm NAME" >&2
        return 2
    }

    local name="$1"
    local dir="$MC_STATE_DIR/$name"
    local cg="$CGROUP_BASE/$name"
    local pid starttime

    # Prevent invalid paths
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || return 2

    [[ -f "$dir/pid" && -f "$dir/starttime" ]] || {
        echo "Error: container not found" >&2
        return 1
    }

    read -r pid < "$dir/pid" || return 1
    read -r starttime < "$dir/starttime" || return 1

    # Refuse to remove running containers
    if process_is_same "$pid" "$starttime"; then
        echo "Error: stop the container first" >&2
        return 1
    fi

    # Refuse removal while network membership exists
    local netdir
    for netdir in "$MC_NETWORK_DIR"/*/; do
        [[ -d "$netdir" ]] || continue

        if [[ -e "$netdir/containers/$name" ]]; then
            echo "Error: disconnect the container first" >&2
            return 1
        fi
    done

    if [[ -d "$cg" ]]; then
        cgroup_wait_empty "$name" || return 1
        rmdir "$cg" || return 1
    fi

    # Remove cgroup only when empty
    if [[ -d "$cg" ]]; then
        rmdir "$cg" || {
            echo "Error: cgroup still contains processes" >&2
            return 1
        }
    fi

    # Remove saved state
    rm -r -- "$dir" || return 1

    echo "Removed container: $name"
}

remove_all_stopped() {
    local dir name pid starttime

    for dir in "$MC_STATE_DIR"/*/; do
        [[ -f "$dir/pid" && -f "$dir/starttime" ]] || continue

        name=$(basename "$dir")

        read -r pid < "$dir/pid" || continue
        read -r starttime < "$dir/starttime" || continue

        if ! process_is_same "$pid" "$starttime"; then
            remove_container "$name" || return 1
        fi
    done
}

show_help() {
    echo MiniContainer CLI
    echo
    echo 'Usage:
	./mc run
	./mc stop
	./mc ps
	./mc help
'
}

case $1 in 
	run)
		shift 
		run_container "$@"
	;;
	exec)
	    shift
	    exec_container "$@"
	;;
	stop)
		shift
		stop_container "$@"
	;;
	ps)
		list_containers
	;;
	help)
		show_help
	;;
	network)
	    shift
	    network_command "$@"
	;;
	rm)
	    shift
	    if [[ "${1:-}" == "--all-stopped" && $# -eq 1 ]]; then
	        remove_all_stopped
	    else
	        remove_container "$@"
	    fi
	;;
	*)
		show_help
	;;
esac
