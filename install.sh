#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

USER_HOME="$HOME"
VENV_SATELLITE="$USER_HOME/wyoming-satellite/.venv"
VENV_OPENWAKEWORD="$USER_HOME/wyoming-openwakeword/.venv"

info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

# ─── Step 0: Preflight ──────────────────────────────────────────────
info "Checking architecture..."
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    error "64-bit OS required (got $ARCH). Re-flash with Raspberry Pi OS Lite 64-bit."
fi

info "Checking available memory..."
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
info "Detected ${MEM_MB}MB RAM"

# ─── Step 1: System dependencies ────────────────────────────────────
info "Installing system packages..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    git python3-venv python3-spidev python3-gpiozero \
    libopenblas-dev

# ─── Step 2: Clone wyoming-satellite ────────────────────────────────
if [[ ! -d "$USER_HOME/wyoming-satellite" ]]; then
    info "Cloning wyoming-satellite..."
    git clone https://github.com/rhasspy/wyoming-satellite.git "$USER_HOME/wyoming-satellite"
else
    info "wyoming-satellite already cloned, pulling latest..."
    git -C "$USER_HOME/wyoming-satellite" pull || true
fi

# ─── Step 3: ReSpeaker drivers ──────────────────────────────────────
if arecord -L 2>/dev/null | grep -q seeed2micvoicec; then
    info "ReSpeaker drivers already installed."
else
    info "Installing ReSpeaker 2-Mic HAT drivers (this takes 30-60 min on Pi Zero 2 W)..."
    sudo bash "$USER_HOME/wyoming-satellite/etc/install-respeaker-drivers.sh"
    warn "Drivers installed. A REBOOT is required."
    warn "After reboot, run this script again to continue setup."
    read -rp "Reboot now? [Y/n] " ans
    if [[ "${ans,,}" != "n" ]]; then
        sudo reboot
    fi
    exit 0
fi

# ─── Step 4: Set up wyoming-satellite Python env ────────────────────
if [[ ! -d "$VENV_SATELLITE" ]]; then
    info "Setting up wyoming-satellite Python environment..."
    cd "$USER_HOME/wyoming-satellite"
    python3 -m venv .venv
    .venv/bin/pip3 install --upgrade pip wheel setuptools
    .venv/bin/pip3 install \
        -f 'https://synesthesiam.github.io/prebuilt-apps/' \
        -e '.[all]'
else
    info "wyoming-satellite venv already exists."
fi

# ─── Step 5: Verify audio ───────────────────────────────────────────
info "Verifying audio device..."
if arecord -L | grep -q seeed2micvoicec; then
    info "Audio capture device found: seeed2micvoicec"
else
    error "ReSpeaker capture device not found. Check driver installation."
fi
if aplay -L | grep -q seeed2micvoicec; then
    info "Audio playback device found: seeed2micvoicec"
else
    error "ReSpeaker playback device not found. Check driver installation."
fi

# ─── Step 6: Local wake word (optional) ─────────────────────────────
if [[ "$WAKE_WORD_MODE" == "local" ]]; then
    warn "Local wake word on Pi Zero 2 W may cause CPU/stability issues."
    if [[ ! -d "$USER_HOME/wyoming-openwakeword" ]]; then
        info "Cloning wyoming-openwakeword..."
        git clone https://github.com/rhasspy/wyoming-openwakeword.git "$USER_HOME/wyoming-openwakeword"
    fi
    if [[ ! -d "$VENV_OPENWAKEWORD" ]]; then
        info "Setting up wyoming-openwakeword..."
        cd "$USER_HOME/wyoming-openwakeword"
        script/setup
    fi

    # Custom wake word directory
    mkdir -p "$USER_HOME/custom-wake-words"

    info "Installing wyoming-openwakeword systemd service..."
    CUSTOM_MODEL_FLAG=""
    if ls "$USER_HOME/custom-wake-words/"*.tflite &>/dev/null; then
        CUSTOM_MODEL_FLAG="--custom-model-dir $USER_HOME/custom-wake-words"
    fi

    sudo tee /etc/systemd/system/wyoming-openwakeword.service > /dev/null <<OWWEOF
[Unit]
Description=Wyoming openWakeWord
After=network-online.target

[Service]
Type=simple
User=$(whoami)
ExecStart=$USER_HOME/wyoming-openwakeword/script/run \\
  --uri 'tcp://127.0.0.1:10400' \\
  --preload-model '$WAKE_WORD_NAME' $CUSTOM_MODEL_FLAG
WorkingDirectory=$USER_HOME/wyoming-openwakeword
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
OWWEOF
fi

# ─── Step 7: LED service (optional) ─────────────────────────────────
if [[ "$ENABLE_LEDS" == "true" ]]; then
    info "Setting up ReSpeaker LED service..."
    cd "$USER_HOME/wyoming-satellite/examples"
    if [[ ! -d .venv ]]; then
        python3 -m venv --system-site-packages .venv
        .venv/bin/pip3 install --upgrade pip wheel setuptools
        .venv/bin/pip3 install 'wyoming==1.5.2'
    fi

    sudo tee /etc/systemd/system/2mic-leds.service > /dev/null <<LEDEOF
[Unit]
Description=Wyoming Satellite 2Mic LEDs

[Service]
Type=simple
User=$(whoami)
ExecStart=$USER_HOME/wyoming-satellite/examples/.venv/bin/python3 \\
  2mic_service.py --uri 'tcp://127.0.0.1:10500'
WorkingDirectory=$USER_HOME/wyoming-satellite/examples
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
LEDEOF
fi

# ─── Step 8: Main satellite systemd service ─────────────────────────
info "Installing wyoming-satellite systemd service..."

EXTRA_ARGS=""
EXTRA_DEPS=""

if [[ "$WAKE_WORD_MODE" == "local" ]]; then
    EXTRA_ARGS="--wake-uri 'tcp://127.0.0.1:10400' --wake-word-name '$WAKE_WORD_NAME'"
    EXTRA_DEPS="Requires=wyoming-openwakeword.service"
fi

if [[ "$ENABLE_LEDS" == "true" ]]; then
    EXTRA_ARGS="$EXTRA_ARGS --event-uri 'tcp://127.0.0.1:10500'"
    EXTRA_DEPS="$EXTRA_DEPS
Requires=2mic-leds.service"
fi

VOLUME_ARGS=""
[[ "$MIC_VOLUME_MULTIPLIER" != "1.0" ]] && VOLUME_ARGS="--mic-volume-multiplier $MIC_VOLUME_MULTIPLIER"
[[ "$MIC_AUTO_GAIN" != "0" ]] && VOLUME_ARGS="$VOLUME_ARGS --mic-auto-gain $MIC_AUTO_GAIN"
[[ "$MIC_NOISE_SUPPRESSION" != "0" ]] && VOLUME_ARGS="$VOLUME_ARGS --mic-noise-suppression $MIC_NOISE_SUPPRESSION"

sudo tee /etc/systemd/system/wyoming-satellite.service > /dev/null <<SATEOF
[Unit]
Description=Wyoming Satellite
Wants=network-online.target
After=network-online.target
$EXTRA_DEPS

[Service]
Type=simple
User=$(whoami)
ExecStart=$USER_HOME/wyoming-satellite/script/run \\
  --name '$SATELLITE_NAME' \\
  --uri 'tcp://0.0.0.0:$SATELLITE_PORT' \\
  --mic-command 'arecord -D $AUDIO_DEVICE -r 16000 -c 1 -f S16_LE -t raw' \\
  --snd-command 'aplay -D $AUDIO_DEVICE -r 22050 -c 1 -f S16_LE -t raw' \\
  $VOLUME_ARGS $EXTRA_ARGS
WorkingDirectory=$USER_HOME/wyoming-satellite
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
SATEOF

# ─── Step 9: Enable and start ───────────────────────────────────────
info "Enabling services..."
sudo systemctl daemon-reload

if [[ "$WAKE_WORD_MODE" == "local" ]]; then
    sudo systemctl enable --now wyoming-openwakeword.service
fi
if [[ "$ENABLE_LEDS" == "true" ]]; then
    sudo systemctl enable --now 2mic-leds.service
fi
sudo systemctl enable --now wyoming-satellite.service

# ─── Done ────────────────────────────────────────────────────────────
info "======================================"
info "  Wyoming Satellite is running!"
info "======================================"
info ""
info "Satellite: $SATELLITE_NAME on port $SATELLITE_PORT"
info "Wake word: $WAKE_WORD_MODE mode"
info ""
info "In Home Assistant:"
info "  1. Go to Settings > Devices & Services"
info "  2. The satellite should auto-discover (Wyoming Protocol)"
info "  3. Or add manually: Wyoming Protocol > IP:$SATELLITE_PORT"
if [[ "$WAKE_WORD_MODE" == "remote" ]]; then
    info ""
    info "For wake word detection, install the openWakeWord add-on"
    info "on your HA server and configure it in your voice pipeline."
fi
info ""
info "Check status:  sudo systemctl status wyoming-satellite"
info "View logs:     journalctl -u wyoming-satellite -f"
