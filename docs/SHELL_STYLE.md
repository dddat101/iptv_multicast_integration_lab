# Shell Style

- Use Bash with `set -Eeuo pipefail` and a controlled `IFS`.
- Source `config.env` through `scripts/lib/common.sh`.
- Validate physical interfaces before changing them.
- Never touch loopback or the management/default-route interface.
- Never flush global nftables/iptables state.
- Never replace the host default route.
- Setup must be bounded and rollback on failure.
- Cleanup must be safe to run more than once.
- Docker application containers must use `--network none`; attach them explicitly with veth pairs.
- Keep packet generation in real applications/protocol stacks; shell scripts only orchestrate.
