-- SERAY Digital Studio. Run once in a NEW, dedicated Supabase project SQL editor.
-- Money is stored as integer USD cents. No prices are invented by this installer.
begin;
create table if not exists public.seray_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 email text not null, blocked boolean not null default false, created_at timestamptz not null default now()
);
create table if not exists public.seray_wallets (
 user_id uuid primary key references public.seray_profiles(user_id) on delete cascade,
 balance_minor bigint not null default 0 check(balance_minor>=0), currency text not null default 'USD' check(currency='USD')
);
create table if not exists public.seray_services (
 id text primary key, name text not null, hosts text[] not null,
 rate_minor bigint check(rate_minor between 1 and 100000000), pricing_unit integer not null default 1000 check(pricing_unit in (1,1000)),
 min_quantity integer not null default 1 check(min_quantity>0), max_quantity integer not null default 1000000,
 enabled boolean not null default false, provider_service_id integer,
 provider_type text not null default 'manual' check(provider_type in ('manual','Default','Custom Comments')),
 check(max_quantity>=min_quantity), check(not enabled or rate_minor is not null),
 check(provider_type='manual' or provider_service_id>0)
);
create table if not exists public.seray_orders (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.seray_profiles(user_id),
 request_key uuid not null, service_id text not null references public.seray_services(id), service_name text not null,
 quantity integer not null, link text not null, details jsonb not null default '{}',
 charge_minor bigint not null check(charge_minor>0), refunded_minor bigint not null default 0 check(refunded_minor>=0 and refunded_minor<=charge_minor),
 status text not null default 'queued' check(status in ('queued','processing','completed','partial','cancelled','needs_review')),
 provider_id bigint, provider_state text not null default 'none' check(provider_state in ('none','submitting','submitted','unknown')),
 provider_service_id integer, provider_type text not null default 'manual',
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(user_id,request_key)
);
create index if not exists seray_orders_owner_date on public.seray_orders(user_id,created_at desc);
create table if not exists public.seray_topups (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.seray_profiles(user_id),
 amount_minor bigint not null check(amount_minor between 100 and 1000000), reference text not null,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 created_at timestamptz not null default now(), decided_at timestamptz, unique(reference)
);
create table if not exists public.seray_transactions (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.seray_profiles(user_id),
 amount_minor bigint not null, kind text not null check(kind in ('order','topup','refund')),
 order_id uuid references public.seray_orders(id), topup_id uuid references public.seray_topups(id), created_at timestamptz not null default now()
);
create index if not exists seray_transactions_owner_date on public.seray_transactions(user_id,created_at desc);
create table if not exists public.seray_tickets (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.seray_profiles(user_id),
 subject text not null, message text not null, reply text not null default '',
 status text not null default 'open' check(status in ('open','answered','closed')), created_at timestamptz not null default now()
);
create index if not exists seray_topups_owner on public.seray_topups(user_id,created_at desc);
create index if not exists seray_tickets_owner on public.seray_tickets(user_id,created_at desc);
alter table public.seray_profiles enable row level security;
alter table public.seray_wallets enable row level security;
alter table public.seray_services enable row level security;
alter table public.seray_orders enable row level security;
alter table public.seray_topups enable row level security;
alter table public.seray_transactions enable row level security;
alter table public.seray_tickets enable row level security;
drop policy if exists seray_read_profile on public.seray_profiles;
create policy seray_read_profile on public.seray_profiles for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists seray_read_wallet on public.seray_wallets;
create policy seray_read_wallet on public.seray_wallets for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists seray_read_orders on public.seray_orders;
create policy seray_read_orders on public.seray_orders for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists seray_read_topups on public.seray_topups;
create policy seray_read_topups on public.seray_topups for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists seray_read_transactions on public.seray_transactions;
create policy seray_read_transactions on public.seray_transactions for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists seray_read_tickets on public.seray_tickets;
create policy seray_read_tickets on public.seray_tickets for select to authenticated using(user_id=(select auth.uid()));
-- Services are read through the server, which omits provider mapping from customer results.
revoke all on public.seray_profiles,public.seray_wallets,public.seray_services,public.seray_orders,public.seray_topups,public.seray_transactions,public.seray_tickets from anon,authenticated;
grant select on public.seray_profiles,public.seray_wallets,public.seray_orders,public.seray_topups,public.seray_transactions,public.seray_tickets to authenticated;
grant all on public.seray_profiles,public.seray_wallets,public.seray_services,public.seray_orders,public.seray_topups,public.seray_transactions,public.seray_tickets to service_role;

create or replace function public.seray_ensure_user(p_user uuid,p_email text) returns void language plpgsql security invoker set search_path='' as $$
begin
 insert into public.seray_profiles(user_id,email) values(p_user,p_email) on conflict(user_id) do update set email=excluded.email;
 insert into public.seray_wallets(user_id) values(p_user) on conflict do nothing;
end $$;

create or replace function public.seray_place_order(p_user uuid,p_key uuid,p_service text,p_quantity integer,p_link text,p_details jsonb,p_expected bigint) returns public.seray_orders language plpgsql security invoker set search_path='' as $$
declare s public.seray_services; w public.seray_wallets; o public.seray_orders; cost bigint;
begin
 if exists(select 1 from public.seray_profiles where user_id=p_user and blocked) then raise exception 'ACCOUNT_BLOCKED'; end if;
 select * into w from public.seray_wallets where user_id=p_user for update;
 if not found then raise exception 'ACCOUNT_MISSING'; end if;
 select * into o from public.seray_orders where user_id=p_user and request_key=p_key;
 if found then
  if o.service_id<>p_service or o.quantity<>p_quantity or o.link<>p_link or o.details<>p_details then raise exception 'REQUEST_CONFLICT'; end if;
  return o;
 end if;
 select * into s from public.seray_services where id=p_service for share;
 if not found or not s.enabled or s.rate_minor is null then raise exception 'SERVICE_UNAVAILABLE'; end if;
 if p_quantity is null or p_quantity<s.min_quantity or p_quantity>s.max_quantity then raise exception 'INVALID_QUANTITY'; end if;
 if p_link is null or length(p_link)>2000 or p_details is null then raise exception 'INVALID_REQUEST'; end if;
 cost=ceil(s.rate_minor::numeric*p_quantity/s.pricing_unit)::bigint;
 if p_expected is distinct from cost then raise exception 'PRICE_CHANGED'; end if;
 if w.balance_minor<cost then raise exception 'INSUFFICIENT_BALANCE'; end if;
 insert into public.seray_orders(user_id,request_key,service_id,service_name,quantity,link,details,charge_minor,provider_service_id,provider_type)
 values(p_user,p_key,s.id,s.name,p_quantity,p_link,p_details,cost,s.provider_service_id,s.provider_type) returning * into o;
 update public.seray_wallets set balance_minor=balance_minor-cost where user_id=p_user;
 insert into public.seray_transactions(user_id,amount_minor,kind,order_id) values(p_user,-cost,'order',o.id);
 return o;
end $$;

create or replace function public.seray_decide_topup(p_id uuid,p_approve boolean) returns public.seray_topups language plpgsql security invoker set search_path='' as $$
declare t public.seray_topups;
begin
 select * into t from public.seray_topups where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if t.status<>'pending' then return t; end if;
 if p_approve then
  update public.seray_wallets set balance_minor=balance_minor+t.amount_minor where user_id=t.user_id;
  insert into public.seray_transactions(user_id,amount_minor,kind,topup_id) values(t.user_id,t.amount_minor,'topup',t.id);
 end if;
 update public.seray_topups set status=case when p_approve then 'approved' else 'rejected' end,decided_at=now() where id=t.id returning * into t;
 return t;
end $$;

-- Total refund, not incremental. Repeated updates cannot refund the same amount twice.
create or replace function public.seray_update_order(p_id uuid,p_status text,p_refund_total bigint) returns public.seray_orders language plpgsql security invoker set search_path='' as $$
declare o public.seray_orders; delta bigint;
begin
 select * into o from public.seray_orders where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if p_status not in ('queued','processing','completed','partial','cancelled','needs_review') or p_refund_total is null or p_refund_total<o.refunded_minor or p_refund_total>o.charge_minor then raise exception 'INVALID_UPDATE'; end if;
 if o.status in ('completed','partial','cancelled') and p_status<>o.status then raise exception 'ORDER_FINAL'; end if;
 if p_refund_total>0 and p_status not in ('partial','cancelled') then raise exception 'INVALID_REFUND'; end if;
 delta=p_refund_total-o.refunded_minor;
 if delta>0 then
  update public.seray_wallets set balance_minor=balance_minor+delta where user_id=o.user_id;
  insert into public.seray_transactions(user_id,amount_minor,kind,order_id) values(o.user_id,delta,'refund',o.id);
 end if;
 update public.seray_orders set status=p_status,refunded_minor=p_refund_total,updated_at=now() where id=o.id returning * into o;
 return o;
end $$;

create or replace function public.seray_claim_provider_order(p_id uuid) returns public.seray_orders language plpgsql security invoker set search_path='' as $$
declare o public.seray_orders;
begin
 update public.seray_orders set provider_state='submitting',status='processing',updated_at=now()
 where id=p_id and status='queued' and provider_state='none' and provider_type<>'manual' returning * into o;
 return o;
end $$;
revoke all on function public.seray_ensure_user(uuid,text),public.seray_place_order(uuid,uuid,text,integer,text,jsonb,bigint),public.seray_decide_topup(uuid,boolean),public.seray_update_order(uuid,text,bigint),public.seray_claim_provider_order(uuid) from public,anon,authenticated;
grant execute on function public.seray_ensure_user(uuid,text),public.seray_place_order(uuid,uuid,text,integer,text,jsonb,bigint),public.seray_decide_topup(uuid,boolean),public.seray_update_order(uuid,text,bigint),public.seray_claim_provider_order(uuid) to service_role;

insert into public.seray_services(id,name,hosts) values
('instagram:followers:domestic','Instagram · followers · domestic',ARRAY['instagram.com']),
('instagram:followers:international','Instagram · followers · international',ARRAY['instagram.com']),
('instagram:channel','Instagram · channel',ARRAY['instagram.com']),
('instagram:likes','Instagram · likes',ARRAY['instagram.com']),
('instagram:likesLocal','Instagram · likesLocal',ARRAY['instagram.com']),
('instagram:likesCountry','Instagram · likesCountry',ARRAY['instagram.com']),
('instagram:views','Instagram · views',ARRAY['instagram.com']),
('instagram:viewsCountry','Instagram · viewsCountry',ARRAY['instagram.com']),
('instagram:auto','Instagram · auto',ARRAY['instagram.com']),
('instagram:repost','Instagram · repost',ARRAY['instagram.com']),
('instagram:story','Instagram · story',ARRAY['instagram.com']),
('instagram:poll','Instagram · poll',ARRAY['instagram.com']),
('instagram:storyLink','Instagram · storyLink',ARRAY['instagram.com']),
('instagram:impressions','Instagram · impressions',ARRAY['instagram.com']),
('instagram:comments','Instagram · comments',ARRAY['instagram.com']),
('instagram:explore','Instagram · explore',ARRAY['instagram.com']),
('instagram:saves','Instagram · saves',ARRAY['instagram.com']),
('instagram:shares','Instagram · shares',ARRAY['instagram.com']),
('instagram:live','Instagram · live',ARRAY['instagram.com']),
('instagram:monthly','Instagram · monthly',ARRAY['instagram.com']),
('tiktok:followers:domestic','TikTok · followers · domestic',ARRAY['tiktok.com']),
('tiktok:followers:international','TikTok · followers · international',ARRAY['tiktok.com']),
('tiktok:likes','TikTok · likes',ARRAY['tiktok.com']),
('tiktok:likesCountry','TikTok · likesCountry',ARRAY['tiktok.com']),
('tiktok:views','TikTok · views',ARRAY['tiktok.com']),
('tiktok:viewsCountry','TikTok · viewsCountry',ARRAY['tiktok.com']),
('tiktok:auto','TikTok · auto',ARRAY['tiktok.com']),
('tiktok:live','TikTok · live',ARRAY['tiktok.com']),
('tiktok:comments','TikTok · comments',ARRAY['tiktok.com']),
('tiktok:shares','TikTok · shares',ARRAY['tiktok.com']),
('tiktok:saves','TikTok · saves',ARRAY['tiktok.com']),
('tiktok:monthly','TikTok · monthly',ARRAY['tiktok.com']),
('x:followers:domestic','X · followers · domestic',ARRAY['x.com','twitter.com']),
('x:followers:international','X · followers · international',ARRAY['x.com','twitter.com']),
('x:likes','X · likes',ARRAY['x.com','twitter.com']),
('x:likesLocal','X · likesLocal',ARRAY['x.com','twitter.com']),
('x:retweet','X · retweet',ARRAY['x.com','twitter.com']),
('x:retweetLocal','X · retweetLocal',ARRAY['x.com','twitter.com']),
('x:verifiedRetweet','X · verifiedRetweet',ARRAY['x.com','twitter.com']),
('x:views','X · views',ARRAY['x.com','twitter.com']),
('x:impressions','X · impressions',ARRAY['x.com','twitter.com']),
('x:poll','X · poll',ARRAY['x.com','twitter.com']),
('x:comments','X · comments',ARRAY['x.com','twitter.com']),
('x:space','X · space',ARRAY['x.com','twitter.com']),
('x:monthly','X · monthly',ARRAY['x.com','twitter.com']),
('youtube:subscribers','YouTube · subscribers',ARRAY['youtube.com','youtu.be']),
('youtube:views','YouTube · views',ARRAY['youtube.com','youtu.be']),
('youtube:likes','YouTube · likes',ARRAY['youtube.com','youtu.be']),
('youtube:dislikes','YouTube · dislikes',ARRAY['youtube.com','youtu.be']),
('youtube:likesCountry','YouTube · likesCountry',ARRAY['youtube.com','youtu.be']),
('youtube:comments','YouTube · comments',ARRAY['youtube.com','youtu.be']),
('youtube:engagement','YouTube · engagement',ARRAY['youtube.com','youtu.be']),
('youtube:live','YouTube · live',ARRAY['youtube.com','youtu.be']),
('youtube:watchHours','YouTube · watchHours',ARRAY['youtube.com','youtu.be']),
('youtube:auto','YouTube · auto',ARRAY['youtube.com','youtu.be']),
('youtube:monthly','YouTube · monthly',ARRAY['youtube.com','youtu.be']),
('twitch:followers:domestic','Twitch · followers · domestic',ARRAY['twitch.tv']),
('twitch:followers:international','Twitch · followers · international',ARRAY['twitch.tv']),
('twitch:live','Twitch · live',ARRAY['twitch.tv']),
('kick:followers:domestic','Kick · followers · domestic',ARRAY['kick.com']),
('kick:followers:international','Kick · followers · international',ARRAY['kick.com']),
('kick:live','Kick · live',ARRAY['kick.com']),
('kick:chat','Kick · chat',ARRAY['kick.com']),
('telegram:members','Telegram · members',ARRAY['t.me','telegram.me']),
('telegram:views','Telegram · views',ARRAY['t.me','telegram.me']),
('telegram:reactions','Telegram · reactions',ARRAY['t.me','telegram.me']),
('telegram:story','Telegram · story',ARRAY['t.me','telegram.me']),
('telegram:comments','Telegram · comments',ARRAY['t.me','telegram.me']),
('telegram:poll','Telegram · poll',ARRAY['t.me','telegram.me']),
('telegram:shares','Telegram · shares',ARRAY['t.me','telegram.me']),
('telegram:auto','Telegram · auto',ARRAY['t.me','telegram.me']),
('telegram:monthly','Telegram · monthly',ARRAY['t.me','telegram.me']),
('discord:boosters','Discord · boosters',ARRAY['discord.gg','discord.com']),
('facebook:followers:domestic','Facebook · followers · domestic',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:followers:international','Facebook · followers · international',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:pageLikes','Facebook · pageLikes',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:likes','Facebook · likes',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:reactions','Facebook · reactions',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:members','Facebook · members',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:views','Facebook · views',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:poll','Facebook · poll',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:story','Facebook · story',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:shares','Facebook · shares',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:reels','Facebook · reels',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:comments','Facebook · comments',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:live','Facebook · live',ARRAY['facebook.com','fb.com','fb.watch']),
('facebook:monthly','Facebook · monthly',ARRAY['facebook.com','fb.com','fb.watch']),
('spotify:followers:domestic','Spotify · followers · domestic',ARRAY['spotify.com']),
('spotify:followers:international','Spotify · followers · international',ARRAY['spotify.com']),
('spotify:listeners','Spotify · listeners',ARRAY['spotify.com']),
('spotify:saves','Spotify · saves',ARRAY['spotify.com']),
('reddit:followers:domestic','Reddit · followers · domestic',ARRAY['reddit.com']),
('reddit:followers:international','Reddit · followers · international',ARRAY['reddit.com']),
('reddit:upvotes','Reddit · upvotes',ARRAY['reddit.com']),
('reddit:comments','Reddit · comments',ARRAY['reddit.com']),
('soundcloud:followers:domestic','SoundCloud · followers · domestic',ARRAY['soundcloud.com']),
('soundcloud:followers:international','SoundCloud · followers · international',ARRAY['soundcloud.com']),
('soundcloud:plays','SoundCloud · plays',ARRAY['soundcloud.com']),
('soundcloud:likes','SoundCloud · likes',ARRAY['soundcloud.com']),
('soundcloud:repost','SoundCloud · repost',ARRAY['soundcloud.com']),
('snapchat:followers:domestic','Snapchat · followers · domestic',ARRAY['snapchat.com']),
('snapchat:followers:international','Snapchat · followers · international',ARRAY['snapchat.com']),
('snapchat:views','Snapchat · views',ARRAY['snapchat.com']),
('snapchat:story','Snapchat · story',ARRAY['snapchat.com']),
('snapchat:monthly','Snapchat · monthly',ARRAY['snapchat.com']),
('linkedin:followers:domestic','LinkedIn · followers · domestic',ARRAY['linkedin.com']),
('linkedin:followers:international','LinkedIn · followers · international',ARRAY['linkedin.com']),
('linkedin:likes','LinkedIn · likes',ARRAY['linkedin.com']),
('linkedin:comments','LinkedIn · comments',ARRAY['linkedin.com']),
('linkedin:monthly','LinkedIn · monthly',ARRAY['linkedin.com']),
('pinterest:followers:domestic','Pinterest · followers · domestic',ARRAY['pinterest.com','pin.it']),
('pinterest:followers:international','Pinterest · followers · international',ARRAY['pinterest.com','pin.it']),
('pinterest:saves','Pinterest · saves',ARRAY['pinterest.com','pin.it']),
('pinterest:views','Pinterest · views',ARRAY['pinterest.com','pin.it']),
('pinterest:monthly','Pinterest · monthly',ARRAY['pinterest.com','pin.it']),
('threads:followers:domestic','Threads · followers · domestic',ARRAY['threads.net','threads.com']),
('threads:followers:international','Threads · followers · international',ARRAY['threads.net','threads.com']),
('threads:likes','Threads · likes',ARRAY['threads.net','threads.com']),
('threads:comments','Threads · comments',ARRAY['threads.net','threads.com']),
('threads:repost','Threads · repost',ARRAY['threads.net','threads.com']),
('googleplay:downloads','Google Play · downloads',ARRAY['play.google.com']),
('kwai:followers:domestic','Kwai · followers · domestic',ARRAY['kwai.com']),
('kwai:followers:international','Kwai · followers · international',ARRAY['kwai.com']),
('kwai:likes','Kwai · likes',ARRAY['kwai.com']),
('kwai:views','Kwai · views',ARRAY['kwai.com']),
('kwai:monthly','Kwai · monthly',ARRAY['kwai.com']),
('bluesky:followers:domestic','Bluesky · followers · domestic',ARRAY['bsky.app']),
('bluesky:followers:international','Bluesky · followers · international',ARRAY['bsky.app']),
('bluesky:likes','Bluesky · likes',ARRAY['bsky.app']),
('bluesky:repost','Bluesky · repost',ARRAY['bsky.app']),
('bluesky:monthly','Bluesky · monthly',ARRAY['bsky.app']),
('behance:followers:domestic','Behance · followers · domestic',ARRAY['behance.net']),
('behance:followers:international','Behance · followers · international',ARRAY['behance.net']),
('behance:likes','Behance · likes',ARRAY['behance.net']),
('behance:views','Behance · views',ARRAY['behance.net']),
('medium:followers:domestic','Medium · followers · domestic',ARRAY['medium.com']),
('medium:followers:international','Medium · followers · international',ARRAY['medium.com']),
('medium:claps','Medium · claps',ARRAY['medium.com']),
('medium:monthly','Medium · monthly',ARRAY['medium.com']),
('tumblr:followers:domestic','Tumblr · followers · domestic',ARRAY['tumblr.com']),
('tumblr:followers:international','Tumblr · followers · international',ARRAY['tumblr.com']),
('tumblr:likes','Tumblr · likes',ARRAY['tumblr.com']),
('tumblr:repost','Tumblr · repost',ARRAY['tumblr.com']),
('tumblr:monthly','Tumblr · monthly',ARRAY['tumblr.com']),
('github:followers:domestic','GitHub · followers · domestic',ARRAY['github.com']),
('github:followers:international','GitHub · followers · international',ARRAY['github.com']),
('github:stars','GitHub · stars',ARRAY['github.com']),
('binance:followers:domestic','Binance Square · followers · domestic',ARRAY['binance.com']),
('binance:followers:international','Binance Square · followers · international',ARRAY['binance.com']),
('binance:likes','Binance Square · likes',ARRAY['binance.com']),
('binance:views','Binance Square · views',ARRAY['binance.com']),
('quora:followers:domestic','Quora · followers · domestic',ARRAY['quora.com']),
('quora:followers:international','Quora · followers · international',ARRAY['quora.com']),
('quora:upvotes','Quora · upvotes',ARRAY['quora.com']),
('quora:monthly','Quora · monthly',ARRAY['quora.com'])
on conflict(id) do nothing;
create index if not exists seray_orders_service_id_idx on public.seray_orders(service_id);
create index if not exists seray_transactions_order_id_idx on public.seray_transactions(order_id);
create index if not exists seray_transactions_topup_id_idx on public.seray_transactions(topup_id);
commit;
