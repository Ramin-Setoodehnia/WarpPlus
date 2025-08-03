#!/bin/sh

#================================================================================
# Warp+ All-in-One Installer with LuCI UI
#
# Created by: PeDitX & Gemini
# Version: 4.3 (Final UI Logic & Style Fixes)
#
# This script will:
# 1. Install the correct warp+ binary for the system architecture.
# 2. Create a rock-solid LuCI UI with robust state management.
# 3. Manage a cron job for the auto-reconnect functionality.
# 4. Create a dynamic and clean init.d service.
# 5. Configure Passwall/Passwall2 automatically.
#================================================================================

echo "Starting Warp+ All-in-One Installer v4.3..."
sleep 2

# --- 1. Detect Architecture and Download Binary ---
echo "\n[Step 1/6] Detecting system architecture and downloading Warp+..."
ARCH=$(uname -m)
case $ARCH in
    x86_64)   WARP_URL="https://github.com/bepass-org/warp-plus/releases/download/v1.2.5/warp-plus_linux-amd64.zip" ;;
    aarch64)  WARP_URL="https://github.com/bepass-org/warp-plus/releases/download/v1.2.5/warp-plus_linux-arm64.zip" ;;
    armv7l)   WARP_URL="https://github.com/bepass-org/warp-plus/releases/download/v1.2.5/warp-plus_linux-arm7.zip" ;;
    mips)     WARP_URL="https://github.com/bepass-org/warp-plus/releases/download/v1.2.5/warp-plus_linux-mips.zip" ;;
    mips64)   WARP_URL="https://github.com/bepass-org/warp-plus/releases/download/v1.2.5/warp-plus_linux-mips64.zip" ;;
    mips64le) WARP_URL="https://github.com/bepass-org/warp-plus/releases/download/v1.2.5/warp-plus_linux-mips64le.zip" ;;
    riscv64)  WARP_URL="https://github.com/bepass-org/warp-plus/releases/download/v1.2.5/warp-plus_linux-riscv64.zip" ;;
    *)
        echo "Error: System architecture not supported."
        exit 1
        ;;
esac

cd /tmp || exit
if ! wget -O warp.zip "$WARP_URL"; then
    echo "Error: Failed to download the Warp+ binary."
    exit 1
fi

if ! unzip -o warp.zip; then
    echo "Error: Failed to extract the zip file."
    exit 1
fi
echo "Download and extraction successful."

# --- 2. Install Binary ---
echo "\n[Step 2/6] Installing the Warp+ binary..."
mv -f warp-plus warp
cp -f warp /usr/bin/
chmod +x /usr/bin/warp
echo "Binary installed to /usr/bin/warp."

# --- 3. Create UCI Config and LuCI UI Files ---
echo "\n[Step 3/6] Creating LuCI interface and configuration files..."

# Create UCI config file to store settings
if [ ! -f /etc/config/wrpplus ]; then
    uci -q batch <<-EOF
        set wrpplus.settings=wrpplus
        set wrpplus.settings.mode='scan'
        set wrpplus.settings.country='US'
        set wrpplus.settings.reconnect_enabled='0'
        set wrpplus.settings.reconnect_interval='120'
        commit wrpplus
EOF
fi

# Create LuCI Controller (Backend Logic)
mkdir -p /usr/lib/lua/luci/controller
cat > /usr/lib/lua/luci/controller/wrpplus.lua <<'EoL'
module("luci.controller.wrpplus", package.seeall)

function index()
    entry({"admin", "peditxos"}, nil, "PeDitXOS Tools", 55).dependent = false
    entry({"admin", "peditxos", "wrpplus"}, template("wrpplus/main"), "Warp+", 1).dependent = true
    entry({"admin", "peditxos", "wrpplus_api"}, call("api_handler")).leaf = true
end

function api_handler()
    local action = luci.http.formvalue("action")
    local uci = luci.model.uci.cursor()
    local DEBUG_LOG_FILE = "/tmp/wrpplus_debug.log"

    local function log(msg)
        luci.sys.call("echo \"[$(date '+%Y-%m-%d %H:%M:%S')] " .. msg .. "\" >> " .. DEBUG_LOG_FILE)
    end

    if action == "status" then
        local running = (os.execute("pgrep -f '/usr/bin/warp' >/dev/null 2>&1") == 0)
        local ip = "N/A"
        if running then
            local ip_handle = io.popen("curl --socks5 127.0.0.1:8086 -m 7 -s http://ifconfig.me/ip")
            if ip_handle then ip = ip_handle:read("*a"):gsub("\n", ""); ip_handle:close() end
        end
        local mode = uci:get("wrpplus", "settings", "mode") or "scan"
        local country = uci:get("wrpplus", "settings", "country") or "US"
        local reconnect_enabled = uci:get("wrpplus", "settings", "reconnect_enabled") or "0"
        local reconnect_interval = uci:get("wrpplus", "settings", "reconnect_interval") or "120"
        luci.http.prepare_content("application/json")
        luci.http.write_json({
            running = running, ip = ip, mode = mode, country = country,
            reconnect_enabled = reconnect_enabled, reconnect_interval = reconnect_interval
        })

    elseif action == "toggle" then
        if (os.execute("pgrep -f '/usr/bin/warp' >/dev/null 2>&1") == 0) then
            log("Request to STOP service.")
            os.execute("/etc/init.d/warp stop >> " .. DEBUG_LOG_FILE .. " 2>&1 &")
        else
            log("Request to START service.")
            os.execute("/etc/init.d/warp start >> " .. DEBUG_LOG_FILE .. " 2>&1 &")
        end
        luci.http.prepare_content("application/json")
        luci.http.write_json({success=true})

    elseif action == "save_settings" then
        local mode = luci.http.formvalue("mode")
        local country = luci.http.formvalue("country")
        log("Request to SAVE settings. Mode: " .. mode .. ", Country: " .. country)

        uci:set("wrpplus", "settings", "mode", mode)
        uci:set("wrpplus", "settings", "country", country)
        uci:commit("wrpplus")
        log("UCI settings saved.")

        local args = "-b 127.0.0.1:8086"
        if mode == "gool" then args = args .. " --gool"
        elseif mode == "cfon" then args = args .. " --cfon --country " .. country
        else args = args .. " --scan" end

        log("Generating new init.d script with args: " .. args)
        -- Using Lua's multi-line string to avoid literal \n characters
        local init_script_content = [[
#!/bin/sh /etc/rc.common
START=91
USE_PROCD=1
PROG=/usr/bin/warp
start_service() {
    local args="]] .. args .. [["
    procd_open_instance
    procd_set_param command $PROG $args
    procd_set_param respawn
    procd_close_instance
}
]]
        local file = io.open("/etc/init.d/warp", "w")
        if file then
            file:write(init_script_content)
            file:close()
        end
        
        luci.sys.call("chmod 755 /etc/init.d/warp")
        log("Restarting warp service to apply changes.")
        luci.sys.call("/etc/init.d/warp restart >> " .. DEBUG_LOG_FILE .. " 2>&1")
        luci.http.prepare_content("application/json")
        luci.http.write_json({success=true})

    elseif action == "save_reconnect" then
        local enabled = luci.http.formvalue("enabled")
        local interval = luci.http.formvalue("interval")
        log("Request to SAVE reconnect settings. Enabled: " .. enabled .. ", Interval: " .. interval .. " mins")

        uci:set("wrpplus", "settings", "reconnect_enabled", enabled)
        uci:set("wrpplus", "settings", "reconnect_interval", interval)
        uci:commit("wrpplus")

        local CRON_CMD = "/etc/init.d/warp restart"
        local CRON_TAG = "#Warp+AutoReconnect"
        luci.sys.call("sed -i '/" .. CRON_TAG .. "/d' /etc/crontabs/root")
        if enabled == "1" then
            log("Enabling cron job.")
            luci.sys.call("echo '*/" .. interval .. " * * * * " .. CRON_CMD .. " " .. CRON_TAG .. "' >> /etc/crontabs/root")
        else
            log("Disabling cron job.")
        end
        luci.sys.call("/etc/init.d/cron restart")
        luci.http.prepare_content("application/json")
        luci.http.write_json({success=true})

    elseif action == "get_debug_log" then
        local content = ""
        local f = io.open(DEBUG_LOG_FILE, "r")
        if f then content = f:read("*a"); f:close() end
        luci.http.prepare_content("application/json")
        luci.http.write_json({ log = content })
    end
end
EoL

# Create LuCI View (Frontend UI)
mkdir -p /usr/lib/lua/luci/view/wrpplus
cat > /usr/lib/lua/luci/view/wrpplus/main.htm <<'EoL'
<%+header%>
<style>
    .peditx-container{ max-width: 650px; margin: 40px auto; padding: 24px; background-color: rgba(30, 30, 30, 0.9); backdrop-filter: blur(10px); border: 1px solid rgba(255, 255, 255, 0.2); box-shadow: 0 8px 32px 0 rgba(0, 0, 0, 0.1); border-radius: 12px; font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Oxygen,Ubuntu,Cantarell,"Fira Sans","Droid Sans","Helvetica Neue",sans-serif; color: #f0f0f0; }
    h2, h3 { text-align: center; color: #fff; margin-bottom: 24px; }
    .peditx-row{ display: flex; justify-content: space-between; align-items: center; padding: 12px 0; border-bottom: 1px solid rgba(255, 255, 255, 0.1); }
    .peditx-row:last-child{ border-bottom: none; }
    .peditx-label{ font-weight: 600; color: #ccc; }
    .peditx-value{ font-weight: 700; color: #fff; }
    .peditx-status-indicator{ display: inline-block; width: 12px; height: 12px; border-radius: 50%; margin-right: 8px; transition: background-color 0.5s ease; }
    .status-connected{ background-color: #28a745; }
    .status-disconnected{ background-color: #dc3545; }
    .peditx-btn{ padding: 10px 24px; font-size: 16px; font-weight: 600; border: none; border-radius: 8px; cursor: pointer; transition: all 0.2s ease; }
    .peditx-btn:hover:not(:disabled){ transform: translateY(-2px); }
    .peditx-btn:disabled{ background-color: #555 !important; cursor: not-allowed; animation: none !important; color: #aaa !important; }
    .settings-section{ margin-top: 24px; padding-top: 16px; border-top: 1px solid rgba(255, 255, 255, 0.1); }
    .controls-group { display: flex; gap: 10px; margin-top: 10px; justify-content: center; align-items: center; flex-wrap: wrap; }
    .mode-btn { background-color: rgba(255, 255, 255, 0.1); border: 1px solid rgba(255, 255, 255, 0.2); color: #fff; }
    .mode-btn.selected-mode { background-color: #9b59b6; border-color: #9b59b6; color: #fff; transform: scale(1.05); }
    .btn-save-changes { background-color: #007bff; }
    .btn-save-changes.dirty { background-color: #ffc107; color: #000; animation: pulse 1.5s infinite; }
    @keyframes pulse { 0% { box-shadow: 0 0 0 0 rgba(255, 193, 7, 0.7); } 70% { box-shadow: 0 0 0 10px rgba(255, 193, 7, 0); } 100% { box-shadow: 0 0 0 0 rgba(255, 193, 7, 0); } }
    #country-select, #reconnectInterval { padding: 8px; border-radius: 8px; background-color: rgba(255, 255, 255, 0.1); color: #fff; border: 1px solid rgba(255, 255, 255, 0.2); font-weight: 600; font-size: 14px; }
    #country-select option { background-color: #333; color: #fff; } /* Fix for dropdown style */
    .debug-log-container { margin-top: 30px; padding: 15px; background-color: rgba(0, 0, 0, 0.3); border-radius: 8px; }
    #log-output { background-color: #000; color: #00ff00; padding: 10px; border-radius: 4px; font-family: monospace; font-size: 12px; white-space: pre-wrap; max-height: 250px; overflow-y: auto; border: 1px solid #333; }
</style>

<div class="peditx-container">
    <h2>Warp+ Manager</h2>
    <div class="peditx-row"><span class="peditx-label">Service Status:</span><span class="peditx-value"><span id="statusIndicator" class="peditx-status-indicator"></span><span id="statusText">...</span></span></div>
    <div class="peditx-row"><span class="peditx-label">Outgoing IP:</span><span id="ipText" class="peditx-value">...</span></div>
    <div class="peditx-row" style="justify-content: center; padding-top: 20px;"><button id="connectBtn" class="peditx-btn">Connect</button><button id="disconnectBtn" class="peditx-btn" style="display:none;">Disconnect</button></div>
    
    <div class="settings-section">
        <h3>Service Settings</h3>
        <div class="peditx-row"><span class="peditx-label">Configured Mode:</span><span id="activeModeText" class="peditx-value">...</span></div>
        <div class="controls-group" id="mode-btn-group"><button class="peditx-btn mode-btn" data-mode="scan">Scan</button><button class="peditx-btn mode-btn" data-mode="gool">Gool</button><button class="peditx-btn mode-btn" data-mode="cfon">Psiphon</button></div>
        <div id="country-selector" class="controls-group" style="display: none; margin-top: 15px;"><label for="country-select" class="peditx-label">Psiphon Country:&nbsp;</label><select id="country-select"><option value="AT">🇦🇹 Austria</option><option value="AU">🇦🇺 Australia</option><option value="BE">🇧🇪 Belgium</option><option value="CA">🇨🇦 Canada</option><option value="DE">🇩🇪 Germany</option><option value="FR">🇫🇷 France</option><option value="GB">🇬🇧 UK</option><option value="IN">🇮🇳 India</option><option value="JP">🇯🇵 Japan</option><option value="NL">🇳🇱 Netherlands</option><option value="US" selected>🇺🇸 USA</option></select></div>
        <div class="peditx-row" style="justify-content: center; padding-top: 20px;"><button id="applyBtn" class="peditx-btn btn-save-changes">Save & Apply Settings</button></div>
    </div>

    <div class="settings-section">
        <h3>Auto-Reconnect</h3>
        <div class="peditx-row"><span class="peditx-label">Status:</span><span id="reconnectStatus" class="peditx-value">Disabled</span></div>
        <div class="controls-group">
            <input type="checkbox" id="reconnectEnabled" style="transform: scale(1.5);">
            <label for="reconnectEnabled">Enable</label>
            <input type="number" id="reconnectInterval" min="1" value="120" style="width: 80px;">
            <label for="reconnectInterval">Minutes</label>
        </div>
        <div class="peditx-row" style="justify-content: center; padding-top: 20px;"><button id="reconnectSaveBtn" class="peditx-btn" style="background-color: #5bc0de;">Save Reconnect Settings</button></div>
    </div>

    <div class="debug-log-container"><h3>Debug Log</h3><pre id="log-output">Waiting for actions...</pre></div>
</div>

<script type="text/javascript">
document.addEventListener('DOMContentLoaded', function() {
    const E = id => document.getElementById(id);
    const elements = {
        indicator: E('statusIndicator'), text: E('statusText'), ip: E('ipText'),
        connect: E('connectBtn'), disconnect: E('disconnectBtn'), activeMode: E('activeModeText'),
        apply: E('applyBtn'), countryContainer: E('country-selector'), countrySelect: E('country-select'),
        reconStatus: E('reconnectStatus'), reconEnabled: E('reconnectEnabled'),
        reconInterval: E('reconnectInterval'), reconSave: E('reconnectSaveBtn'),
        log: E('log-output'), modeButtons: document.querySelectorAll('.mode-btn'),
        allControls: document.querySelectorAll('.peditx-btn, #country-select, #reconnectEnabled, #reconnectInterval')
    };

    let serverState = {}; // Authoritative state from backend
    let uiState = {};     // User's selections on the screen
    let isBusy = false;

    const callAPI = (params, callback) => XHR.get('<%=luci.dispatcher.build_url("admin/peditxos/wrpplus_api")%>' + params, null, (x, data) => data && callback(data));

    function setBusy(busy, message = '') {
        isBusy = busy;
        elements.allControls.forEach(el => { el.disabled = busy; });
        if (busy && message) { elements.text.innerText = message; }
    }

    function render() {
        if (isBusy) return;

        // Connection Status (always from server)
        elements.indicator.className = 'peditx-status-indicator ' + (serverState.running ? 'status-connected' : 'status-disconnected');
        elements.text.innerText = serverState.running ? 'Connected' : 'Disconnected';
        elements.ip.innerText = serverState.running ? (serverState.ip || 'Fetching...') : 'N/A';
        elements.connect.style.display = serverState.running ? 'none' : 'inline-block';
        elements.disconnect.style.display = serverState.running ? 'inline-block' : 'none';

        // Service Settings (use UI state to show user's choice)
        elements.activeMode.innerText = {scan: 'Scan', gool: 'Gool', cfon: 'Psiphon'}[serverState.mode] || 'N/A';
        elements.modeButtons.forEach(btn => btn.classList.toggle('selected-mode', btn.dataset.mode === uiState.mode));
        elements.countryContainer.style.display = (uiState.mode === 'cfon') ? 'flex' : 'none';
        elements.countrySelect.value = uiState.country;
        
        // Reconnect Settings (use UI state)
        const reconEnabled = uiState.reconnect_enabled === '1';
        elements.reconStatus.innerText = serverState.reconnect_enabled === '1' ? `Enabled (Every ${serverState.reconnect_interval} mins)` : 'Disabled';
        elements.reconEnabled.checked = reconEnabled;
        elements.reconInterval.value = uiState.reconnect_interval;
        
        // Check for unsaved changes
        const serviceDirty = uiState.mode !== serverState.mode || (uiState.mode === 'cfon' && uiState.country !== serverState.country);
        elements.apply.classList.toggle('dirty', serviceDirty);
        const reconnectDirty = uiState.reconnect_enabled !== serverState.reconnect_enabled || uiState.reconnect_interval !== serverState.reconnect_interval;
        elements.reconSave.classList.toggle('dirty', reconnectDirty);
    }

    function fetchStatus() {
        if (document.hidden || isBusy) return;
        callAPI('?action=status', data => {
            serverState = data;
            // Sync UI state with server state ONLY if there are no unsaved changes
            if (!elements.apply.classList.contains('dirty')) {
                uiState.mode = serverState.mode;
                uiState.country = serverState.country;
            }
            if (!elements.reconSave.classList.contains('dirty')) {
                uiState.reconnect_enabled = serverState.reconnect_enabled;
                uiState.reconnect_interval = serverState.reconnect_interval;
            }
            render();
        });
    }

    function fetchLog() {
        if (document.hidden || isBusy) return;
        callAPI('?action=get_debug_log', data => {
            if (data && data.log && elements.log.textContent !== data.log) {
                elements.log.textContent = data.log;
                elements.log.scrollTop = elements.log.scrollHeight;
            }
        });
    }

    elements.modeButtons.forEach(btn => btn.addEventListener('click', function() {
        uiState.mode = this.dataset.mode;
        render();
    }));
    elements.countrySelect.addEventListener('change', () => { uiState.country = elements.countrySelect.value; render(); });
    elements.reconEnabled.addEventListener('change', () => { uiState.reconnect_enabled = elements.reconEnabled.checked ? '1' : '0'; render(); });
    elements.reconInterval.addEventListener('input', () => { uiState.reconnect_interval = elements.reconInterval.value; render(); });

    elements.connect.addEventListener('click', () => { setBusy(true, 'Connecting...'); callAPI('?action=toggle', () => setTimeout(() => { setBusy(false); fetchStatus(); }, 5000)); });
    elements.disconnect.addEventListener('click', () => { setBusy(true, 'Disconnecting...'); callAPI('?action=toggle', () => setTimeout(() => { setBusy(false); fetchStatus(); }, 4000)); });
    
    elements.apply.addEventListener('click', () => {
        if (!elements.apply.classList.contains('dirty')) return;
        setBusy(true, 'Applying Settings...');
        const params = `?action=save_settings&mode=${uiState.mode}&country=${uiState.country}`;
        callAPI(params, () => {
            alert('Service settings applied. The service is restarting...');
            setTimeout(() => { setBusy(false); fetchStatus(); }, 6000);
        });
    });

    elements.reconSave.addEventListener('click', () => {
        if (!elements.reconSave.classList.contains('dirty')) return;
        setBusy(true, 'Saving Reconnect...');
        const params = `?action=save_reconnect&enabled=${uiState.reconnect_enabled}&interval=${uiState.reconnect_interval}`;
        callAPI(params, () => {
            alert('Reconnect settings saved.');
            setTimeout(() => { setBusy(false); fetchStatus(); }, 2000);
        });
    });

    // Initial load and periodic polling
    fetchStatus();
    fetchLog();
    setInterval(fetchStatus, 5000);
    setInterval(fetchLog, 3000);
});
</script>
<%+footer%>
EoL
echo "LuCI UI files created successfully."

# --- 4. Create and Enable Service ---
echo "\n[Step 4/6] Creating and enabling the Warp+ service..."

# Create the initial init.d script and clear debug log
echo "" > /tmp/wrpplus_debug.log
cat << 'EOF' > /etc/init.d/warp
#!/bin/sh /etc/rc.common
START=91
USE_PROCD=1
PROG=/usr/bin/warp
start_service() {
    local args="-b 127.0.0.1:8086 --scan"
    procd_open_instance
    procd_set_param command $PROG $args
    procd_set_param respawn
    procd_close_instance
}
EOF

chmod 755 /etc/init.d/warp
service warp enable
service warp start
echo "Warp+ service has been enabled and started."

# --- 5. Configure Passwall ---
echo "\n[Step 5/6] Configuring Passwall/Passwall2..."
if uci show passwall2 >/dev/null 2>&1; then
    uci set passwall2.WarpPlus=nodes; uci set passwall2.WarpPlus.remarks='Warp+'; uci set passwall2.WarpPlus.type='Xray'; uci set passwall2.WarpPlus.protocol='socks'; uci set passwall2.WarpPlus.server='127.0.0.1'; uci set passwall2.WarpPlus.port='8086'; uci commit passwall2
    echo "Passwall2 configured successfully."
elif uci show passwall >/dev/null 2>&1; then
    uci set passwall.WarpPlus=nodes; uci set passwall.WarpPlus.remarks='Warp+'; uci set passwall.WarpPlus.type='Xray'; uci set passwall.WarpPlus.protocol='socks'; uci set passwall.WarpPlus.server='127.0.0.1'; uci set passwall.WarpPlus.port='8086'; uci commit passwall
    echo "Passwall configured successfully."
else
    echo "Neither Passwall nor Passwall2 found. Skipping configuration."
fi

# --- 6. Finalize and Clean Up ---
echo "\n[Step 6/6] Finalizing installation..."
rm -f /tmp/luci-indexcache
/etc/init.d/uhttpd restart
rm -f /tmp/warp.zip /tmp/warp /tmp/README.md /tmp/LICENSE

echo "\n================================================"
echo "      Installation Completed Successfully! "
echo "================================================"
echo "\nPlease refresh your router's web page."
echo "You can find the new manager under: PeDitXOS Tools -> Warp+"
echo "\nMade By: PeDitX & Gemini\n"

