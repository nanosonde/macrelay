set shell := ["bash", "-euo", "pipefail", "-c"]

e2e := justfile_directory() + "/e2e-testing"
openwrt_version := env_var_or_default("E2E_OPENWRT_VERSION", "25.12.5")
openwrt_image := "openwrt-" + openwrt_version + "-x86-64-generic-ext4-combined.img.gz"

# Show the available recipes.
default:
    @just --list

# ---------------------------------------------------------------------
# lifecycle
# ---------------------------------------------------------------------

# Build images, start the lab and wait until the guest answers.
e2e-up: e2e-preflight e2e-keys e2e-stage e2e-fetch-image
    cd {{e2e}} && docker compose build
    cd {{e2e}} && docker compose up -d
    just e2e-wait

# Check the lab subnets against the ones the host already uses.
e2e-preflight:
    {{e2e}}/scripts/preflight.sh

# Block until every service and the OpenWrt guest are ready.
e2e-wait:
    {{e2e}}/scripts/wait-ready.sh

# Stop the lab, keeping the guest disk and the downloaded image.
e2e-down:
    cd {{e2e}} && docker compose down --remove-orphans

# Stop the lab and discard all state, including the guest disk.
e2e-destroy:
    cd {{e2e}} && docker compose down --remove-orphans --volumes
    rm -rf {{e2e}}/artifacts/ssh

# Restart a single service, e.g. `just e2e-restart router`.
e2e-restart service:
    cd {{e2e}} && docker compose restart {{service}}

# Reboot the OpenWrt guest.
e2e-reboot:
    -{{e2e}}/scripts/vm-ssh.sh reboot
    just e2e-wait

# ---------------------------------------------------------------------
# setup helpers
# ---------------------------------------------------------------------

# Generate the throwaway SSH key the harness uses to reach the guest.
e2e-keys:
    mkdir -p {{e2e}}/artifacts/ssh
    if [[ ! -f {{e2e}}/artifacts/ssh/id_ed25519 ]]; then \
        ssh-keygen -t ed25519 -N '' -C macrelay-e2e \
            -f {{e2e}}/artifacts/ssh/id_ed25519; \
    fi
    chmod 600 {{e2e}}/artifacts/ssh/id_ed25519

# Stage macrelay.sh so it is baked into the guest image on first boot.
e2e-stage:
    mkdir -p {{e2e}}/artifacts
    cp {{justfile_directory()}}/macrelay.sh {{e2e}}/artifacts/macrelay.sh

# Download the OpenWrt image on the host, where DNS is known to work.
e2e-fetch-image:
    mkdir -p {{e2e}}/artifacts
    if [[ ! -s {{e2e}}/artifacts/{{openwrt_image}} ]]; then \
        curl -fL --retry 3 -o {{e2e}}/artifacts/{{openwrt_image}} \
            https://downloads.openwrt.org/releases/{{openwrt_version}}/targets/x86/64/{{openwrt_image}}; \
    fi

# Rebuild the container images without starting anything.
e2e-build:
    cd {{e2e}} && docker compose build

# ---------------------------------------------------------------------
# working with the guest
# ---------------------------------------------------------------------

# Copy the current macrelay.sh into the guest and restart the service.
e2e-deploy: e2e-stage
    {{e2e}}/scripts/deploy.sh {{justfile_directory()}}/macrelay.sh

# Run the end-to-end assertions.
e2e-test:
    {{e2e}}/scripts/smoke-test.sh

# Interactive shell on the OpenWrt guest.
e2e-ssh:
    {{e2e}}/scripts/vm-ssh.sh

# Run a single command on the guest, e.g. `just e2e-run 'ip -6 rule show'`.
e2e-run command:
    {{e2e}}/scripts/vm-ssh.sh {{quote(command)}}

# Attach to the guest serial console (ctrl-] to leave).
e2e-console:
    telnet localhost ${E2E_CONSOLE_PORT:-2323}

# ---------------------------------------------------------------------
# observation
# ---------------------------------------------------------------------

# Container status plus what MacRelay has provisioned so far.
e2e-status:
    {{e2e}}/scripts/status.sh

# Follow the macrelay log inside the guest.
e2e-logs:
    {{e2e}}/scripts/vm-ssh.sh 'logread -f -e macrelay'

# Follow a container's log, e.g. `just e2e-service-logs fritzbox`.
e2e-service-logs service:
    cd {{e2e}} && docker compose logs -f {{service}}

# Shell inside one of the lab containers.
e2e-shell service:
    cd {{e2e}} && docker compose exec {{service}} sh

# Watch traffic as the simulated ISP router sees it.
e2e-capture filter="icmp":
    cd {{e2e}} && docker compose exec fritzbox tcpdump -lni any {{quote(filter)}}
