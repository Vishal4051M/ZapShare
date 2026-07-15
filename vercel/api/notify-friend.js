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
    const { targetUid, senderName } = request.body || {};
    if (!targetUid || !senderName) {
      return response.status(400).json({ error: 'Invalid friend request notification payload' });
    }

    const requestSnapshot = await getDatabase(app)
      .ref(`friend_requests/${targetUid}/${sender.uid}`)
      .get();
    const friendReq = requestSnapshot.val();
    if (!friendReq || friendReq.senderId !== sender.uid || friendReq.status !== 'pending') {
      return response.status(403).json({ error: 'Friend request is not authorized' });
    }

    const tokenSnapshot = await getDatabase(app)
      .ref(`users/${targetUid}/fcmToken`)
      .get();
    const token = tokenSnapshot.val();
    if (typeof token !== 'string' || token.length === 0) {
      return response.status(202).json({ delivered: false, reason: 'Recipient has no push token' });
    }

    const messageId = await getMessaging(app).send({
      token,
      notification: {
        title: 'New Friend Request',
        body: `${senderName} wants to add you as a friend`,
      },
      data: {
        type: 'friend_request',
        senderId: String(sender.uid),
      },
      android: {
        priority: 'high',
        notification: { channelId: 'friend_requests_channel' },
      },
    });

    return response.status(200).json({ delivered: true, messageId });
  } catch (error) {
    console.error('Friend request notification failed', error);
    return response.status(500).json({ error: 'Unable to send notification' });
  }
};
