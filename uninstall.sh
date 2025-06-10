#!/bin/bash

# AsusCtrl - KDE Plasma Widget Uninstallation Script
# This script removes the AsusCtrl widget and its configuration

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

# Main uninstallation function
main() {
    echo "========================================"
    echo "  AsusCtrl Widget Uninstaller"
    echo "========================================"
    echo ""
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root!"
        print_error "Please run as a regular user with sudo privileges."
        exit 1
    fi
    
    # Ask for confirmation
    echo "This will remove the AsusCtrl widget and its configuration."
    echo "System services (asusd, supergfxd) will be left running as they may be used by other applications."
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Uninstallation cancelled."
        exit 0
    fi
    
    # Step 1: Remove widget files
    print_status "Step 1: Removing widget files..."
    
    WIDGET_DIR="$HOME/.local/share/plasma/plasmoids"
    WIDGET_NAME="org.kde.plasma.asustufcontrol"
    
    if [[ -d "$WIDGET_DIR/$WIDGET_NAME" ]]; then
        rm -rf "$WIDGET_DIR/$WIDGET_NAME"
        print_success "Widget files removed from $WIDGET_DIR/$WIDGET_NAME"
    else
        print_warning "Widget directory not found at $WIDGET_DIR/$WIDGET_NAME"
    fi
    
    # Step 2: Ask about system configuration removal
    echo ""
    print_status "Do you want to remove system-level configuration files?"
    print_warning "This includes polkit rules, sudoers, and udev rules."
    print_warning "Only remove these if you're not using any other ASUS control applications."
    echo ""
    read -p "Remove system configuration? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Step 2: Removing system configuration..."
        
        # Remove polkit rules
        if [[ -f "/etc/polkit-1/rules.d/90-asustufcontrol.rules" ]]; then
            sudo rm -f "/etc/polkit-1/rules.d/90-asustufcontrol.rules"
            print_success "Polkit rules removed"
        fi
        
        # Remove sudoers configuration
        if [[ -f "/etc/sudoers.d/asustufcontrol" ]]; then
            sudo rm -f "/etc/sudoers.d/asustufcontrol"
            print_success "Sudoers configuration removed"
        fi
        
        # Remove udev rules
        if [[ -f "/etc/udev/rules.d/99-asus-charge-limit.rules" ]]; then
            sudo rm -f "/etc/udev/rules.d/99-asus-charge-limit.rules"
            sudo udevadm control --reload-rules
            print_success "Udev rules removed and reloaded"
        fi
        
        print_success "System configuration removed"
    else
        print_status "Step 2: Keeping system configuration files"
    fi
    
    # Step 3: Restart plasma shell
    print_status "Step 3: Restarting Plasma shell..."
    
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
        print_warning "Please restart Plasma shell manually: plasmashell --replace &"
    fi
    
    print_success "Plasma shell restarted"
    
    # Uninstallation complete
    echo ""
    echo "========================================"
    print_success "Uninstallation completed successfully!"
    echo "========================================"
    echo ""
    print_status "The AsusCtrl widget has been removed."
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        print_status "Note: System configuration files were kept."
        print_status "If you want to remove them later, run this script again."
    fi
    
    echo ""
    print_status "System services (asusd, supergfxd) were left running."
    print_status "If you want to disable them, run:"
    echo "  sudo systemctl disable --now asusd"
    echo "  sudo systemctl disable --now supergfxd"
    echo ""
}

# Run main function
main "$@"
