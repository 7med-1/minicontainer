# MiniContainer

MiniContainer is a small Bash project for learning how Linux containers work. It starts a command in separate PID, network, mount and UTS namespaces, changes its root filesystem with `chroot`, applies cgroup v2 resource limits, and can connect it to a Linux bridge.

This is an experimental learning tool, not a production container runtime. Use it only on a disposable Linux machine or VM with trusted commands and a trusted root filesystem. It needs root privileges, does not create a user namespace or drop capabilities, and does not provide the security controls expected from a production runtime.

## Requirements

- Linux with `/proc`, namespaces, and a writable cgroup v2 hierarchy. The `cpu`, `memory`, and `pids` controllers must be available and delegated to the MiniContainer cgroup parent by the host.
- Bash, `unshare`, `nsenter`, `mount`, `chroot`, `ip` (iproute2), and common utilities such as `awk`, `grep`, and `mkdir`.
- Root privileges and permission to create namespaces, cgroups, network interfaces and mounts. Running inside another container or under restrictive host policies may prevent this.
- An existing Linux root filesystem at `/var/lib/minicontainer/rootfs/alpine`, containing the command you want to run and its dependencies. It must also contain a `proc` directory. Despite the path name, MiniContainer does not download or build Alpine for you.

Run commands from the project directory: `mc` loads its scripts using paths relative to the current directory. Examples below use `sudo`; use a root shell if that is more suitable for your system.

```bash
cd /path/to/minicontainer
sudo ./mc help
```

The root filesystem is **shared by all containers**. Changes made inside one container persist on the host in that directory and are visible to the others. Do not point it at data you cannot afford to change.

## Quick start

First prepare the root filesystem separately and verify that it includes `/bin/sh`, `sleep`, and `/proc`. Then:

```bash
# Keep a container alive for 10 minutes.
sudo ./mc run demo /bin/sleep 600

# Show its host PID and status.
sudo ./mc ps

# Run a second command inside its namespaces and root filesystem.
sudo ./mc exec demo /bin/sh -c 'echo hello; ls /'

# Stop the container and remove its saved state and empty cgroup.
sudo ./mc stop demo
sudo ./mc rm demo
```

`run` starts the command in the background; it does not provide a managed interactive session. The container lasts only while its initial command runs. If that command exits, `ps` can show it as stopped; remove its saved state with `rm`. Use a simple unique name made of letters, digits, underscores and hyphens, starting with a letter or digit. Avoid reusing a name until its old container has been removed: `run` does not reliably reject duplicate or unsafe names.

Commands passed to `run` and `exec` are executed directly, not through a shell. To use pipes, redirection, or shell expansion inside the container, explicitly run `/bin/sh -c '...'` as in the example. The programs and libraries must exist in the root filesystem.

## Commands

| Command | Purpose |
| --- | --- |
| `sudo ./mc run NAME COMMAND [ARGS...]` | Start a command in a new container. |
| `sudo ./mc ps` | List saved containers, their host PID, status, and process start time. |
| `sudo ./mc exec NAME COMMAND [ARGS...]` | Run a command in a running container's namespaces and root filesystem. |
| `sudo ./mc stop NAME` | Disconnect the container from managed networks and forcefully stop its processes. |
| `sudo ./mc rm NAME` | Remove a stopped container's state and empty cgroup. |
| `sudo ./mc rm --all-stopped` | Remove all stopped containers that can be safely removed. |
| `sudo ./mc network create NAME --subnet 10.X.Y.0/24` | Create a bridge network with gateway `10.X.Y.1`. |
| `sudo ./mc network connect NETWORK CONTAINER` | Connect a running container and allocate an address. |
| `sudo ./mc network tree` | Show managed bridges and saved container addresses. |
| `sudo ./mc network disconnect NETWORK CONTAINER` | Disconnect a container and release its saved address. |
| `sudo ./mc network rm NAME` | Remove an empty managed network. |

The built-in help lists only some commands; the table above reflects the command dispatcher in `mc`.

## Networking

Containers start in a separate network namespace. Create a bridge and connect running containers when they need to communicate:

```bash
sudo ./mc run web /bin/sleep 600
sudo ./mc run client /bin/sleep 600
sudo ./mc network create lab --subnet 10.42.0.0/24
sudo ./mc network connect lab web
sudo ./mc network connect lab client
sudo ./mc network tree
```

The bridge receives `.1`; container addresses are allocated from `.2` through `.254`. The connect command prints each address. The root filesystem needs appropriate client or server programs for useful communication. Host firewall rules may affect connectivity. A container can have only one managed connection because the code refuses to add another `eth0`.

MiniContainer does not configure a default route, DNS, NAT, port publishing, or internet access. Connecting to a bridge alone does not provide those features. Stop and remove containers, then remove the empty network when finished:

```bash
sudo ./mc stop web
sudo ./mc stop client
sudo ./mc rm web
sudo ./mc rm client
sudo ./mc network rm lab
```

## Configuration and resource limits

Configuration is currently edited in source files, not supplied as CLI flags:

| Setting | Default | File |
| --- | --- | --- |
| State directory | `/run/minicontainer` | `lib/config.sh` |
| Root filesystem | `/var/lib/minicontainer/rootfs/alpine` | `lib/config.sh` |
| Network state | `/run/minicontainer/networks` | `lib/config.sh` |
| Cgroup parent | `/sys/fs/cgroup/minicontainer` | `lib/cgroups.sh` |
| Memory limit | 100 MiB (`104857600` bytes) | `lib/cgroups.sh` |
| Process limit | 20 tasks | `lib/cgroups.sh` |
| CPU limit | `50000 100000` (half of one CPU's time) | `lib/cgroups.sh` |

Limits apply to the container cgroup; adjust them in `lib/cgroups.sh` before starting a container if the workload needs more resources. The host must allow the controllers to be enabled. State under `/run` is normally temporary and may disappear on reboot; the shared root filesystem is separate and remains on disk.

## How it works

1. `mc` dispatches a command to the scripts in `lib/`.
2. `lib/namespaces.sh` creates a FIFO and cgroup, starts `unshare`, finds the namespace child, attaches it to the cgroup, records its PID and start time, then signals it to continue.
3. `lib/container-init.sh` makes mount propagation private, mounts `/proc` in the root filesystem, and runs the requested command using `chroot`.
4. `exec` uses `nsenter` to join the saved process's namespaces. The saved start time helps detect PID reuse when checking whether the process is still the original one.
5. Networking uses a host bridge and a veth pair; saved state tracks allocated addresses and interface names.

## Troubleshooting and limitations

- **Namespace or mount operation fails:** check that you are root and that the host or enclosing container permits `unshare`, mounts, and the required capabilities.
- **Cgroup creation or controller setup fails:** check that cgroup v2 is mounted and writable, and that the host has made the `cpu`, `memory`, and `pids` controllers available to the parent. Systemd or another cgroup manager may impose additional constraints.
- **Command fails to start:** check that the root filesystem has `/proc`, the executable, its interpreter and any required shared libraries. `run` launches asynchronously, so successful launch output does not guarantee the command stayed running; check `ps`.
- **Network setup fails:** check for conflicting bridge names or subnets, interface name limits, host networking permissions, and firewall rules. Use a short network name. Only `10.x.x.0/24`-shaped subnets are accepted; choose valid IPv4 octets and a non-overlapping subnet yourself.
- **Cleanup fails or state looks inconsistent:** failed launches or network operations can leave partial state or host resources. Inspect `/run/minicontainer`, the cgroup tree, and host interfaces before making changes. `stop` kills processes rather than shutting them down gracefully. `rm` refuses to remove a running container or one still recorded as network-connected.
- **Isolation is incomplete:** containers share the same writable root filesystem, and the project has no image management, private user identities, capability dropping, seccomp profile, persistent storage management, or built-in logging. It is intended for exploration with trusted workloads.

## Development

The entry point is `mc`; each file in `lib/` handles one part of the runtime. A quick syntax check requires no root privileges:

```bash
bash -n mc lib/*.sh
```

Testing actual namespace, cgroup and network behavior requires a suitably configured Linux host and root privileges. Prefer a disposable VM for experiments, and clean up the containers and networks you created when finished.
