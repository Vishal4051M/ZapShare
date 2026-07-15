const { cert, getApps, initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getDatabase } = require('firebase-admin/database');
const { getMessaging } = require('firebase-admin/messaging');

function firebaseApp() {
  if (getApps().length) return getApps()[0];

  const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
  return initializeApp({
    credential: cert(serviceAccount),
    databaseURL: process.env.FIREBASE_DATABASE_URL,
  });
}

module.exports = async (request, response) => {
  if (request.method !== 'POST') {
    response.setHeader('Allow', 'POST');
    return response.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const authorization = request.headers.authorization || '';
    const idToken = authorization.startsWith('Bearer ')
      ? authorization.substring('Bearer '.length)
      : '';
    if (!idToken) return response.status(401).json({ error: 'Missing token' });

    const app = firebaseApp();
    const sender = await getAuth(app).verifyIdToken(idToken);
    const { targetUid, transferId, senderName, fileNames = [] } = request.body || {};
    if (!targetUid || !transferId || !senderName) {
      return response.status(400).json({ error: 'Invalid transfer request' });
    }

    const transferSnapshot = await getDatabase(app)
      .ref(`transfers/${targetUid}/${transferId}`)
      .get();
    const transfer = transferSnapshot.val();
    if (!transfer || transfer.senderId !== sender.uid || transfer.status !== 'pending') {
      return response.status(403).json({ error: 'Transfer is not authorized' });
    }

    const tokenSnapshot = await getDatabase(app)
      .ref(`users/${targetUid}/fcmToken`)
      .get();
    const token = tokenSnapshot.val();
    if (typeof token !== 'string' || token.length === 0) {
      return response.status(202).json({ delivered: false, reason: 'Recipient has no push token' });
    }

    const fileCount = Array.isArray(fileNames) ? fileNames.length : 1;
    const fileLabel = fileCount === 1 ? 'a file' : `${fileCount} files`;
    const messageId = await getMessaging(app).send({
      token,
      notification: {
        title: 'Incoming ZapShare transfer',
        body: `${senderName} wants to send ${fileLabel}`,
      },
      data: {
        type: 'transfer_request',
        transferId: String(transferId),
        roomId: String(transfer.roomId || ''),
      },
      android: {
        priority: 'high',
        notification: { channelId: 'zapshare_transfer_requests' },
      },
    });

    return response.status(200).json({ delivered: true, messageId });
  } catch (error) {
    console.error('Transfer notification failed', error);
    return response.status(500).json({ error: 'Unable to send notification' });
  }
};
