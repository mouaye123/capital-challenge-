-- =====================================================================
-- CAPITAL CHALLENGE — 08_missions_fix.sql
-- Réparation complète des missions quotidiennes.
--
-- À exécuter APRÈS 05_missions.sql (et après 07_correctif.sql).
-- Ce fichier est autonome, ré-exécutable, et conçu pour une base créée
-- par une ancienne version dont les tables `mission_templates` /
-- `user_missions` ont une structure différente.
--
-- Ce qu'il fait :
--   1. vérifie la structure réelle des deux tables de missions ;
--   2. si elle est incompatible, sauvegarde les anciennes tables
--      (`*_backup_...`) puis les reconstruit proprement ;
--   3. ajoute les colonnes manquantes, assouplit les contraintes ;
--   4. réinstalle le catalogue des 12 modèles (4/4/2/2) ;
--   5. recrée le moteur (ensure / get / progress) ;
--   6. répare les profils manquants ;
--   7. TESTE RÉELLEMENT la génération pour de vrais comptes et affiche
--      le résultat dans le tableau final.
--
-- Aucune donnée de jeu n'est supprimée : les anciennes tables de
-- missions sont archivées avant reconstruction.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Journal de diagnostic (table temporaire de session)
-- ---------------------------------------------------------------------
drop table if exists _cc_mission_diag;

create temp table _cc_mission_diag (
  k text,
  v text
);

-- ---------------------------------------------------------------------
-- 1. Les tables existantes sont-elles compatibles avec le moteur ?
--    On contrôle à la fois la présence ET le type des colonnes.
-- ---------------------------------------------------------------------
do $$
declare
  r          record;
  v_type     text;
  v_probleme text := '';
  v_suffix   text := to_char(now(), 'YYYYMMDD_HH24MISS');
begin
  for r in
    select * from (values
      ('mission_templates', 'id',            'smallint,integer,bigint,numeric'),
      ('mission_templates', 'code',          'text,character varying,character'),
      ('mission_templates', 'title',         'text,character varying,character'),
      ('mission_templates', 'description',   'text,character varying,character'),
      ('mission_templates', 'difficulty',    'text,character varying,character'),
      ('mission_templates', 'metric',        'text,character varying,character'),
      ('mission_templates', 'target_min',    'smallint,integer,bigint,numeric'),
      ('mission_templates', 'target_max',    'smallint,integer,bigint,numeric'),
      ('mission_templates', 'reward',        'smallint,integer,bigint,numeric'),
      ('user_missions',     'id',            'smallint,integer,bigint,numeric'),
      ('user_missions',     'user_id',       'uuid'),
      ('user_missions',     'mission_date',  'date'),
      ('user_missions',     'template_id',   'smallint,integer,bigint,numeric'),
      ('user_missions',     'target',        'smallint,integer,bigint,numeric'),
      ('user_missions',     'progress',      'smallint,integer,bigint,numeric'),
      ('user_missions',     'completed',     'boolean'),
      ('user_missions',     'completed_at',  'timestamp with time zone,timestamp without time zone')
    ) as v(tbl, col, types)
  loop
    if to_regclass('public.' || r.tbl) is null then
      continue;
    end if;

    select c.data_type into v_type
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = r.tbl
      and c.column_name = r.col;

    if v_type is null then
      v_probleme := v_probleme || ' ' || r.tbl || '.' || r.col || '(absent)';
    elsif not (v_type = any (string_to_array(r.types, ','))) then
      v_probleme := v_probleme || ' ' || r.tbl || '.' || r.col || '(' || v_type || ')';
    end if;
  end loop;

  if v_probleme <> '' then
    insert into _cc_mission_diag values ('structure', 'incompatible :' || v_probleme);

    -- Archive (si possible) puis reconstruction.
    if to_regclass('public.user_missions') is not null then
      begin
        execute format(
          'create table if not exists public.%I as select * from public.user_missions',
          'user_missions_backup_' || v_suffix
        );
        insert into _cc_mission_diag values
          ('sauvegarde_user_missions', 'user_missions_backup_' || v_suffix);
      exception when others then
        insert into _cc_mission_diag values ('sauvegarde_user_missions', 'échec : ' || sqlerrm);
      end;
    end if;

    if to_regclass('public.mission_templates') is not null then
      begin
        execute format(
          'create table if not exists public.%I as select * from public.mission_templates',
          'mission_templates_backup_' || v_suffix
        );
        insert into _cc_mission_diag values
          ('sauvegarde_mission_templates', 'mission_templates_backup_' || v_suffix);
      exception when others then
        insert into _cc_mission_diag values ('sauvegarde_mission_templates', 'échec : ' || sqlerrm);
      end;
    end if;

    execute 'drop table if exists public.user_missions cascade';
    execute 'drop table if exists public.mission_templates cascade';

    insert into _cc_mission_diag values ('reconstruction', 'tables missions recréées');
  else
    if to_regclass('public.mission_templates') is null
       or to_regclass('public.user_missions') is null then
      insert into _cc_mission_diag values ('structure', 'tables absentes : création');
    else
      insert into _cc_mission_diag values ('structure', 'compatible');
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Création des tables (no-op si déjà présentes et compatibles)
-- ---------------------------------------------------------------------
create table if not exists mission_templates (
  id          smallint generated always as identity primary key,
  code        text not null,
  title       text not null,
  description text not null,
  difficulty  text not null,
  metric      text not null,
  target_min  int not null,
  target_max  int not null,
  reward      int not null
);

create table if not exists user_missions (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  mission_date date not null,
  template_id  smallint not null references public.mission_templates(id),
  target       int not null,
  progress     int not null default 0,
  completed    boolean not null default false,
  completed_at timestamptz
);

-- Colonnes manquantes sur une table finalement conservée.
alter table mission_templates add column if not exists code        text;
alter table mission_templates add column if not exists title       text;
alter table mission_templates add column if not exists description text;
alter table mission_templates add column if not exists difficulty  text;
alter table mission_templates add column if not exists metric      text;
alter table mission_templates add column if not exists target_min  int;
alter table mission_templates add column if not exists target_max  int;
alter table mission_templates add column if not exists reward      int;

alter table user_missions add column if not exists user_id      uuid;
alter table user_missions add column if not exists mission_date date;
alter table user_missions add column if not exists template_id  smallint;
alter table user_missions add column if not exists target       int;
alter table user_missions add column if not exists progress     int default 0;
alter table user_missions add column if not exists completed    boolean default false;
alter table user_missions add column if not exists completed_at timestamptz;

-- Valeurs par défaut utilisées par le moteur.
alter table user_missions alter column progress  set default 0;
alter table user_missions alter column completed set default false;

-- Si la colonne `id` d'une ancienne table n'a ni identité ni serial, les
-- INSERT du moteur échoueraient. On la rend auto-générée.
do $$
declare
  r       record;
  v_ident text;
  v_def   text;
begin
  for r in
    select * from (values ('mission_templates'), ('user_missions')) as v(tbl)
  loop
    select c.is_identity, c.column_default
      into v_ident, v_def
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = r.tbl
      and c.column_name = 'id';

    if coalesce(v_ident, 'NO') <> 'YES' and v_def is null then
      begin
        execute format('alter table public.%I alter column id set not null', r.tbl);
        execute format(
          'alter table public.%I alter column id add generated by default as identity',
          r.tbl
        );
        execute format(
          'select setval(pg_get_serial_sequence(%L, %L), coalesce(max(id), 0) + 1, false) from public.%I',
          'public.' || r.tbl, 'id', r.tbl
        );
        insert into _cc_mission_diag values ('identite_' || r.tbl, 'ajoutée');
      exception when others then
        insert into _cc_mission_diag values ('identite_' || r.tbl, 'échec : ' || sqlerrm);
      end;
    end if;
  end loop;
end;
$$;

-- Colonnes héritées d'une ancienne version, obligatoires mais jamais
-- remplies par le moteur : on retire leur NOT NULL.
do $$
declare
  r record;
begin
  for r in
    select c.table_name, c.column_name
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name in ('mission_templates', 'user_missions')
      and c.is_nullable = 'NO'
      and c.column_default is null
      and not (
        (c.table_name = 'mission_templates' and c.column_name = any (array[
          'id','code','title','description','difficulty','metric',
          'target_min','target_max','reward']))
        or
        (c.table_name = 'user_missions' and c.column_name = any (array[
          'id','user_id','mission_date','template_id','target',
          'progress','completed','completed_at']))
      )
  loop
    begin
      execute format('alter table public.%I alter column %I drop not null',
                     r.table_name, r.column_name);
    exception when others then
      raise notice 'NOT NULL conservé sur %.% : %', r.table_name, r.column_name, sqlerrm;
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Contraintes : on retire les CHECK hérités (valeurs anglaises ou
--    incomplètes) et on installe les nôtres, sans valider l'historique.
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
        'public.mission_templates'::regclass,
        'public.user_missions'::regclass
      )
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
  end loop;
end;
$$;

alter table mission_templates add constraint mission_templates_difficulty_check
  check (difficulty in ('facile','moyenne','difficile','tres_difficile','archive'))
  not valid;

alter table mission_templates add constraint mission_templates_metric_check
  check (metric in ('games_finished','capitals_found','perfect_answers',
                    'answers_total','proposals','games_won','podiums'))
  not valid;

-- ---------------------------------------------------------------------
-- 4. Unicité (nécessaire aux `on conflict`)
-- ---------------------------------------------------------------------
do $$
begin
  begin
    delete from mission_templates a
    using mission_templates b
    where a.code = b.code
      and a.ctid < b.ctid;
  exception when others then
    raise notice 'Doublons de modèles non nettoyés : %', sqlerrm;
  end;

  begin
    delete from user_missions a
    using user_missions b
    where a.user_id = b.user_id
      and a.mission_date = b.mission_date
      and a.template_id = b.template_id
      and a.ctid < b.ctid;
  exception when others then
    raise notice 'Doublons de missions non nettoyés : %', sqlerrm;
  end;

  begin
    create unique index if not exists mission_templates_code_key
      on public.mission_templates (code);
  exception when others then
    raise notice 'Index unique des modèles non créé : %', sqlerrm;
  end;

  begin
    create unique index if not exists user_missions_unique_idx
      on public.user_missions (user_id, mission_date, template_id);
  exception when others then
    raise notice 'Index unique des missions non créé : %', sqlerrm;
  end;

  begin
    create index if not exists user_missions_user_date_idx
      on public.user_missions (user_id, mission_date);
  exception when others then
    raise notice 'Index missions non créé : %', sqlerrm;
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Catalogue officiel : 4 faciles, 4 moyennes, 2 difficiles,
--    2 très difficiles. `do update` corrige d'anciennes lignes.
-- ---------------------------------------------------------------------
do $$
begin
  insert into mission_templates (code, title, description, difficulty, metric, target_min, target_max, reward) values
    ('easy_game',    'Première partie',       'Terminer une partie.',              'facile',        'games_finished',  1,  1,  25),
    ('easy_find',    'Chasse aux capitales',  'Trouver 2 capitales.',              'facile',        'capitals_found',  2,  2,  25),
    ('easy_answer',  'Entrée en jeu',         'Répondre à 3 défis.',               'facile',        'answers_total',   3,  3,  25),
    ('easy_propose', 'Prends les commandes',  'Proposer 1 pays.',                  'facile',        'proposals',       1,  1,  25),
    ('med_games',    'Habitué des salles',    'Terminer 2 parties.',               'moyenne',       'games_finished',  2,  2,  50),
    ('med_find',     'Explorateur',           'Trouver 5 capitales.',              'moyenne',       'capitals_found',  5,  5,  50),
    ('med_answers',  'Joueur actif',          'Répondre à 8 défis.',               'moyenne',       'answers_total',   8,  8,  50),
    ('med_perfect',  'Sans faute',            'Donner 3 réponses parfaites.',      'moyenne',       'perfect_answers', 3,  3,  50),
    ('hard_games',   'Marathonien',           'Terminer 3 parties.',               'difficile',     'games_finished',  3,  3,  75),
    ('hard_find',    'Cartographe',           'Trouver 10 capitales.',             'difficile',     'capitals_found', 10, 10,  75),
    ('vhard_wins',   'Invaincu',              'Gagner 2 parties.',                 'tres_difficile','games_won',       2,  2, 100),
    ('vhard_perfect','Mémoire infaillible',   'Donner 8 réponses parfaites.',      'tres_difficile','perfect_answers', 8,  8, 100)
  on conflict (code) do update set
    title       = excluded.title,
    description = excluded.description,
    difficulty  = excluded.difficulty,
    metric      = excluded.metric,
    target_min  = excluded.target_min,
    target_max  = excluded.target_max,
    reward      = excluded.reward;

  -- Anciens modèles d'une autre version : neutralisés sans casser les
  -- clés étrangères des missions déjà générées.
  update mission_templates
     set difficulty = 'archive'
   where code is null
      or code not in (
     'easy_game','easy_find','easy_answer','easy_propose',
     'med_games','med_find','med_answers','med_perfect',
     'hard_games','hard_find','vhard_wins','vhard_perfect'
   );
exception when others then
  insert into _cc_mission_diag values ('catalogue', 'échec : ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Sécurité des tables de missions
-- ---------------------------------------------------------------------
alter table mission_templates enable row level security;
alter table user_missions     enable row level security;

drop policy if exists mission_templates_select on mission_templates;
create policy mission_templates_select on mission_templates
  for select to authenticated using (true);

drop policy if exists user_missions_select on user_missions;
create policy user_missions_select on user_missions
  for select to authenticated using (user_id = auth.uid());

revoke all on table mission_templates, user_missions from anon, authenticated;
grant select on table mission_templates, user_missions to authenticated;

-- ---------------------------------------------------------------------
-- 7. Moteur : on supprime d'abord pour éviter tout conflit de signature.
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
        'ensure_daily_missions', 'get_daily_missions', 'progress_daily_missions'
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
  if p_user is null then
    raise exception 'Utilisateur inconnu';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('missions:' || p_user::text || ':' || v_today::text, 0)
  );

  select count(*) into v_have
  from user_missions
  where user_id = p_user and mission_date = v_today;

  if v_have >= 3 then return; end if;

  if not exists (select 1 from mission_templates
                 where difficulty in ('facile','moyenne','difficile','tres_difficile')) then
    raise exception 'Catalogue de missions vide : exécutez 08_missions_fix.sql';
  end if;

  if not exists (select 1 from profiles where id = p_user) then
    raise exception 'Profil joueur introuvable (%) : reconnectez-vous', p_user;
  end if;

  insert into user_missions (user_id, mission_date, template_id, target)
  select p_user, v_today, t.id,
         t.target_min + floor(random() * (t.target_max - t.target_min + 1))::int
  from mission_templates t
  where t.difficulty = 'facile'
    and not exists (
      select 1 from user_missions um
      join mission_templates mt on mt.id = um.template_id
      where um.user_id = p_user and um.mission_date = v_today
        and mt.difficulty = 'facile'
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
      where um.user_id = p_user and um.mission_date = v_today
        and mt.difficulty = 'moyenne'
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
-- 8. Profils manquants (un compte sans profil ne peut pas avoir de
--    missions : la clé étrangère user_missions.user_id → profiles.id).
-- ---------------------------------------------------------------------
do $$
declare
  r          record;
  v_username text;
  v_n        int := 0;
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
      v_n := v_n + 1;
    exception when others then
      insert into _cc_mission_diag values ('profil_' || r.id::text, 'échec : ' || sqlerrm);
    end;
  end loop;
  insert into _cc_mission_diag values ('profils_crees', v_n::text);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. TEST RÉEL : on génère les missions de vrais comptes et on capture
--    la moindre erreur. C'est ce test qui révèle la cause exacte si la
--    page reste vide.
-- ---------------------------------------------------------------------
do $$
declare
  r           record;
  v_today     date := (now() at time zone 'utc')::date;
  v_ok        int := 0;
  v_ko        int := 0;
  v_premiere  text;
  v_cnt       int;
  v_nul       int;
begin
  if not exists (select 1 from public.profiles) then
    insert into _cc_mission_diag values ('test', 'aucun compte : inscrivez-vous puis relancez ce test');
    return;
  end if;

  for r in
    select id from public.profiles order by created_at nulls last limit 50
  loop
    begin
      perform public.ensure_daily_missions(r.id);

      select count(*) into v_cnt
      from public.user_missions
      where user_id = r.id and mission_date = v_today;

      select count(*) into v_nul
      from public.user_missions
      where user_id = r.id and mission_date = v_today
        and (target is null or target <= 0 or progress is null);

      if v_cnt >= 3 and v_nul = 0 then
        v_ok := v_ok + 1;
      else
        v_ko := v_ko + 1;
        v_premiere := coalesce(v_premiere,
          'compte ' || r.id || ' : ' || v_cnt || ' mission(s), ' || v_nul || ' ligne(s) invalide(s)');
      end if;
    exception when others then
      v_ko := v_ko + 1;
      v_premiere := coalesce(v_premiere, 'compte ' || r.id || ' : ' || sqlerrm);
    end;
  end loop;

  insert into _cc_mission_diag values ('comptes_testes_ok', v_ok::text);
  insert into _cc_mission_diag values ('comptes_en_echec', v_ko::text);
  insert into _cc_mission_diag values ('premiere_erreur', coalesce(v_premiere, 'aucune'));
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Rechargement du cache API + résultat complet
-- ---------------------------------------------------------------------
notify pgrst, 'reload schema';

select
  (select v from _cc_mission_diag where k = 'structure')              as structure,
  (select count(*) from mission_templates
    where difficulty = 'facile')                                      as faciles,
  (select count(*) from mission_templates
    where difficulty = 'moyenne')                                     as moyennes,
  (select count(*) from mission_templates
    where difficulty in ('difficile','tres_difficile'))                as difficiles,
  (select v from _cc_mission_diag where k = 'comptes_testes_ok')       as comptes_ok,
  (select v from _cc_mission_diag where k = 'comptes_en_echec')        as comptes_ko,
  (select count(*) from user_missions
    where mission_date = (now() at time zone 'utc')::date)             as missions_du_jour,
  (select v from _cc_mission_diag where k = 'premiere_erreur')         as premiere_erreur;

-- Détail brut : colonnes réellement présentes (utile si le problème persiste).
select
  (select string_agg(column_name, ', ' order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'mission_templates') as colonnes_modeles,
  (select string_agg(column_name, ', ' order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'user_missions')     as colonnes_missions;

-- Journal complet (sauvegardes, profils créés, erreurs éventuelles).
select k as etape, v as detail
from _cc_mission_diag
order by k;

drop table if exists _cc_mission_diag;
