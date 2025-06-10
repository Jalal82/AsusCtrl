#!/usr/bin/env python3
import sys
import subprocess
import os
import dbus
import logging
import json
from pathlib import Path
import re
import signal
import atexit
import threading
import time
from contextlib import contextmanager

# Add this block to ensure local import works
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Import get_fan_speeds and get_cpu_temperature from get_sensors.py
try:
    from get_sensors import get_fan_speeds, get_cpu_temperature
except ImportError:
    print("Warning: get_sensors module not found, fan speeds and CPU temperature will not be available", file=sys.stderr)
    def get_fan_speeds():
        return "N/A", "N/A"
    def get_cpu_temperature():
        return "N/A"

DEBUG_MODE = False
_cleanup_handlers = []

def setup_logging(debug=False):
    global DEBUG_MODE
    DEBUG_MODE = debug
    if debug:
        logging.basicConfig(
            level=logging.DEBUG,
            format='%(message)s',
            stream=sys.stderr
        )
    else:
        logging.basicConfig(
            level=logging.ERROR,
            format='%(message)s',
            stream=sys.stderr
        )

def register_cleanup(func):
    """Register a cleanup function to be called on exit"""
    _cleanup_handlers.append(func)

def cleanup_on_exit():
    """Run all registered cleanup handlers"""
    for handler in _cleanup_handlers:
        try:
            handler()
        except Exception as e:
            print(f"Error during cleanup: {e}", file=sys.stderr)

# Register cleanup handler
atexit.register(cleanup_on_exit)

@contextmanager
def timeout_context(seconds):
    """Context manager for operations with timeout"""
    def signal_handler(signum, frame):
        raise TimeoutError(f"Operation timed out after {seconds} seconds")
    
    old_handler = signal.signal(signal.SIGALRM, signal_handler)
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)

class PowerProfile:
    _instance = None
    _lock = threading.Lock()
    
    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super(PowerProfile, cls).__new__(cls)
        return cls._instance
    
    def __init__(self):
        if not hasattr(self, 'initialized'):
            try:
                with timeout_context(5):
                    self.proxy = dbus.Interface(
                        dbus.SystemBus().get_object(
                            "net.hadess.PowerProfiles", "/net/hadess/PowerProfiles"
                        ),
                        dbus_interface=dbus.PROPERTIES_IFACE,
                    )
                    self.supported_profiles = self.get_supported_profiles()
                    self.initialized = True
            except (dbus.exceptions.DBusException, TimeoutError) as e:
                raise Exception(f"Failed to initialize PowerProfiles: {str(e)}")

    def get_supported_profiles(self):
        try:
            with timeout_context(3):
                profiles = []
                for p in self.proxy.Get("net.hadess.PowerProfiles", "Profiles"):
                    profiles.append(str(p["Profile"]))
                return profiles
        except (dbus.exceptions.DBusException, TimeoutError) as e:
            raise Exception(f"Failed to get supported profiles: {str(e)}")

    def get_active_profile(self):
        try:
            with timeout_context(3):
                return str(self.proxy.Get("net.hadess.PowerProfiles", "ActiveProfile"))
        except (dbus.exceptions.DBusException, TimeoutError) as e:
            raise Exception(f"Failed to get active profile: {str(e)}")

    def set_profile(self, profile):
        if profile not in self.supported_profiles:
            raise ValueError(
                f"Invalid profile: {profile}. Supported profiles are: {self.supported_profiles}"
            )
        try:
            with timeout_context(5):
                self.proxy.Set(
                    "net.hadess.PowerProfiles",
                    "ActiveProfile",
                    profile,
                )
        except (dbus.exceptions.DBusException, TimeoutError) as e:
            raise Exception(f"Failed to set profile: {str(e)}")

class GPUControl:
    GPU_MODES =  ['hybrid', 'integrated', 'vfio',  'asusmuxdiscreet','egpu', 'asusmuxdgpu']
    GFX_USER_ACTION = ['logout', 'reboot', 'nothing']
    _instance = None
    _lock = threading.Lock()
    
    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super(GPUControl, cls).__new__(cls)
        return cls._instance
    
    def __init__(self):
        if not hasattr(self, 'initialized'):
            try:
                with timeout_context(5):
                    self.proxy = dbus.Interface(
                        dbus.SystemBus().get_object(
                            "org.supergfxctl.Daemon", 
                            "/org/supergfxctl/Gfx"
                        ),
                        dbus_interface="org.supergfxctl.Daemon",
                    )
                    self.connected = True
                    self.initialized = True
                    register_cleanup(self._cleanup)
            except (dbus.exceptions.DBusException, TimeoutError) as e:
                self.connected = False
                raise Exception(f"Failed to connect to supergfxctl: {e}")
    
    def _cleanup(self):
        """Cleanup resources"""
        if hasattr(self, 'proxy'):
            self.proxy = None
        self.connected = False
    
    def get_mode(self):
        if not self.connected:
            return None
        
        try:
            with timeout_context(3):
                mode_index = self.proxy.Mode()
                if 0 <= mode_index < len(self.GPU_MODES):
                    return self.GPU_MODES[mode_index]
                else:
                    raise Exception(f"Unrecognized graphics mode with index {mode_index}")
        except (dbus.exceptions.DBusException, TimeoutError) as e:
            raise Exception(f"Error getting GPU mode: {e}")
    
    def set_mode(self, new_mode):
        result = {
            "success": False,
            "message": "",
            "required_action": "none"
        }
        
        if not self.connected:
            raise Exception("Not connected to supergfxctl")
        
        if new_mode not in self.GPU_MODES:
            raise ValueError(f"Invalid mode: {new_mode}. Available modes: {', '.join(self.GPU_MODES)}")
        
        current_mode = self.get_mode()
        if current_mode is None:
            raise Exception("Failed to get current GPU mode")
        
        if new_mode == current_mode:
            result["success"] = True
            result["message"] = f"Already in {new_mode} mode"
            return result
        
        try:
            with timeout_context(10):  # GPU mode changes can take longer
                mode_index = self.GPU_MODES.index(new_mode)
                action_index = self.proxy.SetMode(mode_index)
                
                if 0 <= action_index < len(self.GFX_USER_ACTION):
                    action = self.GFX_USER_ACTION[action_index]
                    result["required_action"] = action
                    result["success"] = True
                    
                    if action == "nothing":
                        result["message"] = f"Graphics changed to {new_mode}. No action required."
                    elif action == "logout":
                        result["message"] = f"Graphics changed to {new_mode}. You need to log out for changes to take effect."
                    elif action == "reboot":
                        result["message"] = f"Graphics changed to {new_mode}. You need to reboot for changes to take effect."
                    
                    if new_mode == "integrated":
                        result["message"] += " You must switch to Integrated mode before switching to Compute or VFIO."
                else:
                    raise Exception(f"Unknown action index: {action_index}")
                
                return result
                
        except (dbus.exceptions.DBusException, TimeoutError) as e:
            raise Exception(f"Error setting GPU mode: {e}")

class CPUTurbo:
    _instance = None
    _lock = threading.Lock()
    
    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super(CPUTurbo, cls).__new__(cls)
        return cls._instance
    
    def __init__(self):
        if not hasattr(self, 'initialized'):
            self.turbo_path = "/sys/devices/system/cpu/intel_pstate/no_turbo"
            # Check if AMD system instead of Intel
            if not os.path.exists(self.turbo_path):
                self.turbo_path = "/sys/devices/system/cpu/cpufreq/boost"
                self.is_amd = True
            else:
                self.is_amd = False
            self.initialized = True
    
    def is_available(self):
        return os.path.exists(self.turbo_path)
    
    def is_enabled(self):
        if not self.is_available():
            return False
            
        try:
            with timeout_context(2):
                with open(self.turbo_path, 'r') as f:
                    content = f.read().strip()
                    
                if self.is_amd:
                    return content == "1"
                else:
                    return content == "0"
        except (OSError, TimeoutError) as e:
            print(f"Error checking turbo state: {str(e)}", file=sys.stderr)
            return False
    
    def enable(self):
        if not self.is_available():
            return False
            
        try:
            with timeout_context(2):
                value = "1" if self.is_amd else "0"
                with open(self.turbo_path, 'w') as f:
                    f.write(value)
                return True
        except (OSError, TimeoutError) as e:
            print(f"Error enabling turbo: {str(e)}", file=sys.stderr)
            return False
    
    def disable(self):
        if not self.is_available():
            return False
            
        try:
            with timeout_context(2):
                value = "0" if self.is_amd else "1"
                with open(self.turbo_path, 'w') as f:
                    f.write(value)
                return True
        except (OSError, TimeoutError) as e:
            print(f"Error disabling turbo: {str(e)}", file=sys.stderr)
            return False
            with open(self.turbo_path, 'w') as f:
                f.write(value)
            return True
        except Exception as e:
            print(f"Error disabling turbo: {str(e)}", file=sys.stderr)
            return False
    
    def get_status(self):
        available = self.is_available()
        enabled = self.is_enabled() if available else False
        
        return {
            "available": available,
            "enabled": enabled,
            "path": self.turbo_path,
            "system": "AMD" if self.is_amd else "Intel"
        }

class CPUPowerLimits:
    def __init__(self):
        """Initialize the CPU power limits controller."""
        # Common paths for Intel CPU power limits
        self.intel_rapl_path = "/sys/class/powercap/intel-rapl"
        self.intel_rapl_psys_path = "/sys/class/powercap/intel-rapl:0"
        
        # AMD CPU power limits paths (for newer AMD CPUs)
        self.amd_hsmp_path = "/sys/devices/platform/amd_hsmp"
        
        # Determine CPU type and available interfaces
        self.cpu_type = self._detect_cpu_type()
        self.available_interfaces = self._detect_available_interfaces()
        
        # Default min/max values (will be updated by _get_supported_range)
        self.min_power_limit = 10  # Conservative default minimum (5W)
        self.max_power_limit = 95  # Conservative default maximum (95W)
        
        # Update supported range
        # self._get_supported_range()
        
    def _detect_cpu_type(self):
            """Detect if the system has Intel or AMD CPU."""
            try:
                with open("/proc/cpuinfo", "r") as f:
                    cpuinfo = f.read()
                    if "Intel" in cpuinfo:
                        return "intel"
                    elif "AMD" in cpuinfo:
                        return "amd"
                    else:
                        return "unknown"
            except Exception as e:
                print(f"Error detecting CPU type: {str(e)}", file=sys.stderr)
                return "unknown"
        
    def _detect_available_interfaces(self):
        """Detect which power management interfaces are available."""
        interfaces = []
        
        # Check for Intel RAPL
        if os.path.exists(self.intel_rapl_path):
            interfaces.append("intel_rapl")
        
        # Check for Intel RAPL PSYS
        if os.path.exists(self.intel_rapl_psys_path):
            interfaces.append("intel_rapl_psys")
        
        # Check for AMD HSMP
        if os.path.exists(self.amd_hsmp_path):
            interfaces.append("amd_hsmp")
        
        # Check for thermald (Intel's thermal daemon)
        try:
            result = subprocess.run(["systemctl", "is-active", "thermald"], 
                                capture_output=True, text=True)
            if result.stdout.strip() == "active":
                interfaces.append("thermald")
        except:
            pass
        
        # Check for ryzenadj (for AMD Ryzen CPUs)
        try:
            result = subprocess.run(["which", "ryzenadj"], 
                                capture_output=True, text=True)
            if result.returncode == 0:
                interfaces.append("ryzenadj")
        except:
            pass
        
        return interfaces
    
    def _get_supported_range(self):
        """Determine the supported power limit range for the CPU."""
        if "intel_rapl" in self.available_interfaces:
            # For Intel CPUs, try to get the range from RAPL
            try:
                # Find the package directory (usually intel-rapl:0)
                package_dirs = [d for d in os.listdir(self.intel_rapl_path) 
                            if d.startswith("intel-rapl:") and os.path.isdir(os.path.join(self.intel_rapl_path, d))]
                
                if package_dirs:
                    package_path = os.path.join(self.intel_rapl_path, package_dirs[0])
                    
                    # Read max_power_uw (microWatts)
                    with open(os.path.join(package_path, "constraint_0_max_power_uw"), "r") as f:
                        max_uw = int(f.read().strip())
                        self.max_power_limit = max_uw / 1000000  # Convert to Watts
                    
                    # For minimum, we'll use a reasonable value (usually 5-15W depending on CPU)
                    self.min_power_limit = max(5, self.max_power_limit * 0.2)  # 20% of max or 5W, whichever is higher
            except Exception as e:
                print(f"Error determining power range from RAPL: {str(e)}", file=sys.stderr)
        
        elif "ryzenadj" in self.available_interfaces:
            # For AMD CPUs with ryzenadj, use known typical ranges
            # These values vary by CPU model, so we're using conservative estimates
            try:
                # Run ryzenadj --info to get current limits
                result = subprocess.run(["ryzenadj", "--info"], 
                                    capture_output=True, text=True)
                
                if result.returncode == 0:
                    # Parse the output to find TDP limits
                    tdp_match = re.search(r"STAPM LIMIT.*?(\d+\.\d+)", result.stdout)
                    if tdp_match:
                        current_tdp = float(tdp_match.group(1))
                        # Use current TDP to estimate range
                        self.max_power_limit = current_tdp * 1.5  # 150% of current TDP
                        self.min_power_limit = max(5, current_tdp * 0.5)  # 50% of current TDP or 5W
            except Exception as e:
                print(f"Error determining power range for AMD: {str(e)}", file=sys.stderr)
        
        # Ensure we have reasonable values
        if self.min_power_limit < 5:
            self.min_power_limit = 5
        if self.max_power_limit > 120:
            self.max_power_limit = 120
        if self.max_power_limit < 15:
            self.max_power_limit = 15
    
    def get_current_power_limits(self):
        """Get the current PL1 and PL2 power limits."""
        pl1 = None
        pl2 = None
        
        if "intel_rapl" in self.available_interfaces:
            try:
                # Find the package directory
                package_dirs = [d for d in os.listdir(self.intel_rapl_path) 
                            if d.startswith("intel-rapl:") and os.path.isdir(os.path.join(self.intel_rapl_path, d))]
                
                if package_dirs:
                    package_path = os.path.join(self.intel_rapl_path, package_dirs[0])
                    
                    # PL1 is usually constraint_0
                    with open(os.path.join(package_path, "constraint_0_power_limit_uw"), "r") as f:
                        pl1 = int(f.read().strip()) / 1000000  # Convert to Watts
                    
                    # PL2 is usually constraint_1
                    try:
                        with open(os.path.join(package_path, "constraint_1_power_limit_uw"), "r") as f:
                            pl2 = int(f.read().strip()) / 1000000  # Convert to Watts
                    except:
                        # Some systems don't expose PL2 directly
                        pass
            except Exception as e:
                print(f"Error reading power limits from RAPL: {str(e)}", file=sys.stderr)
        
        elif "thermald" in self.available_interfaces:
            try:
                # Try to get values from thermald using dbus
                import dbus
                bus = dbus.SystemBus()
                thermal_obj = bus.get_object('org.freedesktop.thermald', '/org/freedesktop/thermald')
                thermal_iface = dbus.Interface(thermal_obj, 'org.freedesktop.thermald')
                
                # This is a simplified approach - actual implementation would need to parse thermald's output
                tdp_info = thermal_iface.GetTdpValues()
                if tdp_info and len(tdp_info) >= 2:
                    pl1 = float(tdp_info[0])
                    pl2 = float(tdp_info[1])
            except Exception as e:
                print(f"Error reading power limits from thermald: {str(e)}", file=sys.stderr)
        
        elif "ryzenadj" in self.available_interfaces:
            try:
                # Run ryzenadj --info to get current limits
                result = subprocess.run(["ryzenadj", "--info"], 
                                    capture_output=True, text=True)
                
                if result.returncode == 0:
                    # Parse the output to find TDP limits
                    stapm_match = re.search(r"STAPM LIMIT.*?(\d+\.\d+)", result.stdout)
                    fast_limit_match = re.search(r"PPT LIMIT FAST.*?(\d+\.\d+)", result.stdout)
                    
                    if stapm_match:
                        pl1 = float(stapm_match.group(1))
                    if fast_limit_match:
                        pl2 = float(fast_limit_match.group(1))
            except Exception as e:
                print(f"Error reading power limits from ryzenadj: {str(e)}", file=sys.stderr)
        
        # If we couldn't get values, use reasonable defaults based on the range
        if pl1 is None:
            pl1 = (self.min_power_limit + self.max_power_limit) / 2
        if pl2 is None and pl1 is not None:
            pl2 = pl1 * 1.25  # Typical PL2 is about 1.25x PL1
        
        return {
            "pl1": round(pl1, 1) if pl1 is not None else None,
            "pl2": round(pl2, 1) if pl2 is not None else None,
            "min": round(self.min_power_limit, 1),
            "max": round(self.max_power_limit, 1)
        }
    
    def set_power_limits(self, pl1=None, pl2=None):
        """
        Set PL1 and/or PL2 power limits.
        
        Args:
            pl1 (float): PL1 power limit in Watts
            pl2 (float): PL2 power limit in Watts
            
        Returns:
            dict: Result with success status and message
        """
        result = {
            "success": False,
            "message": ""
        }
        
        # Validate input values
        if pl1 is not None:
            if not isinstance(pl1, (int, float)) or pl1 < self.min_power_limit or pl1 > self.max_power_limit:
                result["message"] = f"Invalid PL1 value. Must be between {self.min_power_limit}W and {self.max_power_limit}W."
                return result
        
        if pl2 is not None:
            if not isinstance(pl2, (int, float)) or pl2 < self.min_power_limit or pl2 > self.max_power_limit:
                result["message"] = f"Invalid PL2 value. Must be between {self.min_power_limit}W and {self.max_power_limit}W."
                return result
        
        # Set power limits based on available interfaces
        if "intel_rapl" in self.available_interfaces:
            try:
                # Find the package directory
                package_dirs = [d for d in os.listdir(self.intel_rapl_path) 
                            if d.startswith("intel-rapl:") and os.path.isdir(os.path.join(self.intel_rapl_path, d))]
                
                if package_dirs:
                    package_path = os.path.join(self.intel_rapl_path, package_dirs[0])
                    
                    # Set PL1 (constraint_0)
                    if pl1 is not None:
                        pl1_uw = int(pl1 * 1000000)  # Convert to microWatts
                        cmd = f"echo {pl1_uw} | pkexec tee {os.path.join(package_path, 'constraint_0_power_limit_uw')}"
                        subprocess.run(cmd, shell=True, check=True)
                    
                    # Set PL2 (constraint_1)
                    if pl2 is not None:
                        pl2_uw = int(pl2 * 1000000)  # Convert to microWatts
                        cmd = f"echo {pl2_uw} | pkexec tee {os.path.join(package_path, 'constraint_1_power_limit_uw')}"
                        subprocess.run(cmd, shell=True, check=True)
                    
                    result["success"] = True
                    result["message"] = "Power limits set successfully."
                else:
                    result["message"] = "Could not find Intel RAPL package directory."
            except Exception as e:
                result["message"] = f"Error setting power limits via RAPL: {str(e)}"
        
        elif "ryzenadj" in self.available_interfaces:
            try:
                cmd_parts = ["pkexec", "ryzenadj"]
                
                if pl1 is not None:
                    cmd_parts.append(f"--stapm-limit={pl1}")
                
                if pl2 is not None:
                    cmd_parts.append(f"--fast-limit={pl2}")
                
                if len(cmd_parts) > 2:  # Only run if we have parameters to set
                    result_proc = subprocess.run(cmd_parts, capture_output=True, text=True)
                    
                    if result_proc.returncode == 0:
                        result["success"] = True
                        result["message"] = "Power limits set successfully."
                    else:
                        result["message"] = f"Error setting power limits: {result_proc.stderr}"
                else:
                    result["message"] = "No power limits specified to set."
            except Exception as e:
                result["message"] = f"Error setting power limits via ryzenadj: {str(e)}"
        
        else:
            result["message"] = "No supported interface available to set power limits."
        
        return result
    
    def get_supported_range(self):
        """Get the supported power limit range."""
        return {
            "min": round(self.min_power_limit, 1),
            "max": round(self.max_power_limit, 1)
        }

CONFIG_PATH = str(Path.home() / ".config/asustufcontrol_led.json")



def load_led_config():
    try:
        with open(CONFIG_PATH, "r") as f:
            config = json.load(f)
            return config
    except Exception:
        return {"led_mode": 0, "led_power": [1,1,1,1]}

def get_led_status():
    # Import the asus keyboard control
    from asus_keyboard_lighting_control import AsusKeyboardLighting
    controller = AsusKeyboardLighting()
    status = controller.get_current_status()
    led_mode = status['led_mode'] 
    led_power = status['led_power'] 
    
   
    print(f"led_mode:{led_mode}")
    print(f"led_power:{int(led_power[0])} {int(led_power[1])} {int(led_power[2])} {int(led_power[3])}")
    sys.exit(0)
    
def get_led_brightness():
        # Import the asus keyboard control
    from asus_keyboard_lighting_control import AsusKeyboardLighting
    controller = AsusKeyboardLighting()
    status = controller.get_current_status()
  
    
   
   
    print(f"led_brightness:{status['brightness']}")
    sys.exit(0)

def set_led_power(boot, awake, sleep, shutdown):
    from asus_keyboard_lighting_control import AsusKeyboardLighting
    controller = AsusKeyboardLighting()
    # zone_id=1 always
    controller.set_led_power(zone_id=1, boot=boot, awake=awake, sleep=sleep, shutdown=shutdown)

    print("LED power updated")
    sys.exit(0)

def set_led_mode(mode):
    from asus_keyboard_lighting_control import AsusKeyboardLighting
    controller = AsusKeyboardLighting()
    controller.set_led_mode(int(mode))

    print("LED mode updated")
    sys.exit(0)
    
def set_led_brightness(brightness):
    from asus_keyboard_lighting_control import AsusKeyboardLighting
    controller = AsusKeyboardLighting()
    controller.set_brightness(int(brightness))

    print("LED mode updated")
    sys.exit(0)


def get_panel_overdrive_status():
    """Get current panel overdrive status using asusctl"""
    try:
        result = subprocess.run(
            ["asusctl", "armoury"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            # Parse output to find panel_overdrive current value
            for line in result.stdout.split('\n'):
                if 'panel_overdrive:' in line:
                    # Look for the next line with current:
                    lines = result.stdout.split('\n')
                    for i, line in enumerate(lines):
                        if 'panel_overdrive:' in line and i + 1 < len(lines):
                            next_line = lines[i + 1]
                            if 'current:' in next_line:
                                # Extract the current value: current: [0,(1)]
                                match = re.search(r'current:\s*\[.*\((\d+)\).*\]', next_line)
                                if match:
                                    return match.group(1)
            return "0"  # Default if parsing fails
        else:
            if DEBUG_MODE:
                logging.debug(f"asusctl armoury failed: {result.stderr}")
            return "0"
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error getting panel overdrive status: {e}")
        return "0"

def get_charging_type():
    """Detect charging type (AC vs Type-C USB-PD)"""
    try:
        # Check for USB-PD power supplies
        power_supply_path = '/sys/class/power_supply'
        if os.path.exists(power_supply_path):
            for ps in os.listdir(power_supply_path):
                ps_path = os.path.join(power_supply_path, ps)
                try:
                    # Check if it's an online power supply
                    online_path = os.path.join(ps_path, 'online')
                    if os.path.exists(online_path):
                        with open(online_path, 'r') as f:
                            online = f.read().strip()
                            if online == '1':  # Power supply is online
                                # Check the type
                                type_path = os.path.join(ps_path, 'type')
                                if os.path.exists(type_path):
                                    with open(type_path, 'r') as f:
                                        ps_type = f.read().strip()
                                        if ps_type == 'USB':
                                            # Check if it supports USB-PD
                                            usb_type_path = os.path.join(ps_path, 'usb_type')
                                            if os.path.exists(usb_type_path):
                                                with open(usb_type_path, 'r') as f:
                                                    usb_type = f.read().strip()
                                                    if 'PD' in usb_type or 'C' in usb_type:
                                                        return "USB_PD"
                                            return "USB"
                                        elif ps_type == 'Mains' or ps_type == 'ADP1':
                                            return "AC"
                except Exception:
                    continue  # Skip this power supply if we can't read it
        
        # Fallback: assume AC if we can't determine
        return "AC"
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error detecting charging type: {e}")
        return "AC"

def get_battery_charging_status():
    """Get actual battery charging status independent of ASUS charge modes"""
    try:
        # Check BAT0 and BAT1 for battery status
        for bat in ['BAT0', 'BAT1']:
            battery_path = f'/sys/class/power_supply/{bat}'
            if os.path.exists(battery_path):
                status_path = os.path.join(battery_path, 'status')
                if os.path.exists(status_path):
                    with open(status_path, 'r') as f:
                        status = f.read().strip().upper()
                        
                        # Map battery status to our codes
                        if status == 'DISCHARGING':
                            return "0"
                        elif status == 'CHARGING':
                            # Get charging type for more detail
                            charging_type = get_charging_type()
                            if charging_type == "USB_PD":
                                return "2"  # Type-C charging
                            else:
                                return "1"  # AC charging
                        elif status == 'FULL':
                            return "3"  # Fully charged
                        elif status == 'NOT_CHARGING':
                            # Check if plugged in but not charging due to charge limit
                            capacity_path = os.path.join(battery_path, 'capacity')
                            if os.path.exists(capacity_path):
                                with open(capacity_path, 'r') as f:
                                    capacity = int(f.read().strip())
                                    if capacity >= 95:  # Nearly full
                                        return "3"  # Consider as fully charged
                                    else:
                                        return "4"  # Plugged in but not charging
                            return "4"
                        else:
                            return "0"  # Unknown, assume discharging
        
        # If no battery found, return unknown
        return "0"
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error getting battery charging status: {e}")
        return "0"

def get_charge_mode_status():
    """Get current charge mode status using asusctl with AC/Type-C detection"""
    try:
        result = subprocess.run(
            ["asusctl", "armoury"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            # Parse output to find charge_mode current value
            for line in result.stdout.split('\n'):
                if 'charge_mode:' in line:
                    # Look for the next line with current:
                    lines = result.stdout.split('\n')
                    for i, line in enumerate(lines):
                        if 'charge_mode:' in line and i + 1 < len(lines):
                            next_line = lines[i + 1]
                            if 'current:' in next_line:
                                # Extract the current value: current: [0,(1),2]
                                match = re.search(r'current:\s*\[.*\((\d+)\).*\]', next_line)
                                if match:
                                    charge_mode = match.group(1)
                                    
                                    # If charging (mode 1), check if it's AC or Type-C
                                    if charge_mode == "1":
                                        # Check power supply type to differentiate AC vs Type-C
                                        charging_type = get_charging_type()
                                        if charging_type == "USB_PD":  # Type-C charging
                                            return "2"  # Type-C charging
                                        else:  # AC charging
                                            return "1"  # AC charging
                                    else:
                                        return charge_mode
            return "1"  # Default if parsing fails
        else:
            if DEBUG_MODE:
                logging.debug(f"asusctl armoury failed: {result.stderr}")
            return "1"
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error getting charge mode status: {e}")
        return "1"

def set_panel_overdrive(enable):
    """Set panel overdrive on/off"""
    try:
        value = "1" if enable else "0"
        # Try multiple command formats as asusctl versions may differ
        commands_to_try = [
            ["asusctl", "armoury", "panel_overdrive", value],
            ["asusctl", "platform", "panel_overdrive", value]
        ]
        
        for cmd in commands_to_try:
            try:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                
                if result.returncode == 0:
                    print(f"Panel overdrive {'enabled' if enable else 'disabled'}")
                    return True
                elif DEBUG_MODE:
                    logging.debug(f"Command {' '.join(cmd)} failed: {result.stderr}")
            except Exception as e:
                if DEBUG_MODE:
                    logging.debug(f"Command {' '.join(cmd)} exception: {e}")
                continue
        
        # If all commands failed, print error
        print(f"Failed to set panel overdrive - feature may not be supported on this system", file=sys.stderr)
        return False
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error setting panel overdrive: {e}")
        print(f"Error setting panel overdrive: {e}", file=sys.stderr)
        return False

# Removed set_charge_mode function as charge_mode is read-only and only reports battery status

def get_service_status(service_name):
    """Get service status using systemctl"""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", service_name],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        # systemctl is-active returns "active", "inactive", "failed", etc.
        status = result.stdout.strip()
        if DEBUG_MODE:
            logging.debug(f"{service_name} service status: {status}")
        
        # Return 1 for active, 0 for inactive/failed/unknown, 2 for not found
        if status == "active":
            return "1"
        elif status in ["inactive", "failed"]:
            return "0"
        else:
            return "2"  # Not found or unknown state
    except subprocess.TimeoutExpired:
        if DEBUG_MODE:
            logging.debug(f"systemctl is-active {service_name} timed out")
        return "2"
    except FileNotFoundError:
        if DEBUG_MODE:
            logging.debug("systemctl command not found")
        return "2"
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error checking {service_name} service status: {e}")
        return "2"

def get_nvidia_powerd_status():
    """Get nvidia-powerd service status using systemctl"""
    return get_service_status("nvidia-powerd.service")

def get_asusctl_status():
    """Get asusctl service status using systemctl"""
    return get_service_status("asusd.service")

def get_supergfxd_status():
    """Get supergfxd service status using systemctl"""
    return get_service_status("supergfxd.service")

def set_nvidia_powerd_service(enable):
    """Enable or disable nvidia-powerd service using systemctl"""
    try:
        action = "enable" if enable else "disable"
        start_stop = "start" if enable else "stop"
        
        # First enable/disable the service
        enable_result = subprocess.run(
            ["pkexec", "systemctl", action, "nvidia-powerd.service"],
            capture_output=True,
            text=True,
            timeout=15
        )
        
        if enable_result.returncode != 0:
            if DEBUG_MODE:
                logging.debug(f"systemctl {action} nvidia-powerd.service failed: {enable_result.stderr}")
            print(f"Failed to {action} nvidia-powerd service: {enable_result.stderr}", file=sys.stderr)
            return False
        
        # Then start/stop the service immediately
        start_stop_result = subprocess.run(
            ["pkexec", "systemctl", start_stop, "nvidia-powerd.service"],
            capture_output=True,
            text=True,
            timeout=15
        )
        
        if start_stop_result.returncode != 0:
            if DEBUG_MODE:
                logging.debug(f"systemctl {start_stop} nvidia-powerd.service failed: {start_stop_result.stderr}")
            print(f"Failed to {start_stop} nvidia-powerd service: {start_stop_result.stderr}", file=sys.stderr)
            return False
        
        action_text = "enabled and started" if enable else "disabled and stopped"
        print(f"nvidia-powerd service {action_text}")
        return True
        
    except subprocess.TimeoutExpired:
        print("nvidia-powerd service command timed out", file=sys.stderr)
        return False
    except FileNotFoundError:
        print("Error: systemctl command not found", file=sys.stderr)
        return False
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error managing nvidia-powerd service: {e}")
        print(f"Error managing nvidia-powerd service: {e}", file=sys.stderr)
        return False
def get_current_refresh_rate():
    """Get current display refresh rate using kscreen-doctor"""
    try:
        result = subprocess.run(
            ["kscreen-doctor", "-o"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            # Parse kscreen-doctor output to find active mode
            for line in result.stdout.split('\n'):
                if 'Modes:' in line:
                    # Look for pattern like "2:1920x1080@60*" where * indicates active
                    import re
                    match = re.search(r'(\d+):.*@(\d+(?:\.\d+)?)\*', line)
                    if match:
                        return float(match.group(2))
            return 60.0  # Default if not found
        else:
            # Fallback to xrandr
            return get_current_refresh_rate_xrandr()
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error getting refresh rate with kscreen-doctor: {e}")
        # Fallback to xrandr
        return get_current_refresh_rate_xrandr()

def get_supported_refresh_rates():
    """Get list of supported refresh rates for the display"""
    import re
    try:
        result = subprocess.run(
            ["kscreen-doctor", "-o"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            if DEBUG_MODE:
                logging.debug(f"kscreen-doctor output: {result.stdout}")
            
            # Parse kscreen-doctor output to find all available modes
            rates = set()
            for line in result.stdout.split('\n'):
                if 'Modes:' in line:
                    if DEBUG_MODE:
                        logging.debug(f"Found Modes line: {line}")
                        logging.debug(f"Line repr: {repr(line)}")
                    
                    # Strip ANSI escape codes first
                    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
                    clean_line = ansi_escape.sub('', line)
                    if DEBUG_MODE:
                        logging.debug(f"Clean line: {clean_line}")
                    
                    # Look for patterns like "1:1920x1080@144*!" or "2:1920x1080@60"
                    pattern = r'\d+:1920x1080@(\d+(?:\.\d+)?)[*!]*'
                    if DEBUG_MODE:
                        logging.debug(f"Using regex pattern: {pattern}")
                    matches = re.findall(pattern, clean_line)
                    if DEBUG_MODE:
                        logging.debug(f"Regex matches: {matches}")
                    for match in matches:
                        rate = float(match)
                        if DEBUG_MODE:
                            logging.debug(f"Processing rate: {rate}")
                        if rate >= 60:  # Only include rates 60Hz and above
                            rates.add(int(rate))
                            if DEBUG_MODE:
                                logging.debug(f"Added rate {int(rate)} to set")
            
            if DEBUG_MODE:
                logging.debug(f"Final rates set: {rates}")
            
            # Convert to sorted list
            supported_rates = sorted(list(rates))
            if supported_rates:
                return supported_rates
            else:
                return [60, 144]  # Default fallback
        else:
            # Fallback to xrandr
            return get_supported_refresh_rates_xrandr()
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error getting supported refresh rates with kscreen-doctor: {e}")
        # Fallback to xrandr
        return get_supported_refresh_rates_xrandr()

def get_supported_refresh_rates_xrandr():
    """Fallback method to get supported refresh rates using xrandr"""
    try:
        result = subprocess.run(
            ["xrandr", "--current"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            rates = set()
            for line in result.stdout.split('\n'):
                if ' connected' in line and 'primary' in line:
                    # Find the modes line for this display
                    continue
                elif 'x' in line and 'Hz' in line:
                    # Look for pattern like "1920x1080     60.00*+  59.93"
                    import re
                    matches = re.findall(r'(\d+(?:\.\d+)?).*Hz', line)
                    for match in matches:
                        rate = float(match)
                        if rate >= 60:  # Only include rates 60Hz and above
                            rates.add(int(rate))
            
            # Convert to sorted list
            supported_rates = sorted(list(rates))
            if supported_rates:
                return supported_rates
            else:
                return [60, 144]  # Default fallback
        else:
            return [60, 144]  # Default fallback
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error getting supported refresh rates with xrandr: {e}")
        return [60, 144]  # Default fallback

def get_current_refresh_rate_xrandr():
    """Fallback method to get refresh rate using xrandr"""
    try:
        result = subprocess.run(
            ["xrandr", "--current"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            for line in result.stdout.split('\n'):
                if '*' in line and ('x' in line or 'Hz' in line):
                    # Extract refresh rate from lines like: "1920x1080    59.96*+ 144.00   120.00"
                    # Match patterns like "59.96*" or "165.00*+"
                    match = re.search(r'(\d+\.?\d*)\*', line)
                    if match:
                        return float(match.group(1))
            return 60.0  # Default if not found
        else:
            return 60.0
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error getting refresh rate with xrandr: {e}")
        return 60.0

def set_refresh_rate(rate):
    """Set display refresh rate using kscreen-doctor"""
    try:
        # First try to use kscreen-doctor to set the refresh rate
        # Get available modes first
        result = subprocess.run(
            ["kscreen-doctor", "-o"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            # Parse output to find the mode ID for the desired refresh rate
            mode_id = None
            display_name = None
            
            for line in result.stdout.split('\n'):
                if 'Output:' in line and 'eDP' in line:
                    # Extract display name like "eDP-1"
                    parts = line.split()
                    if len(parts) >= 3:
                        display_name = parts[2]
                elif 'Modes:' in line and display_name:
                    # Look for pattern like "1:1920x1080@144" matching our desired rate
                    import re
                    pattern = rf'(\d+):1920x1080@{int(rate)}[!\*]?'
                    match = re.search(pattern, line)
                    if match:
                        mode_id = match.group(1)
                        break
            
            if mode_id and display_name:
                # Set the mode using kscreen-doctor
                result = subprocess.run(
                    ["kscreen-doctor", f"output.{display_name}.mode.{mode_id}"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                
                if result.returncode == 0:
                    print(f"Refresh rate set to: {rate}Hz")
                    return True
                else:
                    if DEBUG_MODE:
                        logging.debug(f"kscreen-doctor mode set failed: {result.stderr}")
                    # Fall back to xrandr
                    return set_refresh_rate_xrandr(rate)
            else:
                if DEBUG_MODE:
                    logging.debug(f"Could not find mode for {rate}Hz")
                # Fall back to xrandr
                return set_refresh_rate_xrandr(rate)
        else:
            # Fall back to xrandr
            return set_refresh_rate_xrandr(rate)
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error setting refresh rate with kscreen-doctor: {e}")
        # Fall back to xrandr
        return set_refresh_rate_xrandr(rate)

def set_refresh_rate_xrandr(rate):
    """Fallback method to set refresh rate using xrandr"""
    try:
        # First get the primary display
        result = subprocess.run(
            ["xrandr", "--current"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode != 0:
            print("Failed to get display information", file=sys.stderr)
            return False
        
        # Find connected display
        primary_display = None
        for line in result.stdout.split('\n'):
            if ' connected' in line and 'primary' in line:
                primary_display = line.split()[0]
                break
        
        if not primary_display:
            # Fallback to first connected display
            for line in result.stdout.split('\n'):
                if ' connected' in line:
                    primary_display = line.split()[0]
                    break
        
        if not primary_display:
            print("No display found", file=sys.stderr)
            return False
        
        # Set the refresh rate
        result = subprocess.run(
            ["xrandr", "--output", primary_display, "--rate", str(rate)],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode == 0:
            print(f"Refresh rate set to: {rate}Hz")
            return True
        else:
            if DEBUG_MODE:
                logging.debug(f"xrandr failed: {result.stderr}")
            print(f"Failed to set refresh rate: {result.stderr}", file=sys.stderr)
            return False
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error setting refresh rate with xrandr: {e}")
        print(f"Error setting refresh rate: {e}", file=sys.stderr)
        return False

def auto_refresh_panel_mode():
    """Auto mode: battery status 0→60Hz+overdrive off, battery status 1/2/3→max refresh+overdrive on"""
    try:
        # Get current battery charging status to determine current mode
        current_battery_status = int(get_battery_charging_status())
        
        # Get maximum supported refresh rate
        supported_rates = get_supported_refresh_rates()
        max_refresh_rate = max(supported_rates) if supported_rates else 144
        
        # If discharging (battery_status = 0), switch to power saving mode
        # If charging or fully charged (battery_status = 1, 2, 3), switch to performance mode  
        if current_battery_status == 0:
            # Power saving mode: 60Hz + panel overdrive off
            set_refresh_rate(60)
            set_panel_overdrive(False)
            print(f"Auto mode: Power Saving (60Hz + Panel overdrive OFF) - Battery discharging")
        else:
            # Performance mode: max refresh rate + panel overdrive on
            set_refresh_rate(max_refresh_rate)  # Will apply if display supports it
            set_panel_overdrive(True)
            if current_battery_status == 1:
                print(f"Auto mode: Performance ({max_refresh_rate}Hz + Panel overdrive ON) - AC charging")
            elif current_battery_status == 2:
                print(f"Auto mode: Performance ({max_refresh_rate}Hz + Panel overdrive ON) - Type-C charging")
            elif current_battery_status == 3:
                print(f"Auto mode: Performance ({max_refresh_rate}Hz + Panel overdrive ON) - Fully charged")
            elif current_battery_status == 4:
                print(f"Auto mode: Performance ({max_refresh_rate}Hz + Panel overdrive ON) - Plugged but not charging")
            else:
                print(f"Auto mode: Performance ({max_refresh_rate}Hz + Panel overdrive ON) - Battery status: {current_battery_status}")
        
        return True
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error in auto refresh panel mode: {e}")
        print(f"Error in auto mode: {e}", file=sys.stderr)
        return False


def get_system_status():
    try:    
        # Get power profile status
        power_profile = PowerProfile()
        current_profile = power_profile.get_active_profile()
        
        # Get GPU mode
        gpu_control = GPUControl()
        current_gpu_mode = gpu_control.get_mode()
        
        # Get charge limit
        charge_path = '/sys/class/power_supply/BAT1/charge_control_end_threshold'
        try:
            with open(charge_path, 'r') as f:
                charge_limit = f.read().strip()
        except:
            charge_limit = "100"  # Default if not available

        # Get CPU Turbo status
        turbo = CPUTurbo()
        turbo_status = turbo.get_status()
        
        # Get fan speeds and CPU temperature
        fan_speeds = get_fan_speeds()
        cpu_temp = get_cpu_temperature()
        
        # Get panel overdrive, charge mode status, current refresh rate, and service statuses
        panel_overdrive_status = get_panel_overdrive_status()
        charge_mode_status = get_charge_mode_status()
        battery_charging_status = get_battery_charging_status()
        current_refresh_rate = get_current_refresh_rate()
        
        # Get service statuses
        asusctl_status = get_asusctl_status()
        supergfxd_status = get_supergfxd_status()
        nvidia_powerd_status = get_nvidia_powerd_status()
        
        status = {
            "power_profile": current_profile,
            "gpu_mode": current_gpu_mode,
            "charge_limit": charge_limit,
            "turbo_enabled": "1" if turbo_status["enabled"] else "0",
            "cpu_fan_speed": fan_speeds["cpu_fan"],
            "gpu_fan_speed": fan_speeds["gpu_fan"],
            "cpu_temperature": cpu_temp,
            "panel_overdrive": panel_overdrive_status,
            "charge_mode": charge_mode_status,
            "battery_charging_status": battery_charging_status,
            "current_refresh_rate": str(int(current_refresh_rate)),
            "asusctl_status": asusctl_status,
            "supergfxd_status": supergfxd_status,
            "nvidia_powerd_status": nvidia_powerd_status
        }
        
        print(f"{status['power_profile']}")
        print(f"{status['gpu_mode']}")
        print(f"{status['charge_limit']}")
        print(f"{status['turbo_enabled']}")
        print(f"{status['cpu_fan_speed']}")
        print(f"{status['gpu_fan_speed']}")
        print(f"{status['cpu_temperature']}")
        print(f"{status['panel_overdrive']}")
        print(f"{status['charge_mode']}")
        print(f"{status['battery_charging_status']}")
        print(f"{status['current_refresh_rate']}")
        print(f"{status['asusctl_status']}")
        print(f"{status['supergfxd_status']}")
        print(f"{status['nvidia_powerd_status']}")
        
        if DEBUG_MODE:
            logging.debug(f"Status: {status}")
            
    except Exception as e:
        if DEBUG_MODE:
            logging.error(f"Error in get_system_status: {str(e)}")
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

def set_power_profile(profile):
    try:
        power_profile = PowerProfile()
        power_profile.set_profile(profile.lower())
        print(f"Profile set to: {profile}")
        sys.exit(0)
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

def set_gpu_mode(mode):
    try:
        gpu_control = GPUControl()
        mode_mapping = {
            'Integrated': 'integrated',
            'Hybrid': 'hybrid',
            'asusmuxdiscreet': 'asusmuxdiscreet'
        }
        
        supergfx_mode = mode_mapping.get(mode, mode.lower())
        result = gpu_control.set_mode(supergfx_mode)
        
        print(result["message"])
        if result["required_action"] in ["logout", "logout"]:
            print("LOGOUT_REQUIRED")
        if result["required_action"] in ["reboot", "reboot"]:
            print("REBOOT_REQUIRED")
        sys.exit(0)
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

def set_charge_limit(limit):
    if DEBUG_MODE:
        logging.debug(f"Setting charge limit to: {limit}")
    try:
        # Validate input
        limit = int(limit)
        if not (50 <= limit <= 100):
            print("Error: Charge limit must be between 50 and 100", file=sys.stderr)
            sys.exit(1)

        # Direct write to the file
        charge_path = '/sys/class/power_supply/BAT1/charge_control_end_threshold'
        if DEBUG_MODE:
            logging.debug(f"Writing to {charge_path}")
        
        # Check if file exists and is writable
        if not os.path.exists(charge_path):
            print(f"Error: Battery charge limit file not found: {charge_path}", file=sys.stderr)
            sys.exit(1)
            
        try:
            with open(charge_path, 'w') as f:
                f.write(str(limit))
            
            # Return success message
            print(f"Charge limit set to: {limit}%")
            if DEBUG_MODE:
                logging.debug(f"Charge limit change successful")
            sys.exit(0)
        except PermissionError:
            print(f"Error: Permission denied writing to {charge_path}", file=sys.stderr)
            sys.exit(1)
            
    except ValueError:
        print("Error: Charge limit must be a number", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

def toggle_one_shot_charge():
    """Toggle one-shot battery charge to 100% using asusctl"""
    try:
        result = subprocess.run(
            ["asusctl", "--one-shot-chg"],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode == 0:
            print("One-shot charge to 100% toggled successfully")
            if DEBUG_MODE:
                logging.debug(f"asusctl --one-shot-chg output: {result.stdout}")
            return True
        else:
            if DEBUG_MODE:
                logging.debug(f"asusctl --one-shot-chg failed: {result.stderr}")
            print(f"Failed to toggle one-shot charge: {result.stderr}", file=sys.stderr)
            return False
    except subprocess.TimeoutExpired:
        print("One-shot charge command timed out", file=sys.stderr)
        return False
    except FileNotFoundError:
        print("Error: asusctl command not found", file=sys.stderr)
        return False
    except Exception as e:
        if DEBUG_MODE:
            logging.debug(f"Error toggling one-shot charge: {e}")
        print(f"Error toggling one-shot charge: {e}", file=sys.stderr)
        return False

def get_power_limits():
    try:
        power_limits = CPUPowerLimits()
        current = power_limits.get_current_power_limits()
        
        # Print in format that can be easily parsed by the QML frontend
        print(f"{current['pl1']}")  # Current PL1
        print(f"{current['pl2']}")  # Current PL2
        print(f"{current['min']}")  # Min supported
        print(f"{current['max']}")  # Max supported
        sys.exit(0)
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

def set_power_limit(pl1=None, pl2=None):
    try:
        power_limits = CPUPowerLimits()
        
        # Convert string inputs to float if provided
        if pl1 is not None:
            pl1 = float(pl1)
        if pl2 is not None:
            pl2 = float(pl2)
        
        result = power_limits.set_power_limits(pl1, pl2)
        
        if result["success"]:
            print("Power limits set successfully")
            sys.exit(0)
        else:
            print(f"Error: {result['message']}", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

def detect_dgpu():
    """
    Detects the presence of an NVIDIA or AMD dedicated GPU using lspci.

    Returns:
        str: 'nvidia' if an NVIDIA GPU is detected,
             'amd' if an AMD GPU is detected,
             'none' if neither is detected or the command fails.
    """
    command = "lspci | grep -i vga"
    try:
        # Execute the command
        result = subprocess.run(
            command,
            shell=True,
            check=True,  # Raise CalledProcessError if the command returns a non-zero exit code
            capture_output=True,
            text=True,   # Decode stdout/stderr as text
            encoding='utf-8'
        )
        output = result.stdout.lower()

        # Check the output for keywords
        if "nvidia" in output:
            return "nvidia"
        elif "amd" in output or "radeon" in output: # Include 'radeon' as it's common for AMD GPUs
            return "amd"
        else:
            return "none"

    except FileNotFoundError:
        print("Error: lspci command not found. Make sure it's installed and in your PATH.", file=sys.stderr)
        return "none"
    except subprocess.CalledProcessError as e:
        # This happens if grep finds nothing (exit code 1) or other errors
        # If grep finds nothing, it means no 'vga' devices matched, which is fine.
        # If it's another error, print it.
        if e.returncode == 1:
             # grep returned 1, meaning no lines matched 'vga'. This is expected if no GPUs are found.
             return "none"
        else:
            print(f"Error executing command: {e}", file=sys.stderr)
            print(f"Command output (stderr): {e.stderr}", file=sys.stderr)
            return "none"
    except Exception as e:
        print(f"An unexpected error occurred: {e}", file=sys.stderr)
        return "none"


if __name__ == '__main__':
    try:
        # Setup signal handlers for proper cleanup
        def signal_handler(signum, frame):
            cleanup_on_exit()
            sys.exit(0)
        
        signal.signal(signal.SIGTERM, signal_handler)
        signal.signal(signal.SIGINT, signal_handler)
        
        setup_logging('--debug' in sys.argv)
        if DEBUG_MODE:
            logging.debug(f"Helper script started with args: {sys.argv}")
        
        # Remove debug flag from arguments if present
        args = [arg for arg in sys.argv if arg != '--debug']
        
        if len(args) < 2:
            if DEBUG_MODE:
                logging.debug("Usage: helper.py [status|profile|gpu|charge|turbo] [value]")
            sys.exit(1)
        
        command = args[1]
        if DEBUG_MODE:
            logging.debug(f"Processing command: {command}")
        
        # Use timeout wrapper for all operations
        with timeout_context(30):  # 30 second global timeout
            # Replace all print() to stderr with debug logging
            if command == 'status':
                get_system_status()
            elif command == 'profile' and len(args) > 2:
                set_power_profile(args[2])
            elif command == 'gpu' and len(args) > 2:
                set_gpu_mode(args[2])
            elif command == 'charge' and len(args) > 2:
                if DEBUG_MODE:
                    logging.debug(f"Setting charge limit to: {args[2]}")
                set_charge_limit(args[2])
            elif command == 'one-shot-charge':
                if DEBUG_MODE:
                    logging.debug("Toggling one-shot charge to 100%")
                if toggle_one_shot_charge():
                    sys.exit(0)
                else:
                    sys.exit(1)
            elif command == 'turbo' and len(args) > 2:
                turbo = CPUTurbo()
                if args[2] == "1":
                    if turbo.enable():
                        print("CPU Turbo enabled")
                    else:
                        print("Failed to enable CPU Turbo", file=sys.stderr)
                        sys.exit(1)
                elif args[2] == "0":
                    if turbo.disable():
                        print("CPU Turbo disabled")
                    else:
                        print("Failed to disable CPU Turbo", file=sys.stderr)
                        sys.exit(1)
            elif command == 'power-limits' and len(args) == 2:
                get_power_limits()
            elif command == 'set-power-limits' and len(args) >= 3:
                pl1 = args[2] if args[2] != "null" else None
                pl2 = args[3] if len(args) > 3 and args[3] != "null" else None
                set_power_limit(pl1, pl2)
            elif command == 'ledstatus':
                get_led_status()
            elif command == 'ledpower' and len(args) >= 6:
                # ledpower <boot> <awake> <sleep> <shutdown>
                boot = args[2].lower() in ['1', 'true', 'yes']
                awake = args[3].lower() in ['1', 'true', 'yes']
                sleep = args[4].lower() in ['1', 'true', 'yes']
                shutdown = args[5].lower() in ['1', 'true', 'yes']
                set_led_power(boot, awake, sleep, shutdown)
            elif command == 'ledmode' and len(args) >= 3:
                set_led_mode(args[2])
            elif command == 'ledbrightness':
                set_led_brightness(args[2])
            elif command == 'ledbrightnessstatus':
                get_led_brightness()
            elif command == 'fan-speeds':
                fan_speeds = get_fan_speeds()
                print(f"CPU Fan Speed: {fan_speeds['cpu_fan']}")
                print(f"GPU Fan Speed: {fan_speeds['gpu_fan']}")
            elif command == 'detect-dgpu':
                gpu_type = detect_dgpu()
                print(f"{gpu_type}")
                sys.exit(0)
            elif command == 'battery-charging-status':
                # Get direct battery charging status (independent of ASUS charge modes)
                battery_status = get_battery_charging_status()
                print(f"{battery_status}")
                sys.exit(0)
            elif command == 'terminate_all_processes':
                # Handle termination signal from QML cleanup
                if DEBUG_MODE:
                    logging.debug("Received termination signal, cleaning up...")
                cleanup_on_exit()
                print("Process cleanup completed")
                sys.exit(0)
            elif command == 'panel-overdrive' and len(args) > 2:
                # panel-overdrive <0|1>
                enable = args[2] == "1"
                if set_panel_overdrive(enable):
                    sys.exit(0)
                else:
                    sys.exit(1)
            # charge-mode command removed - charge_mode is read-only (battery status only)
            elif command == 'refresh-rate' and len(args) > 2:
                # refresh-rate <rate>
                rate = float(args[2])
                if set_refresh_rate(rate):
                    sys.exit(0)
                else:
                    sys.exit(1)
            elif command == 'get-supported-rates':
                rates = get_supported_refresh_rates()
                print(','.join(map(str, rates)))
            elif command == 'auto-refresh-panel':
                # auto-refresh-panel (no arguments)
                if auto_refresh_panel_mode():
                    sys.exit(0)
                else:
                    sys.exit(1)
            elif command == 'one-shot-charge':
                toggle_one_shot_charge()
            elif command == 'nvidia-powerd' and len(args) > 2:
                # nvidia-powerd <1|0> - 1 to enable, 0 to disable
                enable = args[2] == "1"
                if set_nvidia_powerd_service(enable):
                    sys.exit(0)
                else:
                    sys.exit(1)
            else:
                if DEBUG_MODE:
                    logging.debug(f"Unknown command or missing arguments: {command}")
                    logging.debug("Usage: helper.py [status|profile|gpu|charge|turbo|fan-speeds] [value]")
                sys.exit(1)
                
    except TimeoutError as e:
        print(f"Operation timed out: {e}", file=sys.stderr)
        cleanup_on_exit()
        sys.exit(1)
    except KeyboardInterrupt:
        if DEBUG_MODE:
            logging.debug("Script interrupted by user")
        cleanup_on_exit()
        sys.exit(0)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        if DEBUG_MODE:
            import traceback
            traceback.print_exc()
        cleanup_on_exit()
        sys.exit(1)
