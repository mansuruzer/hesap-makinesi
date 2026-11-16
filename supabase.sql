-- YTÜ Hesap Makinesi Bul — veritabanı kurulumu
-- Supabase > SQL Editor'e yapıştırıp Run'a bas. Sadece hm_ ile başlayan yeni tablolar/fonksiyonlar ekler.

create table if not exists public.hm_lenders (
  id uuid primary key default gen_random_uuid(),
  token uuid not null default gen_random_uuid(),
  name text not null,
  phone text not null,
  model text not null,
  programmable boolean not null default false,
  campus text not null,
  note text,
  available_until date not null,
  created_at timestamptz not null default now()
);
create table if not exists public.hm_busy (
  id bigserial primary key,
  lender_id uuid not null references public.hm_lenders(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null
);
create index if not exists hm_busy_lender_idx on public.hm_busy(lender_id);
create table if not exists public.hm_requests (
  id uuid primary key default gen_random_uuid(),
  token uuid not null default gen_random_uuid(),
  name text not null,
  phone text not null,
  campus text not null,
  model_pref text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  note text,
  status text not null default 'open',
  created_at timestamptz not null default now()
);
create table if not exists public.hm_rate (
  ip text not null,
  created_at timestamptz not null default now()
);
create index if not exists hm_rate_idx on public.hm_rate(ip, created_at);

alter table public.hm_lenders enable row level security;
alter table public.hm_busy enable row level security;
alter table public.hm_requests enable row level security;
alter table public.hm_rate enable row level security;
revoke all on public.hm_lenders, public.hm_busy, public.hm_requests, public.hm_rate from anon, authenticated;

create or replace function public.hm_norm_phone(p text) returns text
language plpgsql immutable set search_path = public as $$
declare d text := regexp_replace(coalesce(p,''), '\D', '', 'g');
begin
  if d ~ '^05\d{9}$' then d := '9' || d;
  elsif d ~ '^5\d{9}$' then d := '90' || d;
  end if;
  if d !~ '^905\d{9}$' then raise exception 'Telefon numarası geçersiz. Örnek: 532 123 45 67'; end if;
  return d;
end $$;

create or replace function public.hm_check_rate() returns void
language plpgsql security definer set search_path = public as $$
declare v_ip text; h json;
begin
  h := nullif(current_setting('request.headers', true), '')::json;
  v_ip := nullif(btrim(coalesce(h->>'cf-connecting-ip', h->>'x-real-ip', split_part(h->>'x-forwarded-for', ',', 1))), '');
  if v_ip is null then return; end if; -- IP bilinmiyorsa herkesi ortak sınıra sokma
  delete from hm_rate where created_at < now() - interval '1 day';
  if (select count(*) from hm_rate where ip = v_ip and created_at > now() - interval '1 hour') >= 15 then
    raise exception 'Çok fazla kayıt denemesi. Biraz sonra tekrar dene.';
  end if;
  insert into hm_rate(ip) values (v_ip);
end $$;

create or replace function public.hm_clean(p text, maxlen int) returns text
language sql immutable set search_path = public as $$
  select nullif(left(btrim(coalesce(p,'')), maxlen), '')
$$;

create or replace function public.hm_save_busy(p_lender uuid, p_busy jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare r jsonb; s timestamptz; e timestamptz;
begin
  delete from hm_busy where lender_id = p_lender;
  if p_busy is null or jsonb_typeof(p_busy) <> 'array' then return; end if;
  if jsonb_array_length(p_busy) > 40 then raise exception 'En fazla 40 sınav saati eklenebilir.'; end if;
  for r in select * from jsonb_array_elements(p_busy) loop
    s := (r->>'s')::timestamptz; e := (r->>'e')::timestamptz;
    if e <= s or e - s > interval '12 hours' then raise exception 'Sınav saatlerinden biri geçersiz.'; end if;
    insert into hm_busy(lender_id, starts_at, ends_at) values (p_lender, s, e);
  end loop;
end $$;

create or replace function public.hm_validate_lender(p_name text, p_model text, p_campus text, p_until date) returns void
language plpgsql stable set search_path = public as $$
begin
  if hm_clean(p_name,40) is null or length(btrim(p_name)) < 2 then raise exception 'Adını yaz.'; end if;
  if hm_clean(p_model,40) is null then raise exception 'Hesap makinesi modelini yaz.'; end if;
  if hm_clean(p_campus,40) is null then raise exception 'Kampüs seç.'; end if;
  if p_until is null or p_until < (now() at time zone 'Europe/Istanbul')::date or p_until > (now() at time zone 'Europe/Istanbul')::date + 120 then
    raise exception 'Listeleme bitiş tarihi bugünden sonra ve en fazla 4 ay ileride olmalı.';
  end if;
end $$;

create or replace function public.hm_create_lender(p_name text, p_phone text, p_model text, p_programmable boolean,
  p_campus text, p_note text, p_until date, p_busy jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare v hm_lenders;
begin
  perform hm_validate_lender(p_name, p_model, p_campus, p_until);
  perform hm_norm_phone(p_phone);
  perform hm_check_rate();
  insert into hm_lenders(name, phone, model, programmable, campus, note, available_until)
  values (hm_clean(p_name,40), hm_norm_phone(p_phone), hm_clean(p_model,40), coalesce(p_programmable,false),
          hm_clean(p_campus,40), hm_clean(p_note,200), p_until)
  returning * into v;
  perform hm_save_busy(v.id, p_busy);
  return json_build_object('id', v.id, 'token', v.token);
end $$;

create or replace function public.hm_update_lender(p_id uuid, p_token uuid, p_name text, p_phone text, p_model text,
  p_programmable boolean, p_campus text, p_note text, p_until date, p_busy jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform hm_validate_lender(p_name, p_model, p_campus, p_until);
  update hm_lenders set name = hm_clean(p_name,40), phone = hm_norm_phone(p_phone), model = hm_clean(p_model,40),
    programmable = coalesce(p_programmable,false), campus = hm_clean(p_campus,40), note = hm_clean(p_note,200),
    available_until = p_until
  where id = p_id and token = p_token;
  if not found then raise exception 'Kayıt bulunamadı.'; end if;
  perform hm_save_busy(p_id, p_busy);
  return true;
end $$;

create or replace function public.hm_get_lender(p_id uuid, p_token uuid) returns json
language sql security definer set search_path = public as $$
  select json_build_object('id', l.id, 'name', l.name, 'phone', l.phone, 'model', l.model, 'programmable', l.programmable,
    'campus', l.campus, 'note', l.note, 'available_until', l.available_until,
    'busy', coalesce((select json_agg(json_build_object('s', b.starts_at, 'e', b.ends_at) order by b.starts_at)
                      from hm_busy b where b.lender_id = l.id), '[]'::json))
  from hm_lenders l where l.id = p_id and l.token = p_token
$$;

create or replace function public.hm_delete_lender(p_id uuid, p_token uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  delete from hm_lenders where id = p_id and token = p_token;
  return found;
end $$;

create or replace function public.hm_search(p_start timestamptz, p_end timestamptz, p_campus text, p_only_basic boolean)
returns table(id uuid, name text, model text, programmable boolean, campus text, note text, same_campus boolean)
language sql security definer set search_path = public as $$
  select l.id, l.name, l.model, l.programmable, l.campus, l.note, (l.campus = p_campus) as same_campus
  from hm_lenders l
  where l.available_until >= (p_start at time zone 'Europe/Istanbul')::date
    and (not coalesce(p_only_basic,false) or l.programmable = false)
    and not exists (
      select 1 from hm_busy b where b.lender_id = l.id
        and b.starts_at < p_end + interval '30 minutes'
        and b.ends_at > p_start - interval '30 minutes')
  order by (l.campus = p_campus) desc, l.created_at desc
  limit 60
$$;

create or replace function public.hm_contact(p_kind text, p_id uuid) returns text
language sql security definer set search_path = public as $$
  select case when p_kind = 'lender' then (select phone from hm_lenders where id = p_id)
              when p_kind = 'request' then (select phone from hm_requests where id = p_id and status = 'open') end
$$;

create or replace function public.hm_create_request(p_name text, p_phone text, p_campus text, p_model_pref text,
  p_start timestamptz, p_end timestamptz, p_note text) returns json
language plpgsql security definer set search_path = public as $$
declare v hm_requests;
begin
  if hm_clean(p_name,40) is null or length(btrim(p_name)) < 2 then raise exception 'Adını yaz.'; end if;
  if hm_clean(p_campus,40) is null then raise exception 'Kampüs seç.'; end if;
  if p_end <= p_start or p_end - p_start > interval '8 hours' then raise exception 'Saat aralığı geçersiz.'; end if;
  if p_end < now() then raise exception 'Geçmiş bir saat seçilemez.'; end if;
  if p_start > now() + interval '120 days' then raise exception 'Tarih en fazla 4 ay ileride olabilir.'; end if;
  perform hm_norm_phone(p_phone);
  perform hm_check_rate();
  insert into hm_requests(name, phone, campus, model_pref, starts_at, ends_at, note)
  values (hm_clean(p_name,40), hm_norm_phone(p_phone), hm_clean(p_campus,40), hm_clean(p_model_pref,40), p_start, p_end, hm_clean(p_note,200))
  returning * into v;
  return json_build_object('id', v.id, 'token', v.token);
end $$;

create or replace function public.hm_list_requests()
returns table(id uuid, name text, campus text, model_pref text, starts_at timestamptz, ends_at timestamptz, note text)
language sql security definer set search_path = public as $$
  select id, name, campus, model_pref, starts_at, ends_at, note from hm_requests
  where status = 'open' and ends_at > now()
  order by starts_at limit 100
$$;

create or replace function public.hm_close_request(p_id uuid, p_token uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update hm_requests set status = 'closed' where id = p_id and token = p_token;
  return found;
end $$;

create or replace function public.hm_stats() returns json
language sql security definer set search_path = public as $$
  select json_build_object(
    'lenders', (select count(*) from hm_lenders where available_until >= (now() at time zone 'Europe/Istanbul')::date),
    'requests', (select count(*) from hm_requests where status = 'open' and ends_at > now()))
$$;

revoke all on function public.hm_norm_phone(text), public.hm_check_rate(), public.hm_clean(text,int),
  public.hm_save_busy(uuid,jsonb), public.hm_validate_lender(text,text,text,date) from public, anon, authenticated;
revoke all on function public.hm_create_lender(text,text,text,boolean,text,text,date,jsonb),
  public.hm_update_lender(uuid,uuid,text,text,text,boolean,text,text,date,jsonb),
  public.hm_get_lender(uuid,uuid), public.hm_delete_lender(uuid,uuid),
  public.hm_search(timestamptz,timestamptz,text,boolean), public.hm_contact(text,uuid),
  public.hm_create_request(text,text,text,text,timestamptz,timestamptz,text),
  public.hm_list_requests(), public.hm_close_request(uuid,uuid), public.hm_stats() from public;
grant execute on function public.hm_create_lender(text,text,text,boolean,text,text,date,jsonb),
  public.hm_update_lender(uuid,uuid,text,text,text,boolean,text,text,date,jsonb),
  public.hm_get_lender(uuid,uuid), public.hm_delete_lender(uuid,uuid),
  public.hm_search(timestamptz,timestamptz,text,boolean), public.hm_contact(text,uuid),
  public.hm_create_request(text,text,text,text,timestamptz,timestamptz,text),
  public.hm_list_requests(), public.hm_close_request(uuid,uuid), public.hm_stats() to anon, authenticated;
