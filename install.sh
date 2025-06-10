#!/bin/bash

# AsusCtrl - KDE Plasma Widget Installation Script
# This script automates the installation process for the AsusCtrl widget

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect package manager
detect_package_manager() {
    if command_exists pacman; then
        echo "pacman"
    elif command_exists apt; then
        echo "apt"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists zypper; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# Function to detect Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$NAME"
    elif [ -f /etc/arch-release ]; then
        echo "Arch Linux"
    else
        echo "Unknown"
    fi
}

# Function to install packages based on detected package manager
install_packages() {
    local pkg_manager="$1"
    shift
    local packages=("$@")
    
    case "$pkg_manager" in
        "pacman")
            print_status "Installing packages with pacman: ${packages[*]}"
            sudo pacman -S --needed "${packages[@]}"
            ;;
        "apt")
            print_status "Installing packages with apt: ${packages[*]}"
            sudo apt update
            sudo apt install -y "${packages[@]}"
            ;;
        "dnf")
            print_status "Installing packages with dnf: ${packages[*]}"
            sudo dnf install -y "${packages[@]}"
            ;;
        "zypper")
            print_status "Installing packages with zypper: ${packages[*]}"
            sudo zypper install -y "${packages[@]}"
            ;;
        *)
            print_error "Unknown package manager. Please install packages manually."
            return 1
            ;;
    esac
}

# Function to check if user is in wheel group
check_wheel_group() {
    if groups "$USER" | grep -q '\bwheel\b'; then
        return 0
    else
        return 1
    fi
}

# Main installation function
main() {
    echo "========================================"
    echo "  AsusCtrl Widget Installer"
    echo "========================================"
    echo ""
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root!"
        print_error "Please run as a regular user with sudo privileges."
        exit 1
    fi
    
    # Check if user is in wheel group
    if ! check_wheel_group; then
        print_warning "User $USER is not in the 'wheel' group."
        print_warning "Adding user to wheel group..."
        sudo usermod -a -G wheel "$USER"
        print_warning "You may need to log out and back in for group changes to take effect."
    fi
    
    # Detect package manager
    PKG_MANAGER=$(detect_package_manager)
    DISTRO=$(detect_distro)
    print_status "Detected distribution: $DISTRO"
    print_status "Detected package manager: $PKG_MANAGER"
    
    # Step 1: Install system dependencies
    print_status "Step 1: Installing system dependencies..."
    
    case "$PKG_MANAGER" in
        "pacman")
            # Special handling for gaming distros
            if [[ "$DISTRO" == *"Garuda"* ]] || [[ "$DISTRO" == *"CachyOS"* ]]; then
                print_status "Detected gaming-optimized distribution: $DISTRO"
                print_status "Installing kernel headers for potential module support..."
                
                # Try to install appropriate kernel headers
                if pacman -Qs linux-bore-headers >/dev/null 2>&1 || uname -r | grep -q bore; then
                    sudo pacman -S --needed linux-bore-headers 2>/dev/null || print_warning "Could not install linux-bore-headers"
                elif pacman -Qs linux-zen-headers >/dev/null 2>&1 || uname -r | grep -q zen; then
                    sudo pacman -S --needed linux-zen-headers 2>/dev/null || print_warning "Could not install linux-zen-headers"
                else
                    sudo pacman -S --needed linux-headers 2>/dev/null || print_warning "Could not install linux-headers"
                fi
            fi
            
            # Check if packages are available
            if pacman -Si asusctl supergfxctl >/dev/null 2>&1; then
                install_packages "pacman" asusctl supergfxctl python-dbus python-psutil
            else
                print_warning "asusctl/supergfxctl not found in official repos. Checking AUR..."
                if command_exists yay; then
                    print_status "Installing from AUR with yay..."
                    yay -S --needed asusctl supergfxctl python-dbus python-psutil
                elif command_exists paru; then
                    print_status "Installing from AUR with paru..."
                    paru -S --needed asusctl supergfxctl python-dbus python-psutil
                elif command_exists pamac; then
                    print_status "Installing with pamac (Garuda/Manjaro)..."
                    pamac install --no-confirm asusctl supergfxctl python-dbus python-psutil
                else
                    print_error "AUR helper not found. Please install asusctl and supergfxctl manually."
                    print_error "Visit: https://aur.archlinux.org/packages/asusctl"
                    exit 1
                fi
            fi
            ;;
        "apt")
            # Check if packages are available in repos
            if apt-cache show asusctl >/dev/null 2>&1; then
                install_packages "apt" asusctl supergfxctl python3-dbus python3-psutil
            else
                print_warning "asusctl not found in repos. Please install manually."
                print_warning "Visit: https://asus-linux.org/wiki/installation/"
                exit 1
            fi
            ;;
        *)
            print_warning "Automatic package installation not supported for $PKG_MANAGER"
            print_warning "Please install the following packages manually:"
            print_warning "- asusctl"
            print_warning "- supergfxctl" 
            print_warning "- python3-dbus"
            print_warning "- python3-psutil"
            ;;
    esac
    
    # Step 2: Enable and start services
    print_status "Step 2: Enabling and starting system services..."
    
    sudo systemctl enable --now asusd
    print_success "asusd service enabled and started"
    
    if systemctl list-unit-files | grep -q supergfxd; then
        sudo systemctl enable --now supergfxd
        print_success "supergfxd service enabled and started"
    else
        print_warning "supergfxd service not found - GPU switching may not work"
    fi
    
    # Step 3: Install the widget
    print_status "Step 3: Installing the widget..."
    
    WIDGET_DIR="$HOME/.local/share/plasma/plasmoids"
    WIDGET_NAME="org.kde.plasma.asustufcontrol"
    
    # Create plasmoids directory if it doesn't exist
    mkdir -p "$WIDGET_DIR"
    
    # Get the script directory (where this script is located)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Copy widget files
    if [[ -d "$SCRIPT_DIR" && -f "$SCRIPT_DIR/metadata.json" ]]; then
        # We're in the widget directory
        cp -r "$SCRIPT_DIR" "$WIDGET_DIR/$WIDGET_NAME"
        print_success "Widget files copied to $WIDGET_DIR/$WIDGET_NAME"
    else
        print_error "Cannot find widget files. Make sure you're running this script from the widget directory."
        exit 1
    fi
    
    # Set execute permissions
    chmod +x "$WIDGET_DIR/$WIDGET_NAME/contents/scripts/helper.py"
    chmod +x "$WIDGET_DIR/$WIDGET_NAME/contents/scripts/asus_keyboard_lighting_control.py"
    chmod +x "$WIDGET_DIR/$WIDGET_NAME/contents/scripts/get_sensors.py"
    print_success "Execute permissions set for scripts"
    
    # Step 4: Configure system permissions
    print_status "Step 4: Configuring system permissions..."
    
    # Create polkit rules
    POLKIT_RULES="/etc/polkit-1/rules.d/90-asustufcontrol.rules"
    print_status "Creating polkit rules..."
    
    sudo tee "$POLKIT_RULES" > /dev/null << EOF
// AsusCtrl Widget - Polkit Rules
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.policykit.exec" &&
         action.lookup("program") == "/usr/bin/python3" &&
         action.lookup("command_line").indexOf("helper.py") !== -1) &&
        subject.isInGroup("wheel")) {
            return polkit.Result.YES;
    }
});

polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        subject.isInGroup("wheel")) {
            return polkit.Result.YES;
    }
});
EOF
    
    print_success "Polkit rules created"
    
    # Create sudoers file
    SUDOERS_FILE="/etc/sudoers.d/asustufcontrol"
    print_status "Creating sudoers configuration..."
    
    sudo tee "$SUDOERS_FILE" > /dev/null << EOF
# AsusCtrl Widget - Sudo Rules
$USER ALL=(ALL) NOPASSWD: /usr/bin/python3 $WIDGET_DIR/$WIDGET_NAME/contents/scripts/helper.py *
$USER ALL=(ALL) NOPASSWD: /bin/systemctl enable nvidia-powerd.service
$USER ALL=(ALL) NOPASSWD: /bin/systemctl disable nvidia-powerd.service
$USER ALL=(ALL) NOPASSWD: /bin/systemctl start nvidia-powerd.service
$USER ALL=(ALL) NOPASSWD: /bin/systemctl stop nvidia-powerd.service
EOF
    
    print_success "Sudoers configuration created"
    
    # Create udev rules for battery charge limit
    UDEV_RULES="/etc/udev/rules.d/99-asus-charge-limit.rules"
    print_status "Creating udev rules for battery charge limit..."
    
    sudo tee "$UDEV_RULES" > /dev/null << 'EOF'
# AsusCtrl Widget - Battery Charge Limit Rules
ACTION=="add", SUBSYSTEM=="power_supply", ATTR{name}=="BAT0", RUN+="/bin/chmod a+w /sys/class/power_supply/BAT0/charge_control_end_threshold"
ACTION=="add", SUBSYSTEM=="power_supply", ATTR{name}=="BAT1", RUN+="/bin/chmod a+w /sys/class/power_supply/BAT1/charge_control_end_threshold"
EOF
    
    print_success "Udev rules created"
    
    # Reload udev rules
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    print_success "Udev rules reloaded"
    
    # Step 5: Install optional dependencies
    print_status "Step 5: Installing optional dependencies..."
    
    case "$PKG_MANAGER" in
        "pacman")
            # Try to install ryzenadj for AMD support
            if yay --version >/dev/null 2>&1; then
                yay -S --needed --noconfirm ryzenadj 2>/dev/null || print_warning "Could not install ryzenadj (AMD power control)"
            elif paru --version >/dev/null 2>&1; then
                paru -S --needed --noconfirm ryzenadj 2>/dev/null || print_warning "Could not install ryzenadj (AMD power control)"
            fi
            
            # Install nvidia-utils if NVIDIA GPU detected
            if lspci | grep -i nvidia >/dev/null; then
                install_packages "pacman" nvidia-utils || print_warning "Could not install nvidia-utils"
            fi
            ;;
        *)
            print_warning "Optional dependencies not installed automatically for $PKG_MANAGER"
            ;;
    esac
    
    # Step 6: Restart plasma shell
    print_status "Step 6: Restarting Plasma shell..."
    
    if command_exists kquitapp5; then
        kquitapp5 plasmashell 2>/dev/null || true
        sleep 2
        kstart5 plasmashell 2>/dev/null &
    elif command_exists kquitapp6; then
        kquitapp6 plasmashell 2>/dev/null || true  
        sleep 2
        plasmashell 2>/dev/null &
    else
        print_warning "Could not restart Plasma shell automatically"
        print_warning "Please restart Plasma shell manually or log out and back in"
    fi
    
    print_success "Plasma shell restarted"
    
    # Installation complete
    echo ""
    echo "========================================"
    print_success "Installation completed successfully!"
    echo "========================================"
    echo ""
    print_status "Next steps:"
    echo "1. Right-click on your KDE Plasma panel"
    echo "2. Select 'Add Widgets...'"
    echo "3. Search for 'AsusCtrl'"
    echo "4. Drag the widget to your panel or desktop"
    echo ""
    print_status "If the widget doesn't appear immediately:"
    echo "- Log out and back in to ensure all permissions are applied"
    echo "- Or run: plasmashell --replace &"
    echo ""
    print_status "For troubleshooting, check the README.md file"
    echo ""
}

# Run main function
main "$@"
