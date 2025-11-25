#!/bin/sh

# ==============================================================================
# Snapclient Installer for PiCorePlayer 10.x
# Version: 12.0 (Auto-Detect, Strong Attenuation, & Diagnostics)
# ==============================================================================

# ------------------------------------------------------------------------------
# User-Configurable Settings
# ------------------------------------------------------------------------------
# These values can be modified to install different versions or change paths

SNAP_VERSION="0.34.0"       # Snapcast release version to install
SNAP_DISTRO="bookworm"      # Debian base (bookworm = Debian 12)
INSTALL_DIR="/home/tc/snapclient-bin"  # Installation directory

# ------------------------------------------------------------------------------
# PiCorePlayer System Defaults
# ------------------------------------------------------------------------------
# These paths are standard for pCP and should not be changed unless you know
# what you're doing

TC_USER="tc"                           # Default TinyCore user
TCE_DIR="/etc/sysconfig/tcedir"        # TinyCore extension directory
OPTIONAL_DIR="$TCE_DIR/optional"       # Extension storage location
ONBOOT_FILE="$TCE_DIR/onboot.lst"      # Boot-time extension load list
BACKUP_LIST="/opt/.filetool.lst"       # Persistent file backup list
ASOUND_RC="/home/tc/.asoundrc"         # ALSA user configuration

# ------------------------------------------------------------------------------
# Derived Variables (do not edit)
# ------------------------------------------------------------------------------

STARTUP_SCRIPT="$INSTALL_DIR/startup.sh"
LOG_FILE="/tmp/snapclient.log"

# ANSI Colors for terminal output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ==============================================================================
# 1. Architecture Detection
# ==============================================================================
ARCH=$(uname -m)
log_info "Detected Architecture: $ARCH"

if [ "$ARCH" = "aarch64" ]; then
    SNAP_DEB_ARCH="arm64"
    TC_REPO_URL="http://tinycorelinux.net/15.x/aarch64/tcz"
elif [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armhf" ]; then
    SNAP_DEB_ARCH="armhf"
    TC_REPO_URL="http://tinycorelinux.net/15.x/armv7/tcz"
else
    log_err "Unsupported architecture: $ARCH"
    exit 1
fi

# Construct download URL for official Snapcast Debian package
# Format: snapclient_VERSION-1_ARCH_DISTRO.deb
SNAP_URL="https://github.com/badaix/snapcast/releases/download/v${SNAP_VERSION}/snapclient_${SNAP_VERSION}-1_${SNAP_DEB_ARCH}_${SNAP_DISTRO}.deb"

# ==============================================================================
# 2. Dependency Management
# ==============================================================================
# Required TinyCore extensions for Snapclient to function:
# - avahi: mDNS service discovery
# - flac/libvorbis/opus: Audio codec support
# - expat2: XML parsing library
# - pcp-libsoxr: Sample rate conversion
# - gcc_libs: C++ standard library runtime
DEPENDENCIES="avahi.tcz flac.tcz libvorbis.tcz opus.tcz expat2.tcz pcp-libsoxr.tcz gcc_libs.tcz"
log_info "Checking and installing dependencies..."
for EXT in $DEPENDENCIES; do
    if tce-status -i | grep -q "^$(basename $EXT .tcz)$"; then
        echo "  - $EXT is already loaded."
    else
        echo "  - Installing $EXT..."
        tce-load -wi "$EXT" > /dev/null 2>&1
        if ! tce-status -i | grep -q "^$(basename $EXT .tcz)$"; then
            echo "    -> Not found in pCP repo. Fetching from upstream..."
            cd "$OPTIONAL_DIR" || exit 1
            wget -q "$TC_REPO_URL/$EXT"
            wget -q "$TC_REPO_URL/$EXT.md5.txt"
            if [ -f "$EXT" ]; then
                md5sum -c "$EXT.md5.txt" > /dev/null 2>&1
                if [ $? -eq 0 ]; then
                    tce-load -i "$EXT" > /dev/null 2>&1
                    if ! grep -q "$EXT" "$ONBOOT_FILE"; then echo "$EXT" >> "$ONBOOT_FILE"; fi
                else
                    log_err "MD5 mismatch for $EXT."; exit 1
                fi
            else
                log_err "Failed to download $EXT"; exit 1
            fi
        fi
    fi
done

# ==============================================================================
# 3. Download and Extract
# ==============================================================================
log_info "Setting up Snapclient v${SNAP_VERSION}..."
mkdir -p "$INSTALL_DIR"
cd /tmp
rm -rf snapclient_temp
mkdir snapclient_temp
cd snapclient_temp

if [ ! -f "$INSTALL_DIR/snapclient" ]; then
    wget -q "$SNAP_URL" -O snapclient.deb
    if [ ! -f "snapclient.deb" ]; then log_err "Failed to download package."; exit 1; fi
    ar x snapclient.deb; tar -xf data.tar.xz
    cp usr/bin/snapclient "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/snapclient"
else
    log_info "Snapclient binary already exists, skipping download."
fi
cd /tmp; rm -rf snapclient_temp

# ==============================================================================
# 4. Validation
# ==============================================================================
log_info "Validating binary dependencies..."
MISSING_LIBS=$(ldd "$INSTALL_DIR/snapclient" | grep "not found")
if [ -n "$MISSING_LIBS" ]; then
    # Known issue: Debian package expects libFLAC.so.12, TinyCore provides .so.8
    if echo "$MISSING_LIBS" | grep -q "libFLAC.so.12"; then
        if [ -f "/usr/local/lib/libFLAC.so.8" ] || [ -f "/usr/lib/libFLAC.so.8" ]; then
             log_warn "Fixing libFLAC version mismatch..."
             sudo ln -s $(find /usr -name libFLAC.so.8 | head -n 1) /usr/local/lib/libFLAC.so.12
             sudo ldconfig
        fi
    fi
    # Re-check for any remaining issues
    MISSING_LIBS=$(ldd "$INSTALL_DIR/snapclient" | grep "not found")
    if [ -n "$MISSING_LIBS" ]; then
        log_warn "Some library dependencies are missing:"
        echo "$MISSING_LIBS"
        log_warn "The installation will continue, but Snapclient may not work correctly."
    fi
fi

# ==============================================================================
# 5. Snapserver Configuration
# ==============================================================================
echo ""
echo "=============================================================================="
echo -e "${CYAN}SNAPSERVER CONFIGURATION${NC}"
echo "=============================================================================="
read -p "Enter Snapserver IP (e.g. 192.168.1.50): " USER_HOST
if [ -z "$USER_HOST" ]; then log_err "Host cannot be empty."; exit 1; fi

log_info "Checking network connection to $USER_HOST..."
if ping -c 1 -W 2 "$USER_HOST" > /dev/null 2>&1; then
    log_info "Server is reachable."
else
    log_warn "Server $USER_HOST is not reachable via ping. Proceeding anyway..."
fi

# ==============================================================================
# 6. Audio Device Auto-Detection
# ==============================================================================
echo ""
echo "=============================================================================="
echo -e "${CYAN}AUDIO DEVICE SELECTION${NC}"
echo "=============================================================================="
echo "Scanning for running Squeezelite process..."

# Smart Detection: Find the device Squeezelite is ACTUALLY using
SQ_DEVICE=$(ps aux | grep squeezelite | grep -v grep | grep -o 'dmix:[^ ]*')

if [ -n "$SQ_DEVICE" ]; then
    echo -e "${GREEN}FOUND SQUEEZELITE DEVICE:${NC} $SQ_DEVICE"
    echo "This is the ideal device to share audio."
    echo ""
    read -p "Use this device? (y/n): " CONFIRM
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        RAW_DEVICE="$SQ_DEVICE"
    fi
fi

if [ -z "$RAW_DEVICE" ]; then
    echo "Could not auto-detect or user declined. Please select manually:"
    echo "------------------------------------------------------------------------------"
    squeezelite -l | grep -E "dmix:|sysdefault:|hw:" > /tmp/sl_devices.txt
    awk '{print NR ". " $0}' /tmp/sl_devices.txt
    echo "------------------------------------------------------------------------------"
    read -p "Enter the NUMBER of your desired device: " DEV_NUM
    RAW_DEVICE=$(awk -v n="$DEV_NUM" 'NR==n {print $1}' /tmp/sl_devices.txt)
fi

if [ -z "$RAW_DEVICE" ]; then log_err "Invalid selection."; exit 1; fi
log_info "Target Device: $RAW_DEVICE"

# ==============================================================================
# 7. Attenuation & ALSA Config
# ==============================================================================
echo ""
echo "=============================================================================="
echo -e "${CYAN}VOLUME & ATTENUATION${NC}"
echo "=============================================================================="
echo "Since your DAC likely has no hardware mixer, we must lower the digital"
echo "volume to prevent distortion when mixing with Squeezelite."
echo ""
echo "1. Strong Attenuation (30%) - RECOMMENDED if 20% volume is currently loud"
echo "2. Medium Attenuation (50%)"
echo "3. Light Attenuation  (75%)"
echo "4. No Attenuation     (100%)"
echo ""
read -p "Select attenuation level (1-4) [Default: 1]: " ATT_OPT

case "$ATT_OPT" in
    2) FACTOR="0.5" ;;
    3) FACTOR="0.75" ;;
    4) FACTOR="1.0" ;;
    *) FACTOR="0.3" ;; # Default strong
esac

log_info "Applying volume factor: $FACTOR"

if echo "$RAW_DEVICE" | grep -q "dmix:"; then
    cat > "$ASOUND_RC" <<EOF
pcm.snapcast_attenuated {
    type route
    slave.pcm {
        type plug
        slave.pcm "$RAW_DEVICE"
    }
    ttable {
        0.0 $FACTOR
        1.1 $FACTOR
    }
}
EOF
    chown tc:staff "$ASOUND_RC"
    if ! grep -q "home/tc/.asoundrc" "$BACKUP_LIST"; then
        echo "home/tc/.asoundrc" >> "$BACKUP_LIST"
    fi
    FINAL_DEVICE="snapcast_attenuated"
else
    FINAL_DEVICE="$RAW_DEVICE"
    log_warn "Hardware device selected. Attenuation skipped (requires dmix)."
fi

# ==============================================================================
# 8. Create Startup Wrapper
# ==============================================================================
cat > "$STARTUP_SCRIPT" <<EOF
#!/bin/sh
# Snapclient Startup Wrapper
# This script allows snapclient to start at boot via pCP User Commands
# Usage: startup.sh [server_ip_or_uri]

SERVER_INPUT="\${1:-$USER_HOST}"
BINARY="$INSTALL_DIR/snapclient"
DEVICE="$FINAL_DEVICE"
LOG_FILE="/tmp/snapclient.log"

# Add tcp:// prefix if not already a URI
case "\$SERVER_INPUT" in
    *://*) SERVER_URI="\$SERVER_INPUT" ;;
    *)     SERVER_URI="tcp://\$SERVER_INPUT" ;;
esac

# If running as root (e.g., from boot), drop to tc user
if [ "\$(id -u)" -eq 0 ]; then
    su tc -c "\$BINARY -s \$DEVICE \$SERVER_URI > \$LOG_FILE 2>&1 &"
else
    \$BINARY -s \$DEVICE \$SERVER_URI > \$LOG_FILE 2>&1 &
fi
EOF
chmod +x "$STARTUP_SCRIPT"
chown tc:staff "$STARTUP_SCRIPT"

# ==============================================================================
# 9. Persistence & Verify
# ==============================================================================
if ! grep -q "home/tc/snapclient-bin" "$BACKUP_LIST"; then
    echo "home/tc/snapclient-bin" >> "$BACKUP_LIST"
fi
log_info "Running pCP backup..."
pcp bu > /dev/null 2>&1

echo ""
echo "=============================================================================="
echo -e "${CYAN}FINAL AUDIO CHECK${NC}"
echo "=============================================================================="
echo "Stopping Squeezelite for 5 seconds to test Snapclient..."
pcp slk > /dev/null 2>&1
sleep 1

timeout 5s $INSTALL_DIR/snapclient -s "$FINAL_DEVICE" "tcp://$USER_HOST" > /tmp/snap_test.log 2>&1
EXIT_CODE=$?

pcp sls > /dev/null 2>&1

if [ $EXIT_CODE -eq 124 ]; then
    echo -e "${GREEN}[PASS] Snapclient connected and played audio without crashing.${NC}"
else
    echo -e "${RED}[FAIL] Snapclient crashed or failed to connect.${NC}"
    cat /tmp/snap_test.log
fi

# ==============================================================================
# 10. Completion
# ==============================================================================
echo ""
echo "=============================================================================="
echo -e "${GREEN}Snapclient Installation Complete!${NC}"
echo "=============================================================================="
echo "1. Go to pCP Web Interface -> Tweaks -> User Commands"
echo "2. Add this command:"
echo ""
echo -e "${YELLOW}$STARTUP_SCRIPT${NC}"
echo ""
echo "3. Click Save and Reboot."
echo "=============================================================================="