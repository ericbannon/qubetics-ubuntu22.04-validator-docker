#!/bin/bash

# Step 1: Install Required Packages
sudo apt update && sudo apt upgrade -y
sudo apt install -y device-tree-compiler

# Step 2: Create Fan Overlay for GPIO 18
cat << 'EOF' > rpi5-fan-overlay.dts
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2712";

    fragment@0 {
        target-path = "/";
        __overlay__ {
            rpi_fan: rpi_fan {
                compatible = "gpio-fan";
                gpios = <&gpio 18 0>;
                gpio-fan,speed-map = <0 0 55000 1 65000 2 75000 3>;
                #cooling-cells = <2>;
            };
        };
    };

    fragment@1 {
        target = <&thermal>;
        __overlay__ {
            cooling-maps {
                map0 {
                    trip = <&cpu_thermal>;
                    cooling-device = <&rpi_fan 0 3>;
                };
            };
        };
    };
};
EOF

# Step 3: Compile the Overlay
dtc -@ -I dts -O dtb -o rpi5-fan.dtbo rpi5-fan-overlay.dts

# Step 4: Install the Overlay
sudo cp rpi5-fan.dtbo /boot/firmware/overlays/
sudo bash -c 'echo "dtoverlay=rpi5-fan" >> /boot/firmware/config.txt'

# Step 5: Reboot (optional - uncomment if you want it automatic)
# sudo reboot
echo "✅ Fan overlay installed. Please reboot to apply changes."
