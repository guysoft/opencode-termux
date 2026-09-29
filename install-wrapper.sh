#!/data/data/com.termux/files/usr/bin/bash
# Standalone installer for the enhanced OpenCode launcher in Termux
set -euo pipefail

abort() {
    echo "abort: $*" >&2
    exit 1
}

# Ensure we are inside Termux on Android
if [ ! -d "/data/data/com.termux/files/usr" ]; then
    abort "This installer is meant for Termux on Android."
fi

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BIN_DIR="$PREFIX/bin"
LIBEXEC_DIR="$PREFIX/libexec/opencode"

mkdir -p "$BIN_DIR" "$LIBEXEC_DIR"

# Locate the real ELF executable
REAL_BIN=""
for candidate in \
    "/data/data/com.termux/files/usr/opt/opencode/bin/opencode" \
    "$PREFIX/libexec/opencode/opencode.bin" \
    "$PREFIX/libexec/opencode2/opencode2.bin" \
    "$PREFIX/bin/opencode.bin"
do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
        REAL_BIN="$candidate"
        break
    fi
done

# Check if current /usr/bin/opencode is an ELF binary rather than a script
if [ -z "$REAL_BIN" ] && [ -f "$BIN_DIR/opencode" ]; then
    if head -c 4 "$BIN_DIR/opencode" | grep -q $'\x7fELF'; then
        echo "Moving existing ELF binary to $LIBEXEC_DIR/opencode.bin..."
        mv "$BIN_DIR/opencode" "$LIBEXEC_DIR/opencode.bin"
        REAL_BIN="$LIBEXEC_DIR/opencode.bin"
    fi
fi

if [ -z "$REAL_BIN" ]; then
    abort "Could not locate the OpenCode binary. Please install OpenCode for Termux first."
fi

echo "Targeting binary: $REAL_BIN"

# Set up default configuration with persistent port and friendly fallback password
CONFIG_DIR="$HOME/.config/opencode"
CONFIG_FILE="$CONFIG_DIR/service.json"
mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<'EOF'
{
  "port": 4096,
  "password": "opencode"
}
EOF
else
    # Ensure port 4096 is configured if missing
    if ! grep -q '"port"' "$CONFIG_FILE" 2>/dev/null; then
        "$REAL_BIN" service set port 4096 >/dev/null 2>&1 || true
    fi
    # Ensure a friendly password is set if empty
    if ! grep -q '"password"' "$CONFIG_FILE" 2>/dev/null; then
        "$REAL_BIN" service set password "opencode" >/dev/null 2>&1 || true
    fi
fi

# Generate the enhanced wrapper script
TARGET_WRAPPER="$BIN_DIR/opencode"
echo "Installing launcher to $TARGET_WRAPPER..."

cat > "$TARGET_WRAPPER" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
unset LD_PRELOAD

OPENCODE_BIN="$REAL_BIN"
CONFIG_FILE="\$HOME/.config/opencode/service.json"
PORT=4096

# Grab configured port if available, or make sure default port is registered
if [ -f "\$CONFIG_FILE" ]; then
    DETECTED_PORT=\$(sed -n 's/.*"port":[[:space:]]*\\([0-9]\\+\\).*/\\1/p' "\$CONFIG_FILE" 2>/dev/null)
    if [ -n "\$DETECTED_PORT" ]; then
        PORT="\$DETECTED_PORT"
    else
        "\$OPENCODE_BIN" service set port "\$PORT" >/dev/null 2>&1
    fi
fi

ensure_service() {
    if ! curl -s -o /dev/null -I "http://127.0.0.1:\$PORT/" 2>/dev/null; then
        echo "Starting OpenCode background service on port \$PORT..."
        "\$OPENCODE_BIN" service start >/dev/null 2>&1
    fi
}

open_browser() {
    (
        for _ in {1..25}; do
            if curl -s -o /dev/null -I "http://127.0.0.1:\$PORT/" 2>/dev/null; then
                am start -a android.intent.action.VIEW -d "http://127.0.0.1:\$PORT" -p com.android.chrome >/dev/null 2>&1 \\
                    || termux-open-url "http://127.0.0.1:\$PORT" >/dev/null 2>&1
                break
            fi
            sleep 0.2
        done
    ) < /dev/null >/dev/null 2>&1 &
}

# Service management shortcuts
case "\$1" in
    status)
        STATUS=\$("\$OPENCODE_BIN" service status 2>/dev/null || echo "stopped")
        if [ "\$STATUS" = "stopped" ] || [ -z "\$STATUS" ]; then
            echo "OpenCode service: stopped"
        else
            echo "OpenCode service: running at \$STATUS"
        fi
        exit 0
        ;;
    stop)
        "\$OPENCODE_BIN" service stop
        echo "OpenCode service stopped."
        exit 0
        ;;
    start)
        "\$OPENCODE_BIN" service start
        exit 0
        ;;
    restart)
        "\$OPENCODE_BIN" service restart
        exit 0
        ;;
esac

# Password management command
if [ "\$1" = "password" ]; then
    shift
    CURRENT_PASS=\$(sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p' "\$CONFIG_FILE" 2>/dev/null)
    case "\${1:-}" in
        set)
            if [ -z "\${2:-}" ]; then
                echo "Usage: opencode password set <new_password>" >&2
                exit 1
            fi
            "\$OPENCODE_BIN" service set password "\$2" >/dev/null 2>&1
            echo "Password updated to: \$2"
            if curl -s -o /dev/null -I "http://127.0.0.1:\$PORT/" 2>/dev/null; then
                "\$OPENCODE_BIN" service restart >/dev/null 2>&1
                echo "Service restarted to apply new password."
            fi
            exit 0
            ;;
        reset)
            "\$OPENCODE_BIN" service set password "opencode" >/dev/null 2>&1
            echo "Password reset to: opencode"
            if curl -s -o /dev/null -I "http://127.0.0.1:\$PORT/" 2>/dev/null; then
                "\$OPENCODE_BIN" service restart >/dev/null 2>&1
                echo "Service restarted."
            fi
            exit 0
            ;;
        *)
            echo "OpenCode Password Settings:"
            echo "  Current Password: \${CURRENT_PASS:-none}"
            echo ""
            echo "Commands:"
            echo "  opencode password set <pw>  - Change password"
            echo "  opencode password reset     - Reset password to 'opencode'"
            exit 0
            ;;
    esac
fi

# Dedicated web mode
if [ "\$1" = "web" ]; then
    shift
    if [ \$# -gt 0 ]; then
        exec "\$OPENCODE_BIN" serve "\$@"
    fi
    ensure_service
    open_browser
    echo "OpenCode Web UI running at http://127.0.0.1:\$PORT"
    exit 0
fi

# Explicit CLI mode
if [ "\$1" = "--cli" ] || [ "\$1" = "cli" ] || [ "\$1" = "--no-web" ]; then
    shift
    ensure_service
    exec "\$OPENCODE_BIN" "\$@"
fi

# Pass administrative commands and help directly to the real binary
case "\$1" in
    --help|-h|--version|-v|--completions|service|update|upgrade|uninstall|models|auth|mcp|plugin|stats|api|acp|reload|run|session|pair)
        exec "\$OPENCODE_BIN" "\$@"
        ;;
esac

# Standalone mode should run directly without service or browser automation
for arg in "\$@"; do
    if [ "\$arg" = "--standalone" ]; then
        exec "\$OPENCODE_BIN" "\$@"
    fi
done

# If arguments were provided (e.g. project directory or flags), launch directly
if [ \$# -gt 0 ] || [ ! -t 0 ]; then
    ensure_service
    exec "\$OPENCODE_BIN" "\$@"
fi

# Interactive menu for choosing run mode
show_menu() {
    local selected=0

    # Hide cursor
    printf "\033[?25l"

    cleanup() {
        printf "\033[?25h\n"
        exit 0
    }
    trap cleanup INT TERM

    while true; do
        local current_pass=\$(sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p' "\$CONFIG_FILE" 2>/dev/null)

        local options=(
            "CLI (Terminal Interface)"
            "Web UI (Browser: http://127.0.0.1:4096)"
            "Dual Mode (CLI + Web UI)"
            "Stop Service"
            "View Password [\${current_pass:-none}]"
            "Exit"
        )
        local total=\${#options[@]}

        render() {
            printf "\n\033[1;36m  OpenCode Launcher\033[0m\n"
            printf "\033[90m  Use ↑/↓ or j/k to navigate, Enter to select:\033[0m\n\n"
            for i in "\${!options[@]}"; do
                if [ "\$i" -eq "\$selected" ]; then
                    printf "  \033[1;32m❯ %d) %s\033[0m\n" "\$((i + 1))" "\${options[\$i]}"
                else
                    printf "    \033[90m%d) %s\033[0m\n" "\$((i + 1))" "\${options[\$i]}"
                fi
            done
            printf "\n"
        }

        render
        local lines=\$((total + 5))

        while true; do
            IFS= read -rsn1 char
            if [[ "\$char" == \$'\x1b' ]]; then
                read -rsn2 -t 0.1 rest
                if [[ "\$rest" == '[A' ]]; then
                    if [ "\$selected" -gt 0 ]; then
                        selected=\$((selected - 1))
                    else
                        selected=\$((total - 1))
                    fi
                elif [[ "\$rest" == '[B' ]]; then
                    if [ "\$selected" -lt \$((total - 1)) ]; then
                        selected=\$((selected + 1))
                    else
                        selected=0
                    fi
                fi
            elif [[ "\$char" == "k" || "\$char" == "K" ]]; then
                if [ "\$selected" -gt 0 ]; then
                    selected=\$((selected - 1))
                else
                    selected=\$((total - 1))
                fi
            elif [[ "\$char" == "j" || "\$char" == "J" ]]; then
                if [ "\$selected" -lt \$((total - 1)) ]; then
                    selected=\$((selected + 1))
                else
                    selected=0
                fi
            elif [[ -z "\$char" ]]; then
                break 2
            elif [[ "\$char" == "q" || "\$char" == "Q" ]]; then
                selected=\$((total - 1))
                break 2
            elif [[ "\$char" =~ ^[1-6]$ ]]; then
                selected=\$((char - 1))
                break 2
            fi

            printf "\033[%dA" "\$lines"
            render
        done
        break
    done

    # Restore cursor
    printf "\033[?25h"

    case "\$selected" in
        0)
            ensure_service
            exec "\$OPENCODE_BIN"
            ;;
        1)
            ensure_service
            open_browser
            echo "OpenCode Web UI running at http://127.0.0.1:\$PORT"
            exit 0
            ;;
        2)
            ensure_service
            open_browser
            exec "\$OPENCODE_BIN"
            ;;
        3)
            "\$OPENCODE_BIN" service stop
            echo "OpenCode service stopped."
            exit 0
            ;;
        4)
            echo "Current password is: \${current_pass:-none}"
            echo "To change it, run: opencode password set <new_password>"
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
}

show_menu
EOF

chmod +x "$TARGET_WRAPPER"

echo "Installation complete!"
echo "Run 'opencode' to launch the interactive selector menu."
