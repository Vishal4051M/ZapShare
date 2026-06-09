// background.js

let uploadState = {
    isUploading: false,
    files: [], // { name, size, status, progress, fileObj(optional) }
    currentIndex: 0,
    targetIp: '',
    targetPort: 8090,
    error: null
};

// Listen for messages from popup
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.type === 'GET_STATUS') {
        // Return a sanitized version of state (cannot send File objects back easily if not needed)
        sendResponse(getPublicState());
    }
    else if (msg.type === 'START_UPLOAD') {
        if (uploadState.isUploading) {
            sendResponse({ success: false, error: 'Already uploading' });
            return;
        }

        // Initialize State
        // We expect msg.files to be mapped structure from popup: {name, size, type, fileBlob}
        uploadState = {
            isUploading: true,
            files: msg.files.map(f => ({
                name: f.name,
                size: f.size,
                type: f.type,
                fileObj: f.fileBlob || f,
                progress: 0,
                status: 'pending'
            })),
            currentIndex: 0,
            targetIp: msg.ip,
            targetPort: msg.port || 8090,
            error: null
        };

        startUploadProcess();
        sendResponse({ success: true });
    }
    else if (msg.type === 'CANCEL_UPLOAD') {
        // simplistic cancel
        uploadState.isUploading = false;
        uploadState.error = "Cancelled by user";
        sendResponse({ success: true });
    }

    return true; // async response
});


function getPublicState() {
    return {
        isUploading: uploadState.isUploading,
        currentIndex: uploadState.currentIndex,
        targetIp: uploadState.targetIp,
        error: uploadState.error,
        files: uploadState.files.map(f => ({
            name: f.name,
            size: f.size,
            progress: f.progress,
            status: f.status
        }))
    };
}

async function startUploadProcess() {
    const { targetIp, targetPort, files } = uploadState;

    try {
        // 1. Request Approval
        // We notify the first file's progress as "Requesting..."
        if (files.length > 0) files[0].status = "Requesting Approval...";
        broadcastUpdate();

        const manifest = {
            files: files.map(f => ({ name: f.name, size: f.size }))
        };

        const reqRes = await fetch(`http://${targetIp}:${targetPort}/request-upload`, {
            method: 'POST',
            body: JSON.stringify(manifest)
        });

        if (!reqRes.ok) throw new Error("Connection Refused");
        const reqJson = await reqRes.json();
        if (!reqJson.approved) throw new Error("Transfer Denied by Device");

        // 2. Upload Sequentially
        for (let i = 0; i < files.length; i++) {
            if (!uploadState.isUploading) break; // Check cancel

            uploadState.currentIndex = i;
            files[i].status = "Uploading...";
            broadcastUpdate();

            const fileItem = files[i];
            const cleanName = encodeURIComponent(fileItem.name);

            // Actual Upload
            await fetch(`http://${targetIp}:${targetPort}/upload?name=${cleanName}`, {
                method: 'PUT',
                body: fileItem.fileObj
            });

            files[i].progress = 100;
            files[i].status = "Sent";
            broadcastUpdate();
        }

        uploadState.isUploading = false;
        broadcastUpdate();

    } catch (e) {
        console.error("Upload Error", e);
        uploadState.isUploading = false;
        uploadState.error = e.message;
        // Mark current file as failed
        if (uploadState.currentIndex < uploadState.files.length) {
            uploadState.files[uploadState.currentIndex].status = "Failed";
        }
        broadcastUpdate();
    }
}

function broadcastUpdate() {
    chrome.runtime.sendMessage({
        type: 'STATE_UPDATE',
        state: getPublicState()
    }).catch(() => {
        // Popup might be closed, ignore error
    });
}
