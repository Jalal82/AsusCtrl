import dbus
import sys

class AsusKeyboardLighting:
    def __init__(self):
        self.bus = dbus.SystemBus()
        self.service_name = "xyz.ljones.Asusd"
        self.aura_path = "/xyz/ljones/aura/tuf"
        
        try:
            self.aura_obj = self.bus.get_object(self.service_name, self.aura_path)
            self.aura_interface = dbus.Interface(self.aura_obj, "xyz.ljones.Aura")
            self.props_interface = dbus.Interface(self.aura_obj, "org.freedesktop.DBus.Properties")
        except Exception as e:
            #print(f"❌ Failed to connect to ASUS lighting service: {e}")
            sys.exit(1)
    
    def get_current_status(self):
        """Get current lighting status"""
        try:
            brightness = self.props_interface.Get("xyz.ljones.Aura", "Brightness")
            led_mode = self.props_interface.Get("xyz.ljones.Aura", "LedMode")
            led_power = self.props_interface.Get("xyz.ljones.Aura", "LedPower")
            led_mode_data = self.props_interface.Get("xyz.ljones.Aura", "LedModeData")
            supported_brightness = self.props_interface.Get("xyz.ljones.Aura", "SupportedBrightness")
            supported_modes = self.props_interface.Get("xyz.ljones.Aura", "SupportedBasicModes")
            
            # #print("🔍 Current Keyboard Lighting Status:")
            # #print(f"  💡 Brightness: {brightness} (Available: {list(supported_brightness)})")
            # #print(f"  🎨 LED Mode: {led_mode} (Available: {list(supported_modes)})")
            # #print(f"  ⚡ LED Power: {led_power}")
            # #print(f"  🎯 LED Mode Data: {led_mode_data}")
            
            # #print(list(led_power[0][0][1:]))
            
            return {
                'brightness': brightness,
                'led_mode':  led_mode,
                'led_power': list(led_power[0][0][1:]),
                'led_mode_data': led_mode_data,
                'supported_brightness': list(supported_brightness),
                'supported_modes': list(supported_modes)
            }
        except Exception as e:
            #print(f"❌ Error getting status: {e}")
            return None
    
    def set_brightness(self, brightness_level):
        """Set keyboard brightness (0-3 based on your supported levels)"""
        try:
            supported = self.props_interface.Get("xyz.ljones.Aura", "SupportedBrightness")
            if brightness_level not in supported:
                #print(f"❌ Invalid brightness level {brightness_level}. Supported: {list(supported)}")
                return False
            
            self.props_interface.Set("xyz.ljones.Aura", "Brightness", dbus.UInt32(brightness_level))
            # #print(f"✅ Brightness set to {brightness_level}")
            return True
        except Exception as e:
            # #print(f"❌ Error setting brightness: {e}")
            return False
    
    def set_led_mode(self, mode):
        """Set LED mode (0, 1, 10 based on your supported modes)"""
        try:
            supported = self.props_interface.Get("xyz.ljones.Aura", "SupportedBasicModes")
            if mode not in supported:
                # #print(f"❌ Invalid mode {mode}. Supported: {list(supported)}")
                return False
            
            self.props_interface.Set("xyz.ljones.Aura", "LedMode", dbus.UInt32(mode))
            # #print(f"✅ LED mode set to {mode}")
            return True
        except Exception as e:
            # #print(f"❌ Error setting LED mode: {e}")
            return False
    
    def set_led_power(self, zone_id=1, boot=True, awake=True, sleep=True, shutdown=True):
        """
        Set LED power states for different system states
        zone_id: 1 (based on your SupportedPowerZones)
        boot, awake, sleep, shutdown: True/False for each state
        """
        try:
            # Create the power structure based on your current format
            power_struct = dbus.Struct((
                dbus.Array([
                    dbus.Struct((
                        dbus.UInt32(zone_id),
                        dbus.Boolean(boot),
                        dbus.Boolean(awake), 
                        dbus.Boolean(sleep),
                        dbus.Boolean(shutdown)
                    ), signature=None)
                ], signature=dbus.Signature('(ubbbb)')),
            ), signature=None)
            
            self.props_interface.Set("xyz.ljones.Aura", "LedPower", power_struct)
            #print(f"✅ LED power set - Boot:{boot}, Awake:{awake}, Sleep:{sleep}, Shutdown:{shutdown}")
            return True
        except Exception as e:
            #print(f"❌ Error setting LED power: {e}")
            return False
    
    def set_color(self, red, green, blue, mode=0):
        """
        Set LED color (RGB values 0-255)
        mode: LED mode to use (0, 1, or 10)
        """
        try:
            # Based on your current LedModeData structure
            mode_data = dbus.Struct((
                dbus.UInt32(mode),  # LED mode
                dbus.UInt32(0),     # Speed/direction (you can experiment with this)
                dbus.Struct((dbus.Byte(red), dbus.Byte(green), dbus.Byte(blue)), signature=None),  # Primary color
                dbus.Struct((dbus.Byte(0), dbus.Byte(0), dbus.Byte(0)), signature=None),  # Secondary color
                dbus.UInt32(235),   # Unknown parameter (keeping your current value)
                dbus.UInt32(0)      # Unknown parameter (keeping your current value)
            ), signature=None)
            
            self.props_interface.Set("xyz.ljones.Aura", "LedModeData", mode_data)
            self.props_interface.Set("xyz.ljones.Aura", "LedMode", dbus.UInt32(mode))
            #print(f"✅ Color set to RGB({red}, {green}, {blue}) with mode {mode}")
            return True
        except Exception as e:
            #print(f"❌ Error setting color: {e}")
            return False
    
    def turn_off_for_sleep(self):
        """Turn off keyboard lighting during sleep"""
        return self.set_led_power(zone_id=1, boot=True, awake=True, sleep=False, shutdown=True)
    
    def turn_on_for_sleep(self):
        """Keep keyboard lighting on during sleep"""
        return self.set_led_power(zone_id=1, boot=True, awake=True, sleep=True, shutdown=True)
    
    def set_sleep_mode_with_dim_light(self):
        """Set a dim light for sleep mode"""
        # First set brightness to lowest
        self.set_brightness(0)
        # Keep it on during sleep
        self.turn_on_for_sleep()
        # Set a dim color (dark blue for sleep)
        self.set_color(0, 0, 50, mode=0)  # Dim blue
        #print("✅ Sleep mode configured: Dim blue light")

def main():
    if len(sys.argv) < 2:
        #print("🎮 ASUS TUF Keyboard Lighting Control")
        #print("\nUsage:")
        #print("  python asus_keyboard_lighting_control.py <command> [options]")
        #print("\nCommands:")
        #print("  status                           - Show current lighting status")
        #print("  brightness <0-3>                 - Set brightness level")
        #print("  mode <0|1|10>                    - Set LED mode")
        #print("  color <red> <green> <blue>       - Set RGB color (0-255)")
        #print("  sleep-off                        - Turn off lighting during sleep")
        #print("  sleep-on                         - Keep lighting on during sleep")
        #print("  sleep-dim                        - Set dim lighting for sleep")
        #print("  power <boot> <awake> <sleep> <shutdown> - Set power states (true/false)")
        return
    
    controller = AsusKeyboardLighting()
    command = sys.argv[1].lower()
    
    if command == "status":
        controller.get_current_status()
    
    elif command == "brightness":
        if len(sys.argv) != 3:
            #print("❌ Usage: brightness <0-3>")
            return
        try:
            level = int(sys.argv[2])
            controller.set_brightness(level)
        except ValueError:
            print("❌ Brightness must be a number")
            
    
    elif command == "mode":
        if len(sys.argv) != 3:
            #print("❌ Usage: mode <0|1|10>")
            return
        try:
            mode = int(sys.argv[2])
            controller.set_led_mode(mode)
        except ValueError:
            print("❌ Mode must be a number")
           
    
    elif command == "color":
        if len(sys.argv) != 5:
            #print("❌ Usage: color <red> <green> <blue>")
            return
        try:
            r, g, b = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
            controller.set_color(r, g, b)
        except ValueError:
            print("❌ RGB values must be numbers (0-255)")
    
    elif command == "sleep-off":
        controller.turn_off_for_sleep()
    
    elif command == "sleep-on":
        controller.turn_on_for_sleep()
    
    elif command == "sleep-dim":
        controller.set_sleep_mode_with_dim_light()
    
    elif command == "power":
        if len(sys.argv) != 6:
            #print("❌ Usage: power <boot> <awake> <sleep> <shutdown>")
            #print("   Example: power true true false true")
            return
        try:
            boot = sys.argv[2].lower() == 'true'
            awake = sys.argv[3].lower() == 'true'
            sleep = sys.argv[4].lower() == 'true'
            shutdown = sys.argv[5].lower() == 'true'
            controller.set_led_power(boot=boot, awake=awake, sleep=sleep, shutdown=shutdown)
        except Exception as e:
            print(f"❌ Error: {e}")
    
    else:
        print(f"❌ Unknown command: {command}")

if __name__ == "__main__":
    main()