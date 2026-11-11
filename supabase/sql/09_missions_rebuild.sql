select 'Correctif missions — début' as etape;

-- =====================================================================
-- CAPITAL CHALLENGE — 09_missions_rebuild.sql
-- Reconstruction propre des tables de missions, puis test réel.
--
-- À exécuter APRÈS 05_missions.sql / 07_correctif.sql.
-- Les anciennes tables sont d'abord sauvegardées :
--   zz_mission_templates_backup_...  et  zz_user_missions_backup_...
-- Aucune autre donnée n'est touchée (portefeuille, profils, parties…).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Sauvegarde et suppression des anciennes tables de missions
-- ---------------------------------------------------------------------
do $$
declare
  v_s text := to_char(now(), 'YYYYMMDD_HH24MISS');
begin
  if to_regclass('public.user_missions') is not null then
    begin
      execute format(
        'create table if not exists public.%I as select * from public.user_missions',
        'zz_user_missions_backup_' || v_s
      );
    exception when others then
      raise notice 'Sauvegarde user_missions impossible : %', sqlerrm;
    end;
  end if;

  if to_regclass('public.mission_templates') is not null then
    begin
      execute format(
        'create table if not exists public.%I as select * from public.mission_templates',
        'zz_mission_templates_backup_' || v_s
      );
    exception when others then
      raise notice 'Sauvegarde mission_templates impossible : %', sqlerrm;
    end;
  end if;

  execute 'drop table if exists public.user_missions cascade';
  execute 'drop table if exists public.mission_templates cascade';
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Tables neuves, structure exacte attendue par le moteur
-- ---------------------------------------------------------------------
create table public.mission_templates (
  id          smallint generated always as identity primary key,
  code        text not null unique,
  title       text not null,
  description text not null,
  difficulty  text not null,
  metric      text not null,
  target_min  int not null,
  target_max  int not null,
  reward      int not null
);

create table public.user_missions (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  mission_date date not null,
  template_id  smallint not null references public.mission_templates(id),
  target       int not null,
  progress     int not null default 0,
  completed    boolean not null default false,
  completed_at timestamptz,
  unique (user_id, mission_date, template_id)
);

-- ---------------------------------------------------------------------
-- 3. Catalogue : 4 faciles, 4 moyennes, 2 difficiles, 2 très difficiles
-- ---------------------------------------------------------------------
insert into public.mission_templates
  (code, title, description, difficulty, metric, target_min, target_max, reward)
values
  ('easy_game',    'Première partie',      'Terminer une partie.',          'facile',        'games_finished',  1,  1,  25),
  ('easy_find',    'Chasse aux capitales', 'Trouver 2 capitales.',          'facile',        'capitals_found',  2,  2,  25),
  ('easy_answer',  'Entrée en jeu',        'Répondre à 3 défis.',           'facile',        'answers_total',   3,  3,  25),
  ('easy_propose', 'Prends les commandes', 'Proposer 1 pays.',              'facile',        'proposals',       1,  1,  25),
  ('med_games',    'Habitué des salles',   'Terminer 2 parties.',           'moyenne',       'games_finished',  2,  2,  50),
  ('med_find',     'Explorateur',          'Trouver 5 capitales.',          'moyenne',       'capitals_found',  5,  5,  50),
  ('med_answers',  'Joueur actif',         'Répondre à 8 défis.',           'moyenne',       'answers_total',   8,  8,  50),
  ('med_perfect',  'Sans faute',           'Donner 3 réponses parfaites.',  'moyenne',       'perfect_answers', 3,  3,  50),
  ('hard_games',   'Marathonien',          'Terminer 3 parties.',           'difficile',     'games_finished',  3,  3,  75),
  ('hard_find',    'Cartographe',          'Trouver 10 capitales.',         'difficile',     'capitals_found', 10, 10,  75),
  ('vhard_wins',   'Invaincu',             'Gagner 2 parties.',             'tres_difficile','games_won',       2,  2, 100),
  ('vhard_perfect','Mémoire infaillible',  'Donner 8 réponses parfaites.',  'tres_difficile','perfect_answers', 8,  8, 100);

-- ---------------------------------------------------------------------
-- 4. Sécurité et droits
-- ---------------------------------------------------------------------
alter table public.mission_templates enable row level security;
alter table public.user_missions     enable row level security;

drop policy if exists mission_templates_select on public.mission_templates;
create policy mission_templates_select on public.mission_templates
  for select to authenticated using (true);

drop policy if exists user_missions_select on public.user_missions;
create policy user_missions_select on public.user_missions
  for select to authenticated using (user_id = auth.uid());

revoke all on table public.mission_templates, public.user_missions from anon, authenticated;
grant select on table public.mission_templates, public.user_missions to authenticated;

-- ---------------------------------------------------------------------
-- 5. Profils manquants (un compte sans profil ne peut pas avoir de
--    missions : clé étrangère user_missions.user_id → profiles.id)
-- ---------------------------------------------------------------------
insert into public.profiles (id, username)
select u.id, 'joueur_' || substr(replace(u.id::text, '-', ''), 1, 8)
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 6. Test réel : on génère les missions de vrais comptes
-- ---------------------------------------------------------------------
drop table if exists _cc_test;

create temp table _cc_test (k text, v text);

insert into _cc_test values
  ('fonction_get', case when to_regproc('public.get_daily_missions') is null
                        then 'ABSENTE' else 'présente' end),
  ('fonction_ensure', case when to_regproc('public.ensure_daily_missions') is null
                           then 'ABSENTE' else 'présente' end),
  ('fonction_wallet', case when to_regproc('public.wallet_apply') is null
                           then 'ABSENTE' else 'présente' end);

do $$
declare
  r          record;
  v_today    date := (now() at time zone 'utc')::date;
  v_n        int;
  v_ok       int := 0;
  v_ko       int := 0;
  v_erreur   text;
begin
  if to_regproc('public.ensure_daily_missions') is null then
    insert into _cc_test values ('test', 'impossible : fonction ensure_daily_missions absente');
    return;
  end if;

  for r in select id from public.profiles order by created_at nulls last limit 50 loop
    begin
      perform public.ensure_daily_missions(r.id);

      select count(*) into v_n
      from public.user_missions
      where user_id = r.id and mission_date = v_today;

      if v_n >= 3 then
        v_ok := v_ok + 1;
      else
        v_ko := v_ko + 1;
        v_erreur := coalesce(v_erreur,
          'compte ' || r.id || ' : seulement ' || v_n || ' mission(s)');
      end if;
    exception when others then
      v_ko := v_ko + 1;
      v_erreur := coalesce(v_erreur, 'compte ' || r.id || ' : ' || sqlerrm);
    end;
  end loop;

  insert into _cc_test values ('comptes_ok', v_ok::text);
  insert into _cc_test values ('comptes_ko', v_ko::text);
  insert into _cc_test values ('erreur', coalesce(v_erreur, 'aucune'));
end;
$$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 7. Résultat
-- ---------------------------------------------------------------------
select
  (select count(*) from public.mission_templates)                                  as modeles,
  (select count(*) from public.mission_templates where difficulty = 'facile')      as faciles,
  (select count(*) from public.mission_templates where difficulty = 'moyenne')     as moyennes,
  (select count(*) from public.mission_templates
    where difficulty in ('difficile','tres_difficile'))                            as difficiles,
  (select count(*) from public.user_missions
    where mission_date = (now() at time zone 'utc')::date)                         as missions_du_jour,
  (select count(*) from public.profiles)                                           as profils,
  (select jsonb_object_agg(k, v) from _cc_test)                                    as controles;
