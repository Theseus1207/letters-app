// =========================================================
// Edge Function：send-push
// 由資料庫觸發器呼叫，發 Web Push 給使用者的所有裝置
//
// 需要的 secrets（supabase secrets set ...）：
//   VAPID_PUBLIC_KEY、VAPID_PRIVATE_KEY、VAPID_SUBJECT、PUSH_WEBHOOK_SECRET
// SUPABASE_URL、SUPABASE_SERVICE_ROLE_KEY 由 Supabase 自動提供
// 部署：supabase functions deploy send-push --no-verify-jwt
// =========================================================
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2';

const env = (k: string) => {
  const v = Deno.env.get(k);
  if (!v) throw new Error(`缺少環境變數 ${k}`);
  return v;
};

const WEBHOOK_SECRET = env('PUSH_WEBHOOK_SECRET');
webpush.setVapidDetails(
  Deno.env.get('VAPID_SUBJECT') ?? 'mailto:admin@example.com',
  env('VAPID_PUBLIC_KEY'),
  env('VAPID_PRIVATE_KEY'),
);
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false },
});

type Event = {
  user_id: string;
  type: 'new_letter' | 'bottle_picked';
  kind: 'letter' | 'bottle';
  letter_id: number;
  unread?: number;
};

// 通知文字刻意不放信件內容，避免在鎖定畫面被別人看到
function message(ev: Event) {
  if (ev.type === 'bottle_picked') {
    return { body: '你的漂流瓶被陌生人撿到了 🍾', url: './?view=sent' };
  }
  return {
    body: ev.kind === 'bottle' ? '海上的陌生人回信了 🍾' : '你收到一封新信 💌',
    url: `./?open=${ev.letter_id}`,
  };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  if (req.headers.get('x-webhook-secret') !== WEBHOOK_SECRET) {
    return new Response('unauthorized', { status: 401 });
  }

  let ev: Event;
  try {
    ev = await req.json();
  } catch {
    return new Response('bad json', { status: 400 });
  }
  if (!ev.user_id || !ev.type) return new Response('missing fields', { status: 400 });

  const { data: subs, error } = await admin
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth')
    .eq('user_id', ev.user_id);
  if (error) return new Response(error.message, { status: 500 });
  if (!subs?.length) return Response.json({ sent: 0 });

  const { body, url } = message(ev);
  const payload = JSON.stringify({
    title: '信箋與漂流瓶',
    body,
    url,
    tag: `${ev.type}-${ev.letter_id}`,
    type: ev.type,
    kind: ev.kind,
    id: ev.letter_id,
    unread: ev.unread ?? null,
  });

  const results = await Promise.allSettled(
    subs.map((s) =>
      webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload,
        { TTL: 60 * 60 * 24, urgency: 'normal' },
      )
    ),
  );

  // 裝置已取消訂閱（404 / 410）→ 從資料庫刪掉
  const dead = subs.filter((_, i) => {
    const r = results[i];
    return r.status === 'rejected' && [404, 410].includes((r.reason as { statusCode?: number })?.statusCode ?? 0);
  });
  if (dead.length) {
    await admin.from('push_subscriptions').delete().in('id', dead.map((d) => d.id));
  }

  const failed = results.filter((r) => r.status === 'rejected');
  failed.forEach((r) => console.error('push failed', (r as PromiseRejectedResult).reason));

  return Response.json({
    sent: results.length - failed.length,
    failed: failed.length,
    removed: dead.length,
  });
});
