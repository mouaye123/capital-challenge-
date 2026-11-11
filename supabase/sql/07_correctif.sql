-- =====================================================================
-- CAPITAL CHALLENGE — 07_correctif.sql
-- Correctif unique, autonome et ré-exécutable.
--
--   1. Catalogue des 12 missions + moteur (répare la page Missions vide)
--   2. Profils manquants (cause possible de l'échec des missions)
--   3. Chrono de réponse ramené à 15 secondes
--   4. Achats de crédits fermés (aucune recharge possible)
--   5. Rechargement du cache API + diagnostic final
--
-- À exécuter dans Supabase → SQL Editor, après 01 à 06.
-- Le script ne supprime aucune donnée : il complète et remplace des
-- fonctions, jamais des tables ou des lignes existantes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Structure minimale des missions (no-op si déjà installée)
-- ---------------------------------------------------------------------
create table if not exists mission_templates (
  id          smallint generated always as identity primary key,
  code        text not null unique,
  title       text not null,
  description text not null,
  difficulty  text not null check (difficulty in ('facile','moyenne','difficile','tres_difficile')),
  metric      text not null check (metric in
                ('games_finished','capitals_found','perfect_answers','answers_total','proposals','games_won','podiums')),
  target_min  int not null,
  target_max  int not null,
  reward      int not null
);

create table if not exists user_missions (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references profiles(id) on delete cascade,
  mission_date date not null,
  template_id smallint not null references mission_templates(id),
  target      int not null,
  progress    int not null default 0,
  completed   boolean not null default false,
  completed_at timestamptz,
  unique (user_id, mission_date, template_id)
);

-- Index, RLS et droits : chaque bloc tolère une structure déjà différente.
do $$
begin
  begin
    create index if not exists user_missions_user_date_idx
      on user_missions (user_id, mission_date);
  exception when others then
    raise notice 'Index missions non créé : %', sqlerrm;
  end;

  begin
    alter table mission_templates enable row level security;
    alter table user_missions     enable row level security;

    drop policy if exists mission_templates_select on mission_templates;
    create policy mission_templates_select on mission_templates
      for select to authenticated using (true);

    drop policy if exists user_missions_select on user_missions;
    create policy user_missions_select on user_missions
      for select to authenticated using (user_id = auth.uid());
  exception when others then
    raise notice 'Sécurité des missions non appliquée : %', sqlerrm;
  end;

  begin
    revoke all on table mission_templates, user_missions from anon;
    grant select on table mission_templates, user_missions to authenticated;
  exception when others then
    raise notice 'Droits missions non appliqués : %', sqlerrm;
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Catalogue des missions : 4 faciles, 4 moyennes, 2 difficiles,
--    2 très difficiles. `on conflict (code) do nothing` protège l'existant.
-- ---------------------------------------------------------------------
do $$
begin
  insert into mission_templates (code, title, description, difficulty, metric, target_min, target_max, reward) values
    ('easy_game',    'Première partie',        'Terminer une partie.',                         'facile',        'games_finished', 1, 1, 25),
    ('easy_find',    'Chasse aux capitales',   'Trouver 2 capitales.',                         'facile',        'capitals_found', 2, 2, 25),
    ('easy_answer',  'Entrée en jeu',          'Répondre à 3 défis.',                          'facile',        'answers_total',  3, 3, 25),
    ('easy_propose', 'Prends les commandes',   'Proposer 1 pays.',                             'facile',        'proposals',      1, 1, 25),
    ('med_games',    'Habitué des salles',     'Terminer 2 parties.',                          'moyenne',       'games_finished', 2, 2, 50),
    ('med_find',     'Explorateur',            'Trouver 5 capitales.',                         'moyenne',       'capitals_found', 5, 5, 50),
    ('med_answers',  'Joueur actif',           'Répondre à 8 défis.',                          'moyenne',       'answers_total',  8, 8, 50),
    ('med_perfect',  'Sans faute',             'Donner 3 réponses parfaites.',                 'moyenne',       'perfect_answers',3, 3, 50),
    ('hard_games',   'Marathonien',            'Terminer 3 parties.',                          'difficile',     'games_finished', 3, 3, 75),
    ('hard_find',    'Cartographe',            'Trouver 10 capitales.',                        'difficile',     'capitals_found',10,10, 75),
    ('vhard_wins',   'Invaincu',               'Gagner 2 parties.',                            'tres_difficile','games_won',      2, 2,100),
    ('vhard_perfect','Mémoire infaillible',    'Donner 8 réponses parfaites.',                 'tres_difficile','perfect_answers',8, 8,100)
  on conflict (code) do nothing;
exception when others then
  raise notice 'Catalogue de missions non inséré : %', sqlerrm;
end;
$$;

-- Paliers (trophées) : sans effet s'ils existent déjà.
do $$
begin
  if to_regclass('public.milestones') is not null then
    insert into milestones (code, title, metric, threshold, reward) values
      ('first_game',  'Première partie jouée',  'games_played',  1, 100),
      ('ten_games',   'Dix parties jouées',     'games_played', 10, 150),
      ('first_podium','Premier podium',         'podiums',       1, 100),
      ('first_win',   'Première victoire',      'games_won',     1, 150)
    on conflict (code) do nothing;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Profils manquants
--    Un compte créé avant l'installation du trigger n'a pas de ligne
--    `profiles` : les missions échouent alors sur la clé étrangère.
--    On répare uniquement les profils absents, sans toucher aux autres.
-- ---------------------------------------------------------------------
do $$
declare
  r          record;
  v_username text;
begin
  for r in
    select u.id
    from auth.users u
    left join public.profiles p on p.id = u.id
    where p.id is null
  loop
    v_username := 'joueur_' || substr(replace(r.id::text, '-', ''), 1, 8);
    begin
      insert into public.profiles (id, username) values (r.id, v_username);
      raise notice 'Profil créé pour %', r.id;
    exception when others then
      raise notice 'Profil % non créé (%) : %', r.id, v_username, sqlerrm;
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Moteur des missions (version qui complète les groupes manquants
--    et qui signale explicitement un catalogue vide ou un profil absent)
-- ---------------------------------------------------------------------
create or replace function ensure_daily_missions(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_have  int;
begin
  perform pg_advisory_xact_lock(
    hashtextextended('missions:' || p_user::text || ':' || v_today::text, 0)
  );

  select count(*) into v_have
  from user_missions
  where user_id = p_user and mission_date = v_today;

  if v_have >= 3 then
    return;
  end if;

  if not exists (select 1 from mission_templates) then
    raise exception 'Catalogue de missions vide : exécutez la section 2 de 07_correctif.sql';
  end if;
  if not exists (select 1 from mission_templates where difficulty = 'facile')
     or not exists (select 1 from mission_templates where difficulty = 'moyenne')
     or not exists (select 1 from mission_templates where difficulty in ('difficile','tres_difficile')) then
    raise exception 'Catalogue de missions incomplet : il faut un modèle facile, un moyen et un difficile/très difficile';
  end if;

  if not exists (select 1 from profiles where id = p_user) then
    raise exception 'Profil joueur introuvable (%) : exécutez la section 3 de 07_correctif.sql', p_user;
  end if;

  insert into user_missions (user_id, mission_date, template_id, target)
  select p_user, v_today, t.id,
         t.target_min + floor(random() * (t.target_max - t.target_min + 1))::int
  from mission_templates t
  where t.difficulty = 'facile'
    and not exists (
      select 1 from user_missions um
      join mission_templates mt on mt.id = um.template_id
      where um.user_id = p_user and um.mission_date = v_today and mt.difficulty = 'facile'
    )
  order by random() limit 1
  on conflict do nothing;

  insert into user_missions (user_id, mission_date, template_id, target)
  select p_user, v_today, t.id,
         t.target_min + floor(random() * (t.target_max - t.target_min + 1))::int
  from mission_templates t
  where t.difficulty = 'moyenne'
    and not exists (
      select 1 from user_missions um
      join mission_templates mt on mt.id = um.template_id
      where um.user_id = p_user and um.mission_date = v_today and mt.difficulty = 'moyenne'
    )
  order by random() limit 1
  on conflict do nothing;

  insert into user_missions (user_id, mission_date, template_id, target)
  select p_user, v_today, t.id,
         t.target_min + floor(random() * (t.target_max - t.target_min + 1))::int
  from mission_templates t
  where t.difficulty in ('difficile','tres_difficile')
    and not exists (
      select 1 from user_missions um
      join mission_templates mt on mt.id = um.template_id
      where um.user_id = p_user and um.mission_date = v_today
        and mt.difficulty in ('difficile','tres_difficile')
    )
  order by random() limit 1
  on conflict do nothing;
end;
$$;

create or replace function get_daily_missions()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;

  perform ensure_daily_missions(v_uid);

  return (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', um.id,
          'code', t.code,
          'title', t.title,
          'description', t.description,
          'difficulty', t.difficulty,
          'reward', t.reward,
          'target', um.target,
          'progress', least(um.progress, um.target),
          'completed', um.completed
        )
        order by t.reward, t.title
      ),
      '[]'::jsonb
    )
    from user_missions um
    join mission_templates t on t.id = um.template_id
    where um.user_id = v_uid and um.mission_date = v_today
  );
end;
$$;

create or replace function progress_daily_missions(
  p_user       uuid,
  p_games      int,
  p_found      int,
  p_perfect    int,
  p_answers    int,
  p_proposals  int,
  p_wins       int,
  p_podiums    int
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_m     record;
begin
  perform ensure_daily_missions(p_user);

  update user_missions um
     set progress = least(um.target, um.progress + case t.metric
        when 'games_finished'  then p_games
        when 'capitals_found'  then p_found
        when 'perfect_answers' then p_perfect
        when 'answers_total'   then p_answers
        when 'proposals'       then p_proposals
        when 'games_won'       then p_wins
        when 'podiums'         then p_podiums
        else 0 end)
    from mission_templates t
   where um.template_id = t.id
     and um.user_id = p_user
     and um.mission_date = v_today
     and not um.completed;

  update user_missions um
     set completed = true,
         completed_at = now()
   where um.user_id = p_user
     and um.mission_date = v_today
     and not um.completed
     and um.progress >= um.target;

  for v_m in
    select um.id, t.reward
    from user_missions um
    join mission_templates t on t.id = um.template_id
    where um.user_id = p_user
      and um.mission_date = v_today
      and um.completed
  loop
    perform wallet_apply(
      p_user,
      v_m.reward,
      'mission',
      'mission:' || v_m.id,
      jsonb_build_object('mission_id', v_m.id)
    );
  end loop;
end;
$$;

revoke all on function ensure_daily_missions(uuid) from public, anon, authenticated;
revoke all on function progress_daily_missions(uuid, int, int, int, int, int, int, int)
  from public, anon, authenticated;
revoke all on function get_daily_missions() from public, anon, authenticated;
grant execute on function get_daily_missions() to authenticated;

-- ---------------------------------------------------------------------
-- 5. Réglages : chrono de réponse à 15 s et paiements test désactivés
--    (mise à jour compatible avec une colonne value de type jsonb,
--     numérique ou texte ; aucune ligne n'est créée ni supprimée)
-- ---------------------------------------------------------------------
do $$
declare
  v_key_col text;
  v_val_col text;
  v_type    text;
begin
  select column_name into v_key_col
  from information_schema.columns
  where table_schema = 'public' and table_name = 'game_config'
    and column_name in ('key', 'name', 'config_key', 'setting', 'code')
  order by array_position(array['key', 'name', 'config_key', 'setting', 'code'], column_name)
  limit 1;

  select column_name, data_type into v_val_col, v_type
  from information_schema.columns
  where table_schema = 'public' and table_name = 'game_config'
    and column_name <> v_key_col
    and column_name not in ('created_at', 'updated_at', 'description')
  order by
    case when column_name in ('value', 'val', 'setting_value', 'valeur') then 0 else 1 end,
    ordinal_position
  limit 1;

  if v_key_col is null or v_val_col is null then
    raise notice 'game_config introuvable : réglez answer_seconds = 15 et payments_test_mode = 0 manuellement.';
    return;
  end if;

  if v_type = 'jsonb' then
    execute format('update game_config set %I = to_jsonb(15) where %I = %L', v_val_col, v_key_col, 'answer_seconds');
    execute format('update game_config set %I = to_jsonb(0)  where %I = %L', v_val_col, v_key_col, 'payments_test_mode');
  elsif v_type in ('integer', 'bigint', 'smallint', 'numeric', 'real', 'double precision') then
    execute format('update game_config set %I = 15 where %I = %L', v_val_col, v_key_col, 'answer_seconds');
    execute format('update game_config set %I = 0  where %I = %L', v_val_col, v_key_col, 'payments_test_mode');
  else
    execute format('update game_config set %I = %L where %I = %L', v_val_col, v_key_col, '15', 'answer_seconds');
    execute format('update game_config set %I = %L where %I = %L', v_val_col, v_key_col, '0', 'payments_test_mode');
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Achats : fermeture côté serveur
--    `create_purchase` n'est plus exécutable par le navigateur, quelle
--    que soit sa signature. Pour rouvrir plus tard, voir la note en fin
--    de fichier.
-- ---------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'create_purchase'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    raise notice 'Achat fermé : % révoquée', r.sig;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Cache PostgREST + diagnostic
-- ---------------------------------------------------------------------
notify pgrst, 'reload schema';

select
  (select count(*) from mission_templates) as modeles_missions,
  (select count(*) from mission_templates where difficulty = 'facile') as faciles,
  (select count(*) from mission_templates where difficulty = 'moyenne') as moyennes,
  (select count(*) from mission_templates where difficulty in ('difficile','tres_difficile')) as difficiles,
  (select count(*)
     from auth.users u
     left join public.profiles p on p.id = u.id
    where p.id is null) as profils_manquants,
  get_public_config() as config_publique;

-- Signatures réellement installées : à transmettre si un correctif plus
-- profond est nécessaire (elles révèlent la version du moteur en place).
select p.oid::regprocedure as fonction
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'ensure_daily_missions', 'get_daily_missions', 'progress_daily_missions',
    'finalize_room', 'advance_room', 'wallet_apply', 'create_purchase'
  )
order by 1;

-- =====================================================================
-- DIAGNOSTIC DES RÉCOMPENSES DE PARTIE (à exécuter séparément si besoin)
-- Liste les 20 dernières parties terminées et vérifie que la récompense
-- figure bien dans le portefeuille.
-- =====================================================================
-- select r.code,
--        r.finished_at,
--        r.ended_by_forfeit,
--        rp.user_id,
--        rp.final_rank,
--        rp.reward,
--        coalesce((
--          select sum(wt.amount)
--          from wallet_transactions wt
--          where wt.user_id = rp.user_id and wt.type = 'reward'
--        ), 0) as total_recompenses_creditees
-- from rooms r
-- join room_players rp on rp.room_id = r.id
-- where r.phase = 'finished'
-- order by r.finished_at desc nulls last
-- limit 20;

-- =====================================================================
-- POUR ROUVRIR LA BOUTIQUE PLUS TARD
--   1. Brancher un webhook de paiement vérifié (Edge Function).
--   2. Passer payments_test_mode à 0 (déjà fait ici) et ne jamais le
--      remettre à 1 en production.
--   3. Redonner l'autorisation d'exécution :
--        grant execute on function create_purchase(int) to authenticated;
--      (adapte la signature exacte : \df public.create_purchase)
--   4. Passer PURCHASES_ENABLED à true dans js/config.js.
-- =====================================================================
