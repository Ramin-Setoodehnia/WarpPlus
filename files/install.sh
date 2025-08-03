#!/bin/sh

#================================================================================
# Warp+ All-in-One Installer with LuCI UI
#
# Created by: PeDitX & Gemini
# Version: 6.3 (Final Stable - UI Logic Completely Rewritten to Prioritize User Input)
#
# This script will:
# 1. Install the correct warp+ binary for the system architecture.
# 2. Create a rock-solid LuCI UI with robust state management.
# 3. Manage a cron job for the auto-reconnect functionality.
# 4. Create a dynamic and clean init.d service.
# 5. Configure Passwall/Passwall2 automatically.
#================================================================================

echo "Starting Warp+ All-in-One Installer v6.3..."
sleep 2

# --- 1. Detect Architecture and Download Binary ---
echo -e "\n[Step 1/6] Detecting system architecture and downloading Warp+..."
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
echo -e "\n[Step 2/6] Installing the Warp+ binary..."
mv -f warp-plus warp
cp -f warp /usr/bin/
chmod +x /usr/bin/warp
echo "Binary installed to /usr/bin/warp."

# --- 3. Create UCI Config and LuCI UI Files ---
echo -e "\n[Step 3/6] Creating LuCI interface and configuration files..."

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
        local ipCountryCode = "N/A"
        if running then
            local ip_handle = io.popen("curl --socks5 127.0.0.1:8086 -m 7 -s http://ifconfig.me/ip")
            if ip_handle then 
                ip = ip_handle:read("*a"):gsub("\n", "")
                ip_handle:close()
                if ip ~= "N/A" and ip ~= "" then
                    local country_handle = io.popen("curl -s http://ip-api.com/json/" .. ip .. "?fields=countryCode")
                    if country_handle then
                        local json_str = country_handle:read("*a")
                        country_handle:close()
                        local code = json_str:match('"countryCode":"(..)"')
                        if code then ipCountryCode = code end
                    end
                end
            end
        end
        local mode = uci:get("wrpplus", "settings", "mode") or "scan"
        local country = uci:get("wrpplus", "settings", "country") or "US"
        local reconnect_enabled = uci:get("wrpplus", "settings", "reconnect_enabled") or "0"
        local reconnect_interval = uci:get("wrpplus", "settings", "reconnect_interval") or "120"
        luci.http.prepare_content("application/json")
        luci.http.write_json({
            running = running, ip = ip, ipCountryCode = ipCountryCode,
            mode = mode, country = country,
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
        local init_script_content = "#!/bin/sh /etc/rc.common\n" ..
                                        "START=91\nUSE_PROCD=1\nPROG=/usr/bin/warp\n" ..
                                        "start_service() {\n    local args=\"" .. args .. "\"\n" ..
                                        "    procd_open_instance\n    procd_set_param command $PROG $args\n" ..
                                        "    procd_set_param stdout 1\n    procd_set_param stderr 1\n" ..
                                        "    procd_set_param respawn\n    procd_close_instance\n}\n"
        
        local file = io.open("/etc/init.d/warp", "w")
        if file then
            file:write(init_script_content)
            file:close()
        end
        
        luci.sys.call("chmod 755 /etc/init.d/warp")
        log("Restarting warp service to apply changes.")
        luci.sys.call("/etc/init.d/warp restart >> " .. DEBUG_LOG_FILE .. " 2>&1 &")
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
    #country-select option { background-color: #333; color: #fff; }
    .debug-log-container { margin-top: 30px; padding: 15px; background-color: rgba(0, 0, 0, 0.3); border-radius: 8px; }
    #log-output { background-color: #000; color: #00ff00; padding: 10px; border-radius: 4px; font-family: monospace; font-size: 12px; white-space: pre-wrap; max-height: 250px; overflow-y: auto; border: 1px solid #333; }
</style>

<div class="peditx-container">
    <div id="notification-bar" style="display: none; position: fixed; top: 20px; left: 50%; transform: translateX(-50%); background-color: #28a745; color: white; padding: 12px 20px; border-radius: 8px; z-index: 1000; box-shadow: 0 4px 8px rgba(0,0,0,0.2); font-weight: 600; transition: opacity 0.5s;"></div>
    <h2>Warp+ Manager</h2>
    <div class="peditx-row"><span class="peditx-label">Service Status:</span><span class="peditx-value"><span id="statusIndicator" class="peditx-status-indicator"></span><span id="statusText">...</span></span></div>
    <div class="peditx-row"><span class="peditx-label">Outgoing IP:</span><span class="peditx-value"><span id="ipFlag"></span> <span id="ipText">...</span></span></div>
    <div class="peditx-row" style="justify-content: center; padding-top: 20px;"><button id="connectBtn" class="peditx-btn">Connect</button><button id="disconnectBtn" class="peditx-btn" style="display:none;">Disconnect</button></div>
    
    <div class="settings-section">
        <h3>Service Settings</h3>
        <div class="peditx-row"><span class="peditx-label">Configured Mode:</span><span id="configuredModeText" class="peditx-value">...</span></div>
        <div class="controls-group" id="mode-btn-group"><button class="peditx-btn mode-btn" data-mode="scan">Scan</button><button class="peditx-btn mode-btn" data-mode="gool">Gool</button><button class="peditx-btn mode-btn" data-mode="cfon">Psiphon</button></div>
        <div id="country-selector" class="controls-group" style="display: none; margin-top: 15px;"><label for="country-select" class="peditx-label">Psiphon Country:&nbsp;</label>
            <select id="country-select">
                <option value="AT">🇦🇹 Austria</option><option value="AU">🇦🇺 Australia</option><option value="BE">🇧🇪 Belgium</option><option value="BG">🇧🇬 Bulgaria</option><option value="CA">🇨🇦 Canada</option><option value="CH">🇨🇭 Switzerland</option><option value="CZ">🇨🇿 Czech Rep</option><option value="DE">🇩🇪 Germany</option><option value="DK">🇩🇰 Denmark</option><option value="EE">🇪🇪 Estonia</option><option value="ES">🇪🇸 Spain</option><option value="FI">🇫🇮 Finland</option><option value="FR">🇫🇷 France</option><option value="GB">🇬🇧 UK</option><option value="HR">🇭🇷 Croatia</option><option value="HU">🇭🇺 Hungary</option><option value="IE">🇮🇪 Ireland</option><option value="IN">🇮🇳 India</option><option value="IT">🇮🇹 Italy</option><option value="JP">🇯🇵 Japan</option><option value="LV">🇱🇻 Latvia</option><option value="NL">🇳🇱 Netherlands</option><option value="NO">🇳🇴 Norway</option><option value="PL">🇵🇱 Poland</option><option value="PT">🇵🇹 Portugal</option><option value="RO">🇷🇴 Romania</option><option value="RS">🇷🇸 Serbia</option><option value="SE">🇸🇪 Sweden</option><option value="SG">🇸🇬 Singapore</option><option value="SK">🇸🇰 Slovakia</option><option value="US" selected>🇺🇸 USA</option>
            </select>
        </div>
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
        <div class="peditx-row" style="justify-content: center; padding-top: 20px;"><button id="reconnectSaveBtn" class="peditx-btn btn-save-changes" style="background-color: #5bc0de;">Save Reconnect Settings</button></div>
    </div>

    <div class="debug-log-container"><h3>Debug Log</h3><pre id="log-output">Waiting for actions...</pre></div>
</div>

<script type="text/javascript">
document.addEventListener('DOMContentLoaded', function() {
    const E = id => document.getElementById(id);
    const elements = {
        indicator: E('statusIndicator'), text: E('statusText'), ip: E('ipText'), ipFlag: E('ipFlag'),
        connect: E('connectBtn'), disconnect: E('disconnectBtn'), configuredMode: E('configuredModeText'),
        applyBtn: E('applyBtn'), countryContainer: E('country-selector'), countrySelect: E('country-select'),
        reconStatus: E('reconnectStatus'), reconEnabled: E('reconnectEnabled'),
        reconInterval: E('reconnectInterval'), reconSaveBtn: E('reconnectSaveBtn'),
        log: E('log-output'), modeButtons: document.querySelectorAll('.mode-btn'),
        notificationBar: E('notification-bar'),
        allControls: document.querySelectorAll('.peditx-btn, #country-select, #reconnectEnabled, #reconnectInterval')
    };

    // This object holds the user's selections. It is the SINGLE SOURCE OF TRUTH for the controls.
    let uiState = {};
    // This object holds the last known state from the server. Used for display only.
    let serverState = {};
    let isBusy = false;
    let initialLoadComplete = false;

    const deepCopy = (obj) => JSON.parse(JSON.stringify(obj));

    const callAPI = (params, callback) => {
        const url = '<%=luci.dispatcher.build_url("admin/peditxos/wrpplus_api")%>' + params;
        const cacheBuster = (url.includes('?') ? '&' : '?') + '_t=' + new Date().getTime();
        XHR.get(url + cacheBuster, null, (x, data) => {
            if (data) callback(data);
        });
    };

    const showNotification = (message, duration = 3000) => {
        elements.notificationBar.textContent = message;
        elements.notificationBar.style.display = 'block';
        setTimeout(() => { elements.notificationBar.style.display = 'none'; }, duration);
    };

    function setBusy(busy, message = '') {
        isBusy = busy;
        elements.allControls.forEach(el => { el.disabled = busy; });
        if (busy && message) { elements.text.innerText = message; }
    }

    function getFlagEmoji(countryCode) {
        if (!countryCode || countryCode.length !== 2 || countryCode === "N/A") return '';
        const codePoints = countryCode.toUpperCase().split('').map(char => 127397 + char.charCodeAt());
        return String.fromCodePoint(...codePoints);
    }

    function updateUI() {
        if (!initialLoadComplete) return;

        // --- Update informational displays from serverState ---
        elements.indicator.className = 'peditx-status-indicator ' + (serverState.running ? 'status-connected' : 'status-disconnected');
        elements.text.innerText = isBusy ? elements.text.innerText : (serverState.running ? 'Connected' : 'Disconnected');
        elements.ip.innerText = serverState.running ? (serverState.ip || 'Fetching...') : 'N/A';
        elements.ipFlag.innerText = serverState.running ? getFlagEmoji(serverState.ipCountryCode) + ' ' : '';
        elements.connect.style.display = serverState.running ? 'none' : 'inline-block';
        elements.disconnect.style.display = serverState.running ? 'inline-block' : 'none';
        elements.configuredMode.innerText = {scan: 'Scan', gool: 'Gool', cfon: 'Psiphon'}[serverState.mode] || 'N/A';
        elements.reconStatus.innerText = serverState.reconnect_enabled === '1' ? `Enabled (Every ${serverState.reconnect_interval} mins)` : 'Disabled';

        // --- Update interactive controls from uiState ---
        elements.modeButtons.forEach(btn => btn.classList.toggle('selected-mode', btn.dataset.mode === uiState.mode));
        elements.countryContainer.style.display = (uiState.mode === 'cfon') ? 'flex' : 'none';
        elements.countrySelect.value = uiState.country;
        elements.reconEnabled.checked = uiState.reconnect_enabled === '1';
        elements.reconInterval.value = uiState.reconnect_interval;

        // --- Update save button states by comparing uiState and serverState ---
        const serviceDirty = uiState.mode !== serverState.mode || (uiState.mode === 'cfon' && uiState.country !== serverState.country);
        elements.applyBtn.classList.toggle('dirty', serviceDirty);
        const reconnectDirty = uiState.reconnect_enabled !== serverState.reconnect_enabled || uiState.reconnect_interval !== serverState.reconnect_interval;
        elements.reconSaveBtn.classList.toggle('dirty', reconnectDirty);
    }
    
    // --- EVENT LISTENERS (They only change uiState and call for a UI update) ---
    elements.modeButtons.forEach(btn => btn.addEventListener('click', function() { uiState.mode = this.dataset.mode; updateUI(); }));
    elements.countrySelect.addEventListener('change', () => { uiState.country = elements.countrySelect.value; updateUI(); });
    elements.reconEnabled.addEventListener('change', () => { uiState.reconnect_enabled = elements.reconEnabled.checked ? '1' : '0'; updateUI(); });
    elements.reconInterval.addEventListener('input', () => { uiState.reconnect_interval = elements.reconInterval.value; updateUI(); });

    // --- ACTION BUTTONS ---
    elements.connect.addEventListener('click', () => { setBusy(true, 'Connecting...'); callAPI('?action=toggle', () => setTimeout(() => { setBusy(false); callAPI('?action=status', data => { serverState.running = data.running; updateUI(); }); }, 5000)); });
    elements.disconnect.addEventListener('click', () => { setBusy(true, 'Disconnecting...'); callAPI('?action=toggle', () => setTimeout(() => { setBusy(false); callAPI('?action=status', data => { serverState.running = data.running; updateUI(); }); }, 4000)); });
    
    elements.applyBtn.addEventListener('click', () => {
        if (!elements.applyBtn.classList.contains('dirty')) return;
        setBusy(true, 'Applying Settings...');
        const params = `?action=save_settings&mode=${uiState.mode}&country=${uiState.country}`;
        callAPI(params, () => {
            // OPTIMISTIC UPDATE: The new saved state IS the current UI state.
            serverState.mode = uiState.mode;
            serverState.country = uiState.country;
            updateUI(); // Re-render instantly with the new saved state
            showNotification('Service settings applied. Restarting service...', 4000);
            setTimeout(() => {
                setBusy(false);
                // Fetch full status later to get new IP and confirm running state
                callAPI('?action=status', data => { 
                    serverState.running = data.running;
                    serverState.ip = data.ip;
                    serverState.ipCountryCode = data.ipCountryCode;
                    updateUI(); 
                });
            }, 8000);
        });
    });

    elements.reconSaveBtn.addEventListener('click', () => {
        if (!elements.reconSaveBtn.classList.contains('dirty')) return;
        setBusy(true, 'Saving Reconnect...');
        const params = `?action=save_reconnect&enabled=${uiState.reconnect_enabled}&interval=${uiState.reconnect_interval}`;
        callAPI(params, () => {
            // OPTIMISTIC UPDATE: The new saved state IS the current UI state.
            serverState.reconnect_enabled = uiState.reconnect_enabled;
            serverState.reconnect_interval = uiState.reconnect_interval;
            updateUI(); // Re-render instantly with the new saved state
            showNotification('Reconnect settings saved.', 3000);
            setBusy(false);
        });
    });

    // --- INITIAL LOAD & POLLING ---
    setBusy(true, 'Loading status...');
    callAPI('?action=status', data => {
        if (data && data.mode) {
            serverState = deepCopy(data);
            uiState = deepCopy(data);
            initialLoadComplete = true;
            setBusy(false);
            updateUI();
            
            // Polling only updates non-user-configurable parts of serverState
            setInterval(() => {
                if (isBusy || document.hidden) return;
                callAPI('?action=status', newData => {
                    serverState.running = newData.running;
                    serverState.ip = newData.ip;
                    serverState.ipCountryCode = newData.ipCountryCode;
                    updateUI();
                });
            }, 7000);
            
            callAPI('?action=get_debug_log', logData => {
                 if (logData && logData.log) elements.log.textContent = logData.log;
            });
            setInterval(() => {
                if (isBusy || document.hidden) return;
                callAPI('?action=get_debug_log', logData => {
                    if (logData && logData.log && elements.log.textContent !== logData.log) {
                        elements.log.textContent = logData.log;
                        elements.log.scrollTop = logData.log.scrollHeight;
                    }
                });
            }, 3000);

        } else {
            setBusy(false);
            elements.text.innerText = "Error loading config!";
        }
    });
});
</script>
<%+footer%>
EoL
echo "LuCI UI files created successfully."

# --- 4. Create and Enable Service ---
echo -e "\n[Step 4/6] Creating and enabling the Warp+ service..."

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
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}
EOF

chmod 755 /etc/init.d/warp
service warp enable
service warp start
echo "Warp+ service has been enabled and started."

# --- 5. Configure Passwall ---
echo -e "\n[Step 5/6] Configuring Passwall/Passwall2..."
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
echo -e "\n[Step 6/6] Finalizing installation..."
rm -f /tmp/luci-indexcache
/etc/init.d/uhttpd restart
rm -f /tmp/warp.zip /tmp/warp /tmp/README.md /tmp/LICENSE

echo -e "\n================================================"
echo "      Installation Completed Successfully! "
echo -e "================================================"
echo -e "\nPlease refresh your router's web page."
echo "You can find the new manager under: PeDitXOS Tools -> Warp+"
echo -e "\nMade By: PeDitX & Gemini\n"
