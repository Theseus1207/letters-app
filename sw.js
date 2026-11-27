// =========================================================
// Service Worker：離線快取 + 背景推播
// 改了網站檔案後，把 CACHE 的版本號 +1，使用者下次打開就會更新
// =========================================================
const CACHE = 'letters-v11';
const SHELL = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/badge-72.png',
];

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// 只處理自己網站的檔案：先抓網路（拿到最新版），沒網路時用快取
// Supabase 的資料請求不經過快取
self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;
  event.respondWith(
    fetch(req)
      .then(res => {
        if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
        return res;
      })
      .catch(() => caches.match(req, { ignoreSearch: true }).then(r => r || caches.match('./index.html')))
  );
});

// Apple（iPhone / Mac Safari）不允許收到推播卻不顯示通知，否則可能被收回通知權限
const ua = self.navigator.userAgent;
const IS_APPLE_WEBKIT = /iPhone|iPad|iPod/.test(ua) ||
  (/Macintosh/.test(ua) && /Safari/.test(ua) && !/Chrome|Chromium|Edg|Firefox/.test(ua));

self.addEventListener('push', event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch {}

  // App 圖示上的未讀數字（支援的平台才有）。獨立出來，就算這步卡住／失敗，
  // 也不會連累下面「顯示橫幅通知」一起卡住——這兩件事互不影響。
  const updateBadge = (async () => {
    if (typeof data.unread !== 'number' || !self.navigator.setAppBadge) return;
    try { data.unread > 0 ? await self.navigator.setAppBadge(data.unread) : await self.navigator.clearAppBadge(); }
    catch (e) { console.error('更新角標失敗', e); }
  })();

  const showBanner = (async () => {
    // 使用者正盯著 App 時，交給頁面內的提示就好，不重複跳系統通知
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const watching = wins.some(w => w.visibilityState === 'visible' && w.focused);
    if (watching && !IS_APPLE_WEBKIT) {
      wins.forEach(w => w.postMessage({ type: 'push', data }));
      return;
    }
    const opts = {
      body: data.body || '你有新的信',
      icon: './icons/icon-192.png',
      badge: './icons/badge-72.png',
      tag: data.tag || 'letters',
      renotify: true,
      data: { url: data.url || './' },
    };
    try {
      await self.registration.showNotification(data.title || '信箋與漂流瓶', opts);
    } catch (e) {
      // 原本的設定（圖示路徑、tag 等）某個欄位讓系統拒絕顯示；
      // 退回最簡單的版本再試一次，至少讓橫幅/鎖定畫面通知能出現
      console.error('showNotification 失敗，改用最簡版本重試', e);
      try { await self.registration.showNotification(data.title || '信箋與漂流瓶', { body: opts.body }); }
      catch (e2) { console.error('showNotification 重試仍失敗', e2); }
    }
  })();

  event.waitUntil(Promise.allSettled([updateBadge, showBanner]));
});

// 點通知：已經開著就切過去並打開那封信，沒開就開新視窗
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || './', self.registration.scope).href;
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) {
      if (w.url.startsWith(self.registration.scope)) {
        await w.focus();
        w.postMessage({ type: 'open', url });
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
