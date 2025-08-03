#!/bin/sh

#================================================================================
# Warp+ All-in-One Uninstaller
#
# Created by: PeDitX
# Version: 1.0
#
# This script will completely remove all files and configurations
# related to the Warp+ All-in-One Installer.
#================================================================================

echo "Starting Warp+ Uninstaller..."
sleep 2

# --- 1. Stop and Disable Service ---
echo -e "\n[Step 1/7] Stopping and disabling the Warp+ service..."
if [ -f /etc/init.d/warp ]; then
    /etc/init.d/warp stop
    /etc/init.d/warp disable
    echo "Service stopped and disabled."
else
    echo "Service not found, skipping."
fi

# --- 2. Remove Files ---
echo -e "\n[Step 2/7] Removing files..."
rm -f /etc/init.d/warp
rm -f /usr/bin/warp
rm -f /etc/config/wrpplus
rm -f /usr/lib/lua/luci/controller/wrpplus.lua
rm -rf /usr/lib/lua/luci/view/wrpplus
rm -f /tmp/wrpplus_debug.log
echo "All related files have been removed."

# --- 3. Remove Cron Job ---
echo -e "\n[Step 3/7] Removing auto-reconnect cron job..."
sed -i '/#Warp+AutoReconnect/d' /etc/crontabs/root
/etc/init.d/cron restart
echo "Cron job removed."

# --- 4. Remove Passwall/Passwall2 Node ---
echo -e "\n[Step 4/7] Removing Passwall/Passwall2 node..."
if uci show passwall2.WarpPlus >/dev/null 2>&1; then
    uci delete passwall2.WarpPlus
    uci commit passwall2
    echo "Passwall2 node removed."
elif uci show passwall.WarpPlus >/dev/null 2>&1; then
    uci delete passwall.WarpPlus
    uci commit passwall
    echo "Passwall node removed."
else
    echo "Passwall/Passwall2 node not found, skipping."
fi

# --- 5. Clean LuCI Cache ---
echo -e "\n[Step 5/7] Cleaning LuCI cache..."
rm -f /tmp/luci-indexcache
echo "Cache cleaned."

# --- 6. Restart Web Server ---
echo -e "\n[Step 6/7] Restarting web server..."
/etc/init.d/uhttpd restart
echo "Web server restarted."

# --- 7. Finalization ---
echo -e "\n[Step 7/7] Uninstallation complete."
echo -e "\n================================================"
echo "      Warp+ has been successfully uninstalled. "
echo -e "================================================"
echo -e "\nPlease refresh your router's web page to see the changes."
echo -e "\nMade By: PeDitX\n"

