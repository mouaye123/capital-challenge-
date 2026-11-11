-- =====================================================================
-- CAPITAL CHALLENGE — 01_schema.sql
-- Base : extensions, tables, index, sécurité (RLS), portefeuille,
--        profils, trophées et réglages publics.
--
-- Ré-exécutable : `create ... if not exists`, `create or replace`,
-- `drop policy if exists`. Aucune donnée n'est supprimée.
-- À exécuter en premier, dans Supabase → SQL Editor.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Profils, portefeuille, statistiques
-- ---------------------------------------------------------------------
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text not null,
  created_at  timestamptz not null default now()
);

create unique index if not exists profiles_username_lower_idx
  on profiles (lower(username));

create table if not exists wallets (
  user_id             uuid primary key references profiles(id) on delete cascade,
  balance             int not null default 0,
  last_daily_bonus_on date,
  updated_at          timestamptz not null default now()
);

create table if not exists wallet_transactions (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles(id) on delete cascade,
  amount     int not null,
  type       text not null check (type in
               ('welcome','daily','entry','reward','mission','milestone','purchase','refund','adjust')),
  ref        text,
  meta       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists wallet_transactions_user_idx
  on wallet_transactions (user_id, created_at desc);

-- Une même référence (partie, mission, palier, achat) n'est créditée qu'une fois.
create unique index if not exists wallet_transactions_ref_idx
  on wallet_transactions (user_id, type, ref)
  where ref is not null;

create table if not exists player_stats (
  user_id         uuid primary key references profiles(id) on delete cascade,
  games_played    int not null default 0,
  games_won       int not null default 0,
  podiums         int not null default 0,
  capitals_found  int not null default 0,
  answers_total   int not null default 0,
  perfect_answers int not null default 0,
  proposals       int not null default 0,
  best_score      int not null default 0,
  total_score     int not null default 0,
  updated_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. Catalogue des pays
-- ---------------------------------------------------------------------
create table if not exists countries (
  id         smallint primary key,
  iso2       char(2) not null unique,
  name_fr    text not null,
  name_en    text not null,
  capital_fr text not null,
  capital_en text not null default '',
  note_fr    text
);

-- ---------------------------------------------------------------------
-- 3. Salles, joueurs, manches, réponses
-- ---------------------------------------------------------------------
create table if not exists rooms (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  host_id           uuid not null references profiles(id) on delete cascade,
  phase             text not null default 'waiting'
                      check (phase in ('waiting','picking','answering','revealing','finished','cancelled')),
  target_rounds     int not null default 20,
  total_rounds      int not null default 20,
  current_round     int not null default 0,
  max_players       int not null default 9,
  entry_fee         int not null default 0,
  tiebreak_blocks   int not null default 0,
  ended_by_forfeit  boolean not null default false,
  created_at        timestamptz not null default now(),
  started_at        timestamptz,
  finished_at       timestamptz,
  expires_at        timestamptz,
  phase_ends_at     timestamptz,
  updated_at        timestamptz not null default now()
);

create index if not exists rooms_phase_idx on rooms (phase);

create table if not exists room_players (
  id           bigint generated always as identity primary key,
  room_id      uuid not null references rooms(id) on delete cascade,
  user_id      uuid not null references profiles(id) on delete cascade,
  seat         int,
  score        numeric(6,1) not null default 0,
  is_ready     boolean not null default false,
  is_forfeit   boolean not null default false,
  joker_used   boolean not null default false,
  missed_turns int not null default 0,
  final_rank   int,
  reward       int not null default 0,
  last_seen_at timestamptz not null default now(),
  joined_at    timestamptz not null default now(),
  unique (room_id, user_id)
);

create index if not exists room_players_user_idx on room_players (user_id, joined_at desc);
create index if not exists room_players_room_idx on room_players (room_id, seat);

create table if not exists rounds (
  id               uuid primary key default gen_random_uuid(),
  room_id          uuid not null references rooms(id) on delete cascade,
  round_no         int not null,
  proposer_id      uuid not null references profiles(id) on delete cascade,
  country_id       smallint references countries(id),
  status           text not null default 'picking'
                     check (status in ('picking','answering','revealed')),
  auto_picked      boolean not null default false,
  found            boolean not null default false,
  correct_names    text,
  reveal_note      text,
  pick_ends_at     timestamptz,
  answer_ends_at   timestamptz,
  picked_at        timestamptz,
  revealed_at      timestamptz,
  created_at       timestamptz not null default now(),
  unique (room_id, round_no)
);

create index if not exists rounds_room_idx on rounds (room_id, round_no);

-- Capitale saisie en secret par le proposant : AUCUNE politique de
-- lecture, donc invisible via l'API. Seul le moteur (SECURITY DEFINER)
-- la lit, et uniquement si personne ne trouve.
create table if not exists round_secrets (
  round_id   uuid primary key references rounds(id) on delete cascade,
  secret     text not null,
  created_at timestamptz not null default now()
);

create table if not exists answers (
  id             bigint generated always as identity primary key,
  round_id       uuid not null references rounds(id) on delete cascade,
  user_id        uuid not null references profiles(id) on delete cascade,
  text           text not null,
  grade          text check (grade in ('perfect','typo','wrong')),
  points         numeric(4,1) not null default 0,
  joker_consumed boolean not null default false,
  elapsed_ms     int,
  created_at     timestamptz not null default now(),
  unique (round_id, user_id)
);

create index if not exists answers_round_idx on answers (round_id);
create index if not exists answers_user_idx on answers (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- 3 bis. Compatibilité avec une installation plus ancienne
--    `add column if not exists` : aucune donnée n'est perdue, et le
--    moteur trouve toujours les colonnes qu'il utilise.
-- ---------------------------------------------------------------------
alter table profiles       add column if not exists created_at timestamptz not null default now();
alter table wallets        add column if not exists last_daily_bonus_on date;
alter table wallets        add column if not exists updated_at timestamptz not null default now();

alter table countries      add column if not exists capital_fr text;
alter table countries      add column if not exists capital_en text;
alter table countries      add column if not exists note_fr text;

alter table player_stats   add column if not exists games_played int not null default 0;
alter table player_stats   add column if not exists games_won int not null default 0;
alter table player_stats   add column if not exists podiums int not null default 0;
alter table player_stats   add column if not exists capitals_found int not null default 0;
alter table player_stats   add column if not exists answers_total int not null default 0;
alter table player_stats   add column if not exists perfect_answers int not null default 0;
alter table player_stats   add column if not exists proposals int not null default 0;
alter table player_stats   add column if not exists best_score int not null default 0;
alter table player_stats   add column if not exists total_score int not null default 0;
alter table player_stats   add column if not exists updated_at timestamptz not null default now();

alter table rooms          add column if not exists phase_ends_at timestamptz;
alter table rooms          add column if not exists tiebreak_blocks int not null default 0;
alter table rooms          add column if not exists ended_by_forfeit boolean not null default false;
alter table rooms          add column if not exists expires_at timestamptz;
alter table rooms          add column if not exists started_at timestamptz;
alter table rooms          add column if not exists finished_at timestamptz;
alter table rooms          add column if not exists updated_at timestamptz not null default now();

alter table room_players   add column if not exists joker_used boolean not null default false;
alter table room_players   add column if not exists missed_turns int not null default 0;
alter table room_players   add column if not exists final_rank int;
alter table room_players   add column if not exists reward int not null default 0;
alter table room_players   add column if not exists last_seen_at timestamptz not null default now();

alter table rounds         add column if not exists status text;
alter table rounds         add column if not exists auto_picked boolean not null default false;
alter table rounds         add column if not exists found boolean not null default false;
alter table rounds         add column if not exists correct_names text;
alter table rounds         add column if not exists reveal_note text;
alter table rounds         add column if not exists picked_at timestamptz;
alter table rounds         add column if not exists revealed_at timestamptz;

-- Ancienne colonne `proposer_secret` (versions antérieures) : on la rend
-- facultative pour qu'une insertion de manche ne soit jamais bloquée.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'rounds'
      and column_name = 'proposer_secret'
  ) then
    execute 'alter table public.rounds alter column proposer_secret drop not null';
  end if;
end;
$$;

alter table answers        add column if not exists grade text;
alter table answers        add column if not exists points numeric(4,1) not null default 0;
alter table answers        add column if not exists joker_consumed boolean not null default false;
alter table answers        add column if not exists elapsed_ms int;

-- ---------------------------------------------------------------------
-- 4. Trophées (paliers)
-- ---------------------------------------------------------------------
create table if not exists milestones (
  code      text primary key,
  title     text not null,
  metric    text not null check (metric in ('games_played','podiums','games_won')),
  threshold int not null,
  reward    int not null default 0
);

create table if not exists user_milestones (
  user_id     uuid not null references profiles(id) on delete cascade,
  code        text not null references milestones(code) on delete cascade,
  achieved_at timestamptz not null default now(),
  primary key (user_id, code)
);

insert into milestones (code, title, metric, threshold, reward) values
  ('first_game',   'Première partie jouée', 'games_played',  1, 100),
  ('ten_games',    'Dix parties jouées',    'games_played', 10, 150),
  ('first_podium', 'Premier podium',        'podiums',       1, 100),
  ('first_win',    'Première victoire',     'games_won',     1, 150)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 5. Réglages du jeu (source de vérité côté serveur)
-- ---------------------------------------------------------------------
create table if not exists game_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

insert into game_config (key, value) values
  ('entry_fee',           to_jsonb(350)),
  ('reward_1',            to_jsonb(400)),
  ('reward_2',            to_jsonb(200)),
  ('reward_3',            to_jsonb(150)),
  ('welcome_bonus',       to_jsonb(2000)),
  ('daily_bonus',         to_jsonb(50)),
  ('min_players',         to_jsonb(2)),
  ('max_players',         to_jsonb(9)),
  ('pick_seconds',        to_jsonb(30)),
  ('answer_seconds',      to_jsonb(15)),
  ('reveal_seconds',      to_jsonb(8)),
  ('lobby_minutes',       to_jsonb(30)),
  ('reconnect_seconds',   to_jsonb(30)),
  ('forfeit_missed_turns',to_jsonb(2)),
  ('tiebreak_min_block',  to_jsonb(5)),
  ('tiebreak_max_blocks', to_jsonb(4)),
  ('payments_test_mode',  to_jsonb(0))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 6. Fonctions utilitaires
-- ---------------------------------------------------------------------
create or replace function server_now()
returns timestamptz
language sql
stable
as $$ select now(); $$;

-- Réglages publics : renvoie { clé: valeur } avec de vrais nombres JSON.
create or replace function get_public_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from game_config;
$$;

create or replace function cc_config_int(p_key text, p_default int)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select case when jsonb_typeof(value) = 'number' then (value #>> '{}')::numeric::int
                 else (value #>> '{}')::numeric::int end
     from game_config where key = p_key),
    p_default
  );
$$;

-- Applique un mouvement de crédits, idempotent sur (user, type, ref).
create or replace function wallet_apply(
  p_user   uuid,
  p_amount int,
  p_type   text,
  p_ref    text default null,
  p_meta   jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance int;
begin
  if p_user is null then raise exception 'Non authentifié'; end if;

  if p_ref is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('wallet:' || p_user::text || ':' || p_type || ':' || p_ref, 0)
    );
    if exists (
      select 1 from wallet_transactions
      where user_id = p_user and type = p_type and ref = p_ref
    ) then
      select balance into v_balance from wallets where user_id = p_user;
      return jsonb_build_object('ok', true, 'balance', coalesce(v_balance, 0), 'duplicate', true);
    end if;
  end if;

  insert into wallets (user_id) values (p_user) on conflict (user_id) do nothing;

  update wallets
     set balance = balance + p_amount, updated_at = now()
   where user_id = p_user
   returning balance into v_balance;

  if v_balance < 0 then
    raise exception 'Solde de crédits insuffisant';
  end if;

  insert into wallet_transactions (user_id, amount, type, ref, meta)
  values (p_user, p_amount, p_type, p_ref, coalesce(p_meta, '{}'::jsonb));

  return jsonb_build_object('ok', true, 'balance', v_balance, 'duplicate', false);
end;
$$;

create or replace function claim_daily_bonus()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_today   date := (now() at time zone 'utc')::date;
  v_bonus   int  := cc_config_int('daily_bonus', 50);
  v_last    date;
  v_balance int;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;

  select last_daily_bonus_on into v_last from wallets where user_id = v_uid for update;
  if v_last = v_today then
    select balance into v_balance from wallets where user_id = v_uid;
    return jsonb_build_object('ok', false, 'reason', 'already_claimed',
                              'balance', coalesce(v_balance, 0));
  end if;

  perform wallet_apply(v_uid, v_bonus, 'daily', 'daily:' || v_today::text,
                       jsonb_build_object('date', v_today));

  update wallets set last_daily_bonus_on = v_today, updated_at = now()
   where user_id = v_uid;

  select balance into v_balance from wallets where user_id = v_uid;
  return jsonb_build_object('ok', true, 'amount', v_bonus, 'balance', v_balance);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Création automatique du profil + portefeuille à l'inscription
-- ---------------------------------------------------------------------
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text;
  v_bonus    int := cc_config_int('welcome_bonus', 2000);
begin
  v_username := nullif(trim(coalesce(new.raw_user_meta_data->>'username', '')), '');
  if v_username is null then
    v_username := 'joueur_' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;

  begin
    insert into profiles (id, username) values (new.id, v_username);
  exception when unique_violation then
    insert into profiles (id, username)
    values (new.id, 'joueur_' || substr(replace(new.id::text, '-', ''), 1, 8))
    on conflict (id) do nothing;
  end;

  insert into wallets (user_id, balance) values (new.id, v_bonus)
  on conflict (user_id) do nothing;

  insert into wallet_transactions (user_id, amount, type, ref, meta)
  values (new.id, v_bonus, 'welcome', 'welcome:' || new.id::text,

          jsonb_build_object('reason', 'welcome'))
  on conflict do nothing;

  insert into player_stats (user_id) values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Changement de pseudo (3 à 20 caractères, unicité insensible à la casse).
create or replace function update_username(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_name text := trim(coalesce(p_username, ''));
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;

  if length(v_name) < 3 or length(v_name) > 20 then
    raise exception 'Le pseudo doit contenir entre 3 et 20 caractères';
  end if;

  if exists (
    select 1 from profiles
    where lower(username) = lower(v_name) and id <> v_uid
  ) then
    raise exception 'Ce pseudo est déjà pris';
  end if;

  update profiles set username = v_name where id = v_uid;

  return jsonb_build_object('ok', true, 'username', v_name);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Sécurité (RLS)
-- ---------------------------------------------------------------------
create or replace function is_room_member(p_room uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from room_players
    where room_id = p_room and user_id = auth.uid()
  );
$$;

alter table profiles            enable row level security;
alter table wallets             enable row level security;
alter table wallet_transactions enable row level security;
alter table player_stats        enable row level security;
alter table countries           enable row level security;
alter table rooms               enable row level security;
alter table room_players        enable row level security;
alter table rounds              enable row level security;
alter table round_secrets       enable row level security;
alter table answers             enable row level security;
alter table milestones          enable row level security;
alter table user_milestones     enable row level security;
alter table game_config         enable row level security;

-- Profils : lisibles par les joueurs connectés (pseudos des adversaires).
drop policy if exists profiles_select on profiles;
create policy profiles_select on profiles
  for select to authenticated using (true);

drop policy if exists profiles_update on profiles;
create policy profiles_update on profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists wallets_select on wallets;
create policy wallets_select on wallets
  for select to authenticated using (user_id = auth.uid());

drop policy if exists wallet_tx_select on wallet_transactions;
create policy wallet_tx_select on wallet_transactions
  for select to authenticated using (user_id = auth.uid());

drop policy if exists player_stats_select on player_stats;
create policy player_stats_select on player_stats
  for select to authenticated using (user_id = auth.uid());

drop policy if exists countries_select on countries;
create policy countries_select on countries
  for select to anon, authenticated using (true);

drop policy if exists rooms_select on rooms;
create policy rooms_select on rooms
  for select to authenticated using (is_room_member(id));

drop policy if exists room_players_select on room_players;
create policy room_players_select on room_players
  for select to authenticated using (is_room_member(room_id));

drop policy if exists rounds_select on rounds;
create policy rounds_select on rounds
  for select to authenticated using (is_room_member(room_id));

drop policy if exists answers_select on answers;
create policy answers_select on answers
  for select to authenticated using (
    exists (
      select 1 from rounds r
      where r.id = answers.round_id
        and is_room_member(r.room_id)
        -- Les réponses des autres joueurs ne sont lisibles qu'après la
        -- révélation : impossible de copier la réponse d'un adversaire.
        and r.status = 'revealed'
    )
  );

drop policy if exists milestones_select on milestones;
create policy milestones_select on milestones
  for select to authenticated using (true);

drop policy if exists user_milestones_select on user_milestones;
create policy user_milestones_select on user_milestones
  for select to authenticated using (user_id = auth.uid());

-- Aucune politique d'écriture : tout passe par des fonctions SECURITY DEFINER.

revoke all on table profiles, wallets, wallet_transactions, player_stats,
  countries, rooms, room_players, rounds, answers, milestones,
  user_milestones, game_config, round_secrets
  from anon, authenticated;

-- Pays : uniquement les colonnes publiques. Les capitales ne sont jamais
-- lisibles par le navigateur (sinon un joueur lirait la réponse via l'API).
grant select (id, iso2, name_fr, name_en) on table countries to anon, authenticated;

grant select on table profiles, wallets, wallet_transactions, player_stats,
  rooms, room_players, rounds, answers, milestones,
  user_milestones to authenticated;

-- ---------------------------------------------------------------------
-- 9. Realtime : les écrans de jeu écoutent ces tables
-- ---------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table rooms;
  exception when duplicate_object then null; when undefined_object then null;
  end;
  begin
    alter publication supabase_realtime add table room_players;
  exception when duplicate_object then null; when undefined_object then null;
  end;
  begin
    alter publication supabase_realtime add table rounds;
  exception when duplicate_object then null; when undefined_object then null;
  end;
  begin
    alter publication supabase_realtime add table answers;
  exception when duplicate_object then null; when undefined_object then null;
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Droits d'exécution des fonctions
-- ---------------------------------------------------------------------
revoke all on function server_now() from public;
revoke all on function get_public_config() from public;
revoke all on function cc_config_int(text, int) from public, anon, authenticated;
revoke all on function wallet_apply(uuid, int, text, text, jsonb) from public, anon, authenticated;
revoke all on function claim_daily_bonus() from public, anon, authenticated;
revoke all on function handle_new_user() from public, anon, authenticated;
revoke all on function is_room_member(uuid) from public, anon;
revoke all on function update_username(text) from public, anon, authenticated;

grant execute on function server_now() to anon, authenticated;
grant execute on function get_public_config() to anon, authenticated;
grant execute on function claim_daily_bonus() to authenticated;
grant execute on function is_room_member(uuid) to authenticated;
grant execute on function update_username(text) to authenticated;

notify pgrst, 'reload schema';

select
  (select count(*) from countries) as pays,
  (select count(*) from game_config) as reglages,
  (select count(*) from milestones) as trophees;
