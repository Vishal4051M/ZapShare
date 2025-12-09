document.addEventListener('DOMContentLoaded', function () {
    // --- State: Receiving ---
    let currentFiles = [];
    let currentIp = '';
    let receivePort = 8080;
    let selectedIndices = new Set();

    // --- State: Sending ---
    let sendIp = '';
    let sendPort = 8090;
    let filesToSend = []; // Array of File objects
    let isUploading = false;

    // --- Elements ---
    const codeInput = document.getElementById('code-input');
    const recentList = document.getElementById('recent-list');
    const toast = document.getElementById('toast');

    // Views
    const views = document.querySelectorAll('.view-layer');
    const navbar = document.getElementById('navbar');
    const selectionBar = document.getElementById('selection-bar');
    const bottomBars = document.getElementById('bottom-bars-container');

    // Receive Elements
    const fileListEl = document.getElementById('file-list');
    const btnConnect = document.getElementById('btn-connect');
    const btnSelectAll = document.getElementById('btn-select-all');
    const btnDlNow = document.getElementById('btn-dl-now');
    const btnCloseSel = document.getElementById('btn-close-sel');
    const selCountText = document.getElementById('sel-count-text');

    // Send Elements
    const btnWebSend = document.getElementById('btn-web-send');
    const btnSendBack = document.getElementById('btn-send-back');
    const fileInputEl = document.getElementById('file-input-el');
    const dropZone = document.getElementById('drop-zone');
    const uploadListEl = document.getElementById('upload-list');
    const btnUploadStart = document.getElementById('btn-upload-start');
    const uploadCountSpan = document.getElementById('upload-count');
    const sendStatus = document.getElementById('send-status');
    const warningNote = document.getElementById('warning-note');
    const btnOpenWeb = document.getElementById('btn-open-web');

    // Nav
    const navItems = document.querySelectorAll('.nav-item');

    // --- Init ---
    if (codeInput) codeInput.focus();
    loadRecentHistory();

    // --- Navigation Handlers ---
    navItems.forEach(btn => {
        btn.addEventListener('click', () => {
            // Disabled during upload?
            if (isUploading) return;

            const target = btn.getAttribute('data-target');
            // If going to home or files, ensure bottom bar is visible
            bottomBars.style.display = 'block';
            views.forEach(v => v.classList.toggle('active', v.id === target));
            navItems.forEach(b => b.classList.toggle('active', b === btn));
        });
    });

    // --- Main Actions ---
    if (btnConnect) btnConnect.onclick = () => startReceiveFlow();
    if (btnWebSend) btnWebSend.onclick = () => startSendFlow();
    if (codeInput) codeInput.onkeypress = (e) => {
        if (e.key === 'Enter') startReceiveFlow();
    };

    // --- RECEIVE LOGIC ---
    async function startReceiveFlow() {
        const { ip, code } = getIpAndCode();
        if (!ip) return;
        saveToHistory(code);

        currentIp = ip;
        showView('view-files');
        fileListEl.innerHTML = '<div style="text-align:center; padding-top:80px; color:#666;">⏳ Connecting...</div>';

        try {
            const controller = new AbortController();
            setTimeout(() => controller.abort(), 6000);
            const res = await fetch(`http://${ip}:${receivePort}/list`, { signal: controller.signal });
            if (res.ok) {
                currentFiles = await res.json();
                renderReceiveList();
            } else { throw new Error("Failed"); }
        } catch (e) {
            fileListEl.innerHTML = '<div style="text-align:center; padding-top:80px; color:#ef4444;">❌ Failed to Connect<br><span style="font-size:10px">Check if phone is ready</span></div>';
        }
    }

    // --- SEND LOGIC ---
    function startSendFlow() {
        const { ip, code } = getIpAndCode();
        if (!ip) return;
        saveToHistory(code);
        sendIp = ip;

        showView('view-send');
        bottomBars.style.display = 'none';
        filesToSend = [];
        renderUploadList();
    }

    if (btnOpenWeb) btnOpenWeb.onclick = () => {
        const { ip, code } = getIpAndCode();
        const targetIp = ip || sendIp;
        if (targetIp) {
            chrome.tabs.create({ url: `http://${targetIp}:${sendPort}/` });
        } else {
            showToast("Please enter code");
        }
    };

    if (btnSendBack) btnSendBack.onclick = () => {
        if (isUploading) return;
        showView('view-home');
        bottomBars.style.display = 'block';
    };

    // File Choosing
    if (dropZone) dropZone.onclick = () => { if (!isUploading) fileInputEl.click(); };
    if (fileInputEl) fileInputEl.onchange = (e) => {
        const newFiles = Array.from(e.target.files);
        filesToSend = [...filesToSend, ...newFiles];
        renderUploadList();
        e.target.value = '';
    };

    function renderUploadList() {
        uploadListEl.innerHTML = '';
        btnUploadStart.style.display = filesToSend.length > 0 ? 'flex' : 'none';
        btnUploadStart.innerText = `Send Now (${filesToSend.length})`;
        uploadCountSpan.innerText = filesToSend.length;
        if (warningNote) warningNote.style.display = 'block';

        filesToSend.forEach((file, index) => {
            const div = document.createElement('div');
            div.className = 'file-item';
            const sizeStr = (file.size / 1024 / 1024).toFixed(2) + ' MB';

            const status = file._status || 'Pending';
            const isSent = status === 'Sent';

            if (isSent) div.classList.add('sent');

            div.innerHTML = `
                <div class="f-icon" style="background:${isSent ? '#22c55e' : '#555'};">${isSent ? '✓' : 'FILE'}</div>
                <div class="f-info">
                   <div class="f-name">${file.name}</div>
                   <div class="f-meta">${status === 'Pending' ? sizeStr : status}</div>
                   <div class="f-progress" id="prog-${index}" style="height:2px; background:#333; width:100%; margin-top:4px; display:${status === 'Uploading...' ? 'block' : 'none'};">
                       <div style="height:100%; background:#FFF176; width:0%; transition: width 0.2s;"></div>
                   </div>
                </div>
             `;

            if (!isUploading && status === 'Pending') {
                const del = document.createElement('div');
                del.innerHTML = '&times;';
                del.style.cssText = 'color:#ef4444; font-size:18px; cursor:pointer; padding:0 10px;';
                del.onclick = () => { filesToSend.splice(index, 1); renderUploadList(); };
                div.appendChild(del);
            }

            uploadListEl.appendChild(div);
        });
    }

    if (btnUploadStart) btnUploadStart.onclick = async () => {
        if (filesToSend.length === 0 || isUploading) return;
        isUploading = true;
        btnUploadStart.disabled = true;
        sendStatus.innerText = "Requesting Approval...";

        try {
            // 1. Request Approval
            const manifest = {
                files: filesToSend.map(f => ({ name: f.name, size: f.size }))
            };

            const reqRes = await fetch(`http://${sendIp}:${sendPort}/request-upload`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(manifest)
            });

            if (!reqRes.ok) throw new Error("Connection Refused");
            const reqJson = await reqRes.json();

            if (!reqJson.approved) {
                throw new Error("Transfer Denied by Device");
            }

            sendStatus.innerText = "Sending...";

            // 2. Upload Files Sequentially
            for (let i = 0; i < filesToSend.length; i++) {
                const file = filesToSend[i];
                if (file._status === 'Sent') continue;

                file._status = 'Uploading...';
                renderUploadList();

                // Animate fake progress
                const progBar = document.getElementById(`prog-${i}`);
                if (progBar) progBar.firstElementChild.style.width = '20%';

                const cleanName = encodeURIComponent(file.name);

                await fetch(`http://${sendIp}:${sendPort}/upload?name=${cleanName}`, {
                    method: 'PUT',
                    body: file
                });

                if (progBar) progBar.firstElementChild.style.width = '100%';
                file._status = 'Sent';
                renderUploadList();
            }

            showToast("All Sent!", true);
            sendStatus.innerText = "Completed";

        } catch (e) {
            console.error(e);
            showToast(e.message || "Error");
            sendStatus.innerText = "Error: " + e.message;
        } finally {
            isUploading = false;
            btnUploadStart.disabled = false;
            btnUploadStart.innerText = `Send Now (${filesToSend.length})`;
            renderUploadList();
        }
    };


    // --- RECEIVE RENDER & LOGIC --- (Standard Logic)

    if (btnSelectAll) btnSelectAll.onclick = () => {
        if (currentFiles.length === 0) return;
        if (selectedIndices.size === currentFiles.length) selectedIndices.clear();
        else currentFiles.forEach(f => selectedIndices.add(f.index));
        renderReceiveList();
    };
    if (btnCloseSel) btnCloseSel.onclick = () => { selectedIndices.clear(); renderReceiveList(); };

    if (btnDlNow) btnDlNow.onclick = () => {
        const dlFiles = currentFiles.filter(f => selectedIndices.has(f.index));
        if (dlFiles.length === 0) return;
        btnDlNow.innerText = "Starting...";
        let count = 0;
        dlFiles.forEach(f => {
            const url = `http://${currentIp}:${receivePort}/file/${f.index}`;
            chrome.downloads.download({ url, filename: f.name, saveAs: false, conflictAction: 'overwrite' }, () => {
                count++;
                if (count === dlFiles.length) { showToast("Started"); selectedIndices.clear(); renderReceiveList(); btnDlNow.innerText = "Download"; }
            });
        });
    };

    function renderReceiveList() {
        const countTxt = document.getElementById('file-count-text');
        if (countTxt) countTxt.innerText = `Files (${currentFiles.length})`;
        if (btnSelectAll) btnSelectAll.innerText = (selectedIndices.size > 0 && selectedIndices.size === currentFiles.length) ? "Deselect All" : "Select All";

        if (selectedIndices.size > 0) {
            navbar.classList.add('hidden');
            selectionBar.classList.add('visible');
            selCountText.innerText = `${selectedIndices.size} selected`;
        } else {
            navbar.classList.remove('hidden');
            selectionBar.classList.remove('visible');
        }

        fileListEl.innerHTML = '';
        if (currentFiles.length === 0) {
            fileListEl.innerHTML = '<div style="text-align:center; margin-top:80px; opacity:0.5;">No Files</div>';
            return;
        }

        currentFiles.forEach(file => {
            const isSel = selectedIndices.has(file.index);
            const div = document.createElement('div');
            div.className = `file-item ${isSel ? 'item-selected' : ''}`;
            const ext = file.name.split('.').pop().toLowerCase();
            const isImg = ['jpg', 'jpeg', 'png', 'gif', 'webp'].includes(ext);
            const url = `http://${currentIp}:${receivePort}/file/${file.index}`;
            const sizeStr = file.size < 1024 * 1024 ? (file.size / 1024).toFixed(1) + ' KB' : (file.size / (1024 * 1024)).toFixed(1) + ' MB';

            div.innerHTML = `
                <div class="f-chk"></div>
                <div class="f-icon" style="${isImg ? '' : 'background:#444; color:#aaa;'}">${isImg ? `<img src="${url}">` : 'FIL'}</div>
                <div class="f-info"><div class="f-name">${file.name}</div><div class="f-meta">${sizeStr}</div></div>
            `;
            div.onclick = () => {
                if (selectedIndices.has(file.index)) selectedIndices.delete(file.index);
                else selectedIndices.add(file.index);
                renderReceiveList();
            };
            fileListEl.appendChild(div);
        });
    }

    // --- Helpers ---
    function getIpAndCode() {
        const code = codeInput.value.trim().toUpperCase();
        if (!code) { showToast("Enter Code"); return { ip: null, code: null }; }

        let ip = null;
        if (/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(code)) ip = code;
        else if (/^[0-9A-Z]{1,8}$/.test(code)) {
            const val = parseInt(code, 36);
            if (!isNaN(val)) ip = `${(val >>> 24) & 255}.${(val >>> 16) & 255}.${(val >>> 8) & 255}.${val & 255}`;
        }

        if (!ip) { showToast("Invalid Code"); return { ip: null, code: null }; }
        return { ip, code };
    }

    function showView(id) {
        views.forEach(v => v.classList.toggle('active', v.id === id));
        if (id === 'view-send') {
            navItems.forEach(b => b.classList.remove('active'));
        } else if (id === 'view-home') {
            navItems.forEach(b => b.classList.toggle('active', b.getAttribute('data-target') === 'view-home'));
        }
    }

    function showToast(msg, success = false) {
        toast.innerText = msg;
        toast.style.background = success ? '#22c55e' : '#ef4444';
        toast.classList.add('visible');
        setTimeout(() => toast.classList.remove('visible'), 2500);
    }

    function loadRecentHistory() {
        try {
            const h = JSON.parse(localStorage.getItem('zap_history') || '[]');
            recentList.innerHTML = '';
            h.forEach(c => {
                const chip = document.createElement('div');
                chip.className = 'chip';
                chip.innerHTML = `${c} <span class="chip-del">&times;</span>`;
                chip.onclick = () => { if (codeInput) codeInput.value = c; };
                chip.querySelector('.chip-del').onclick = (e) => {
                    e.stopPropagation();
                    localStorage.setItem('zap_history', JSON.stringify(h.filter(x => x !== c)));
                    loadRecentHistory();
                };
                recentList.appendChild(chip);
            });
        } catch (e) { }
    }
    function saveToHistory(c) {
        let h = JSON.parse(localStorage.getItem('zap_history') || '[]');
        h = h.filter(x => x !== c);
        h.unshift(c);
        if (h.length > 5) h.pop();
        localStorage.setItem('zap_history', JSON.stringify(h));
        loadRecentHistory();
    }
});
