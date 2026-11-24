-- =========================================================
-- 推播設定（部署完 Edge Function 之後執行一次）
-- 把兩個 <...> 換成你自己的值，在 SQL Editor 執行
-- =========================================================

-- 1. Edge Function 的網址（把 <project-ref> 換成你的專案代號）
select vault.create_secret(
  'https://<project-ref>.supabase.co/functions/v1/send-push',
  'push_function_url'
);

-- 2. 和 Edge Function 共用的密碼（要和 PUSH_WEBHOOK_SECRET 一模一樣）
select vault.create_secret(
  '<一串你自己產生的長密碼>',
  'push_webhook_secret'
);

-- 之後要修改：
-- select vault.update_secret(
--   (select id from vault.secrets where name = 'push_webhook_secret'),
--   '<新的密碼>'
-- );
