-- =====================================================================
-- CAPITAL CHALLENGE — 01_schema.sql
-- Base : extensions, tables, index, sécurité (RLS), portefeuille,
--        profils, trophées et réglages publics.
--
-- Écrit pour être relancé SUR UNE BASE EXISTANTE, même si celle-ci a été
-- créée par une version antérieure :
--   • `create table if not exists` ne touche pas aux tables existantes ;
--   • une section « compatibilité » ajoute les colonnes manquantes
--     (`add column if not exists`) AVANT de créer index et politiques ;
--   • les contraintes CHECK trop strictes sont assouplies ;
--   • aucune table, aucune ligne n'est supprimée.
-- À exécuter en premier, dans Supabase → SQL Editor.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 0. Remise à plat des fonctions
--    Une ancienne version a pu définir ces fonctions avec un autre type
--    de retour : `create or replace` refuserait alors de s'exécuter.
--    On les supprime donc d'abord (aucune donnée n'est touchée), puis on
--    les recrée plus bas. Les politiques RLS qui en dépendent sont
--    recréées dans la section 10.
-- ---------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (array[
        'server_now', 'get_public_config', 'cc_config_int', 'wallet_apply',
        'claim_daily_bonus', 'update_username', 'is_room_member', 'handle_new_user'
      ])
  loop
    begin
      execute format('drop function %s cascade', f.sig);
    exception when others then
      raise notice 'Fonction % non supprimée : %', f.sig, sqlerrm;
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text not null,
  created_at  timestamptz not null default now()
);

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
  type       text not null,
  ref        text,
  meta       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

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

create table if not exists countries (
  id         smallint primary key,
  iso2       char(2) not null,
  name_fr    text not null,
  name_en    text not null,
  capital_fr text,
  capital_en text,
  note_fr    text
);

create table if not exists rooms (
  id                uuid primary key default gen_random_uuid(),
  code              text not null,
  host_id           uuid not null references profiles(id) on delete cascade,
  phase             text not null default 'waiting',
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

create table if not exists rounds (
  id               uuid primary key default gen_random_uuid(),
  room_id          uuid not null references rooms(id) on delete cascade,
  round_no         int not null,
  proposer_id      uuid not null references profiles(id) on delete cascade,
  country_id       smallint references countries(id),
  status           text not null default 'picking',
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
  grade          text,
  points         numeric(4,1) not null default 0,
  joker_consumed boolean not null default false,
  elapsed_ms     int,
  created_at     timestamptz not null default now(),
  unique (round_id, user_id)
);

create table if not exists milestones (
  code      text primary key,
  title     text not null,
  metric    text not null,
  threshold int not null,
  reward    int not null default 0
);

-- Pas de clé étrangère inline ici : elle est ajoutée plus bas, seulement
-- si la table `milestones` possède bien une unicité sur `code`.
create table if not exists user_milestones (
  user_id     uuid not null references profiles(id) on delete cascade,
  code        text not null,
  achieved_at timestamptz not null default now(),
  primary key (user_id, code)
);

create table if not exists game_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. Compatibilité avec une installation plus ancienne
--    Toutes les colonnes utilisées par le moteur et le frontend sont
--    ajoutées si elles manquent. Aucune donnée n'est perdue.
-- ---------------------------------------------------------------------
alter table profiles            add column if not exists created_at timestamptz default now();

alter table wallets             add column if not exists balance int default 0;
alter table wallets             add column if not exists last_daily_bonus_on date;
alter table wallets             add column if not exists updated_at timestamptz default now();

alter table wallet_transactions add column if not exists ref text;
alter table wallet_transactions add column if not exists meta jsonb default '{}'::jsonb;
alter table wallet_transactions add column if not exists created_at timestamptz default now();

alter table player_stats        add column if not exists games_played int default 0;
alter table player_stats        add column if not exists games_won int default 0;
alter table player_stats        add column if not exists podiums int default 0;
alter table player_stats        add column if not exists capitals_found int default 0;
alter table player_stats        add column if not exists answers_total int default 0;
alter table player_stats        add column if not exists perfect_answers int default 0;
alter table player_stats        add column if not exists proposals int default 0;
alter table player_stats        add column if not exists best_score int default 0;
alter table player_stats        add column if not exists total_score int default 0;
alter table player_stats        add column if not exists updated_at timestamptz default now();

alter table countries          add column if not exists capital_fr text;
alter table countries          add column if not exists capital_en text;
alter table countries          add column if not exists note_fr text;

alter table rooms              add column if not exists phase text default 'waiting';
alter table rooms              add column if not exists target_rounds int default 20;
alter table rooms              add column if not exists total_rounds int default 20;
alter table rooms              add column if not exists current_round int default 0;
alter table rooms              add column if not exists max_players int default 9;
alter table rooms              add column if not exists entry_fee int default 0;
alter table rooms              add column if not exists tiebreak_blocks int default 0;
alter table rooms              add column if not exists ended_by_forfeit boolean default false;
alter table rooms              add column if not exists created_at timestamptz default now();
alter table rooms              add column if not exists started_at timestamptz;
alter table rooms              add column if not exists finished_at timestamptz;
alter table rooms              add column if not exists expires_at timestamptz;
alter table rooms              add column if not exists phase_ends_at timestamptz;
alter table rooms              add column if not exists updated_at timestamptz default now();

alter table room_players       add column if not exists seat int;
alter table room_players       add column if not exists score numeric(6,1) default 0;
alter table room_players       add column if not exists is_ready boolean default false;
alter table room_players       add column if not exists is_forfeit boolean default false;
alter table room_players       add column if not exists joker_used boolean default false;
alter table room_players       add column if not exists missed_turns int default 0;
alter table room_players       add column if not exists final_rank int;
alter table room_players       add column if not exists reward int default 0;
alter table room_players       add column if not exists last_seen_at timestamptz default now();
alter table room_players       add column if not exists joined_at timestamptz default now();

alter table rounds             add column if not exists status text default 'picking';
alter table rounds             add column if not exists auto_picked boolean default false;
alter table rounds             add column if not exists found boolean default false;
alter table rounds             add column if not exists correct_names text;
alter table rounds             add column if not exists reveal_note text;
alter table rounds             add column if not exists pick_ends_at timestamptz;
alter table rounds             add column if not exists answer_ends_at timestamptz;
alter table rounds             add column if not exists picked_at timestamptz;
alter table rounds             add column if not exists revealed_at timestamptz;
alter table rounds             add column if not exists created_at timestamptz default now();

alter table answers            add column if not exists grade text;
alter table answers            add column if not exists points numeric(4,1) default 0;
alter table answers            add column if not exists joker_consumed boolean default false;
alter table answers            add column if not exists elapsed_ms int;
alter table answers            add column if not exists created_at timestamptz default now();

alter table milestones         add column if not exists title text;
alter table milestones         add column if not exists metric text;
alter table milestones         add column if not exists threshold int;
alter table milestones         add column if not exists reward int default 0;

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

-- ---------------------------------------------------------------------
-- 3. Assouplissement des contraintes héritées
--    Une ancienne version pouvait interdire les valeurs utilisées par le
--    nouveau moteur ('typo', 'mission', 'cancelled'…). On remplace ces
--    CHECK par des versions permissives, non revalidées sur l'historique.
-- ---------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select c.conrelid::regclass::text as tbl, c.conname
    from pg_constraint c
    where c.contype = 'c'
      and c.conrelid in (
        'public.wallet_transactions'::regclass,
        'public.rooms'::regclass,
        'public.rounds'::regclass,
        'public.answers'::regclass
      )
      and (
        pg_get_constraintdef(c.oid) ilike '%type%'
        or pg_get_constraintdef(c.oid) ilike '%phase%'
        or pg_get_constraintdef(c.oid) ilike '%status%'
        or pg_get_constraintdef(c.oid) ilike '%grade%'
      )
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
  end loop;
end;
$$;

alter table wallet_transactions drop constraint if exists wallet_transactions_type_check;
alter table wallet_transactions add constraint wallet_transactions_type_check
  check (type in ('welcome','daily','entry','reward','mission','milestone','purchase','refund','adjust'))
  not valid;

alter table rooms drop constraint if exists rooms_phase_check;
alter table rooms add constraint rooms_phase_check
  check (phase in ('waiting','picking','answering','revealing','finished','cancelled'))
  not valid;

alter table rounds drop constraint if exists rounds_status_check;
alter table rounds add constraint rounds_status_check
  check (status in ('picking','answering','revealed'))
  not valid;

alter table answers drop constraint if exists answers_grade_check;
alter table answers add constraint answers_grade_check
  check (grade is null or grade in ('perfect','typo','wrong'))
  not valid;

-- ---------------------------------------------------------------------
-- 4. Colonnes historiques devenues obligatoires mais jamais remplies
--    On commence par reposer les valeurs par défaut attendues par le
--    moteur : sans elles, un INSERT partiel laisserait des NULL et
--    casserait les calculs de score.
-- ---------------------------------------------------------------------
alter table wallets             alter column balance set default 0;
alter table wallets             alter column updated_at set default now();
alter table wallet_transactions alter column meta set default '{}'::jsonb;
alter table wallet_transactions alter column created_at set default now();

alter table player_stats alter column games_played set default 0;
alter table player_stats alter column games_won set default 0;
alter table player_stats alter column podiums set default 0;
alter table player_stats alter column capitals_found set default 0;
alter table player_stats alter column answers_total set default 0;
alter table player_stats alter column perfect_answers set default 0;
alter table player_stats alter column proposals set default 0;
alter table player_stats alter column best_score set default 0;
alter table player_stats alter column total_score set default 0;
alter table player_stats alter column updated_at set default now();

alter table rooms alter column phase set default 'waiting';
alter table rooms alter column target_rounds set default 20;
alter table rooms alter column total_rounds set default 20;
alter table rooms alter column current_round set default 0;
alter table rooms alter column max_players set default 9;
alter table rooms alter column entry_fee set default 0;
alter table rooms alter column tiebreak_blocks set default 0;
alter table rooms alter column ended_by_forfeit set default false;
alter table rooms alter column created_at set default now();
alter table rooms alter column updated_at set default now();

alter table room_players alter column score set default 0;
alter table room_players alter column is_ready set default false;
alter table room_players alter column is_forfeit set default false;
alter table room_players alter column joker_used set default false;
alter table room_players alter column missed_turns set default 0;
alter table room_players alter column reward set default 0;
alter table room_players alter column last_seen_at set default now();
alter table room_players alter column joined_at set default now();

alter table rounds alter column status set default 'picking';
alter table rounds alter column auto_picked set default false;
alter table rounds alter column found set default false;
alter table rounds alter column created_at set default now();

alter table answers alter column points set default 0;
alter table answers alter column joker_consumed set default false;
alter table answers alter column created_at set default now();

do $$
declare
  t record;
  r record;
begin
  for t in
    select * from (values
      ('profiles',            'id,username,created_at'),
      ('wallets',             'user_id,balance,last_daily_bonus_on,updated_at'),
      ('wallet_transactions', 'id,user_id,amount,type,ref,meta,created_at'),
      ('player_stats',        'user_id,games_played,games_won,podiums,capitals_found,answers_total,perfect_answers,proposals,best_score,total_score,updated_at'),
      ('countries',           'id,iso2,name_fr,name_en,capital_fr,capital_en,note_fr'),
      ('rooms',               'id,code,host_id,phase,target_rounds,total_rounds,current_round,max_players,entry_fee,created_at'),
      ('room_players',        'id,room_id,user_id,seat,is_ready,joined_at'),
      ('rounds',              'id,room_id,round_no,proposer_id,status,pick_ends_at,created_at'),
      ('answers',             'id,round_id,user_id,text,elapsed_ms,created_at'),
      ('milestones',          'code,title,metric,threshold,reward'),
      ('game_config',         'key,value')
    ) as v(tbl, keep)
  loop
    for r in
      select c.column_name
      from information_schema.columns c
      where c.table_schema = 'public'
        and c.table_name = t.tbl
        and c.is_nullable = 'NO'
        and c.column_default is null
        and c.column_name <> all (string_to_array(t.keep, ','))
    loop
      execute format('alter table public.%I alter column %I drop not null', t.tbl, r.column_name);
    end loop;
  end loop;
end;
$$;

-- Données historiques incohérentes (solde NULL) : remises à zéro.
update wallets set balance = 0 where balance is null;

-- ---------------------------------------------------------------------
-- 5. Index
-- ---------------------------------------------------------------------
do $$
begin
  begin
    create unique index if not exists profiles_username_lower_idx
      on profiles (lower(username));
  exception when unique_violation then
    raise notice 'Pseudos en double : index unique non créé (unicité vérifiée à la saisie).';
    execute 'create index if not exists profiles_username_lower_soft_idx on profiles (lower(username))';
  end;
end;
$$;

create index if not exists wallet_transactions_user_idx
  on wallet_transactions (user_id, created_at desc);

-- Une même référence (partie, mission, palier, achat) n'est créditée qu'une fois.
create unique index if not exists wallet_transactions_ref_idx
  on wallet_transactions (user_id, type, ref)
  where ref is not null;

do $$
begin
  begin
    create unique index if not exists rooms_code_key on rooms (code);
  exception when unique_violation then
    raise notice 'Codes de salle en double : index unique non créé.';
  end;

  begin
    create unique index if not exists milestones_code_key on milestones (code);
  exception when unique_violation then
    raise notice 'Codes de trophées en double : index unique non créé.';
  end;
end;
$$;

create index if not exists rooms_phase_idx on rooms (phase);
create index if not exists room_players_user_idx on room_players (user_id, joined_at desc);
create index if not exists room_players_room_idx on room_players (room_id, seat);
create index if not exists rounds_room_idx on rounds (room_id, round_no);
create index if not exists answers_round_idx on answers (round_id);
create index if not exists answers_user_idx on answers (user_id, created_at desc);

-- Clé étrangère des trophées : nécessaire pour que l'API puisse joindre
-- `user_milestones` et `milestones` (mur de trophées du profil).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where contype = 'f'
      and conrelid = 'public.user_milestones'::regclass
      and confrelid = 'public.milestones'::regclass
  ) then
    begin
      alter table user_milestones
        add constraint user_milestones_code_fkey
        foreign key (code) references milestones(code) on delete cascade;
    exception when others then
      raise notice 'Clé étrangère des trophées non ajoutée : %', sqlerrm;
    end;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Trophées (paliers)
-- ---------------------------------------------------------------------
do $$
begin
  insert into milestones (code, title, metric, threshold, reward)
  select v.code, v.title, v.metric, v.threshold, v.reward
  from (values
    ('first_game',   'Première partie jouée', 'games_played',  1, 100),
    ('ten_games',    'Dix parties jouées',    'games_played', 10, 150),
    ('first_podium', 'Premier podium',        'podiums',       1, 100),
    ('first_win',    'Première victoire',     'games_won',     1, 150)
  ) as v(code, title, metric, threshold, reward)
  where not exists (select 1 from milestones m where m.code = v.code);
exception when others then
  raise notice 'Trophées non initialisés : %', sqlerrm;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Réglages du jeu (source de vérité côté serveur)
-- ---------------------------------------------------------------------
do $$
begin
  insert into game_config (key, value)
  select v.key, v.val::jsonb
  from (values
    ('entry_fee',            '350'),
    ('reward_1',             '400'),
    ('reward_2',             '200'),
    ('reward_3',             '150'),
    ('welcome_bonus',        '2000'),
    ('daily_bonus',          '50'),
    ('min_players',          '2'),
    ('max_players',          '9'),
    ('pick_seconds',         '30'),
    ('answer_seconds',       '15'),
    ('reveal_seconds',       '8'),
    ('lobby_minutes',        '30'),
    ('reconnect_seconds',    '30'),
    ('forfeit_missed_turns', '2'),
    ('tiebreak_min_block',   '5'),
    ('tiebreak_max_blocks',  '4'),
    ('payments_test_mode',   '0')
  ) as v(key, val)
  where not exists (select 1 from game_config g where g.key = v.key);
exception when others then
  raise notice 'Réglages non initialisés (colonne value non jsonb ?) : %', sqlerrm;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Fonctions utilitaires
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
    (select (value #>> '{}')::numeric::int from game_config where key = p_key),
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
     set balance = coalesce(balance, 0) + p_amount, updated_at = now()
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
-- 9. Création automatique du profil + portefeuille à l'inscription
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
-- 10. Sécurité (RLS)
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
-- 11. Realtime : les écrans de jeu écoutent ces tables
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
-- 12. Droits d'exécution des fonctions
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
