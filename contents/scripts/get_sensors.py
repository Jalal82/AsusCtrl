#!/usr/bin/env python3
import subprocess
import os
import re
import sys




def get_fan_speeds():
    """
    Reads fan speeds from /sys/class/hwmon/hwmon*/fan*_input.
    Attempts to differentiate between CPU and GPU fans.
    Returns a dictionary with 'cpu_fan' and 'gpu_fan' speeds in RPM or "N/A".
    """
    cpu_fan_speed = "N/A"
    gpu_fan_speed = "N/A"

    for hwmon_dir_name in os.listdir('/sys/class/hwmon/'):
        hwmon_path = os.path.join('/sys/class/hwmon/', hwmon_dir_name)
        if os.path.isdir(hwmon_path):
            # Try to identify the sensor type (e.g., k10temp for AMD CPU, nouveau for NVIDIA GPU)
            name_path = os.path.join(hwmon_path, 'name')
            chip_name = ""
            if os.path.exists(name_path):
                try:
                    with open(name_path, 'r') as f:
                        chip_name = f.read().strip().lower()
                except Exception:
                    pass

            for i in range(1, 5): # Check up to 4 fans per hwmon
                fan_input_path = os.path.join(hwmon_path, f"fan{i}_input")
                if os.path.exists(fan_input_path):
                    try:
                        with open(fan_input_path, 'r') as f:
                            speed = int(f.read().strip())
                            # Simple heuristic to assign fan to CPU or GPU
                            if "k10temp" in chip_name or "cpu" in chip_name or "coretemp" in chip_name:
                                cpu_fan_speed = f"{speed} RPM"
                            elif "nouveau" in chip_name or "amdgpu" in chip_name or "gpu" in chip_name:
                                gpu_fan_speed = f"{speed} RPM"
                            elif cpu_fan_speed == "N/A": # Assign to CPU if not specifically identified
                                cpu_fan_speed = f"{speed} RPM"
                            elif gpu_fan_speed == "N/A": # Assign to GPU if not specifically identified
                                gpu_fan_speed = f"{speed} RPM"
                    except Exception:
                        pass
    return {"cpu_fan": cpu_fan_speed, "gpu_fan": gpu_fan_speed}

def get_cpu_temperature():
    """
    Reads CPU temperature from /sys/class/hwmon/hwmon*/temp*_input.
    Returns CPU temperature in Celsius or "N/A".
    """
    cpu_temp = "N/A"
    
    try:
        for hwmon_dir_name in os.listdir('/sys/class/hwmon/'):
            hwmon_path = os.path.join('/sys/class/hwmon/', hwmon_dir_name)
            if os.path.isdir(hwmon_path):
                # Try to identify the sensor type
                name_path = os.path.join(hwmon_path, 'name')
                chip_name = ""
                if os.path.exists(name_path):
                    try:
                        with open(name_path, 'r') as f:
                            chip_name = f.read().strip().lower()
                    except Exception:
                        pass
                
                # Look for CPU temperature sensors
                # Common CPU temp sensors: k10temp (AMD), coretemp (Intel)
                if "k10temp" in chip_name or "coretemp" in chip_name or "cpu" in chip_name:
                    # Check for temperature inputs
                    for i in range(1, 5):  # Check temp1_input to temp4_input
                        temp_input_path = os.path.join(hwmon_path, f"temp{i}_input")
                        if os.path.exists(temp_input_path):
                            try:
                                with open(temp_input_path, 'r') as f:
                                    temp_millicelsius = int(f.read().strip())
                                    temp_celsius = temp_millicelsius / 1000
                                    cpu_temp = f"{temp_celsius:.1f}°C"
                                    return cpu_temp  # Return the first valid temp reading
                            except Exception:
                                pass
                
                # Fallback: if no specific CPU sensor found, use the first temperature reading
                if cpu_temp == "N/A":
                    temp_input_path = os.path.join(hwmon_path, "temp1_input")
                    if os.path.exists(temp_input_path):
                        try:
                            with open(temp_input_path, 'r') as f:
                                temp_millicelsius = int(f.read().strip())
                                temp_celsius = temp_millicelsius / 1000
                                cpu_temp = f"{temp_celsius:.1f}°C"
                        except Exception:
                            pass
    except Exception:
        pass
    
    return cpu_temp

if __name__ == '__main__':
    fan_speeds = get_fan_speeds()
    cpu_temp = get_cpu_temperature()

    print(f"CPU Fan Speed: {fan_speeds['cpu_fan']}")
    print(f"GPU Fan Speed: {fan_speeds['gpu_fan']}")
    print(f"CPU Temperature: {cpu_temp}")