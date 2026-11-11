-- =====================================================================
-- CAPITAL CHALLENGE — 05_missions.sql
-- Missions quotidiennes : catalogue, tables, moteur et versement.
-- Autonome et ré-exécutable : crée ce qui manque, ne supprime rien.
-- À exécuter après 04_moteur.sql.
-- =====================================================================

create table if not exists mission_templates (
  id          smallint generated always as identity primary key,
  code        text not null unique,
  title       text not null,
  description text not null,
  difficulty  text not null check (difficulty in ('facile','moyenne','difficile','tres_difficile')),
  metric      text not null check (metric in
                ('games_finished','capitals_found','perfect_answers','answers_total',
                 'proposals','games_won','podiums')),
  target_min  int not null,
  target_max  int not null,
  reward      int not null
);

create table if not exists user_missions (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references profiles(id) on delete cascade,
  mission_date date not null,
  template_id  smallint not null references mission_templates(id),
  target       int not null,
  progress     int not null default 0,
  completed    boolean not null default false,
  completed_at timestamptz,
  unique (user_id, mission_date, template_id)
);

create index if not exists user_missions_user_date_idx
  on user_missions (user_id, mission_date);

alter table mission_templates enable row level security;
alter table user_missions     enable row level security;

drop policy if exists mission_templates_select on mission_templates;
create policy mission_templates_select on mission_templates
  for select to authenticated using (true);

drop policy if exists user_missions_select on user_missions;
create policy user_missions_select on user_missions
  for select to authenticated using (user_id = auth.uid());

revoke all on table mission_templates, user_missions from anon;
grant select on table mission_templates, user_missions to authenticated;

-- ---------------------------------------------------------------------
-- Catalogue : 4 faciles, 4 moyennes, 2 difficiles, 2 très difficiles
-- ---------------------------------------------------------------------
do $$
begin
  insert into mission_templates (code, title, description, difficulty, metric, target_min, target_max, reward) values
    ('easy_game',    'Première partie',      'Terminer une partie.',             'facile',        'games_finished', 1, 1, 25),
    ('easy_find',    'Chasse aux capitales', 'Trouver 2 capitales.',             'facile',        'capitals_found', 2, 2, 25),
    ('easy_answer',  'Entrée en jeu',        'Répondre à 3 défis.',              'facile',        'answers_total',  3, 3, 25),
    ('easy_propose', 'Prends les commandes', 'Proposer 1 pays.',                 'facile',        'proposals',      1, 1, 25),
    ('med_games',    'Habitué des salles',   'Terminer 2 parties.',              'moyenne',       'games_finished', 2, 2, 50),
    ('med_find',     'Explorateur',          'Trouver 5 capitales.',             'moyenne',       'capitals_found', 5, 5, 50),
    ('med_answers',  'Joueur actif',         'Répondre à 8 défis.',              'moyenne',       'answers_total',  8, 8, 50),
    ('med_perfect',  'Sans faute',           'Donner 3 réponses parfaites.',     'moyenne',       'perfect_answers',3, 3, 50),
    ('hard_games',   'Marathonien',          'Terminer 3 parties.',              'difficile',     'games_finished', 3, 3, 75),
    ('hard_find',    'Cartographe',          'Trouver 10 capitales.',            'difficile',     'capitals_found',10,10, 75),
    ('vhard_wins',   'Invaincu',             'Gagner 2 parties.',                'tres_difficile','games_won',      2, 2,100),
    ('vhard_perfect','Mémoire infaillible',  'Donner 8 réponses parfaites.',     'tres_difficile','perfect_answers',8, 8,100)
  on conflict (code) do nothing;
exception when others then
  raise notice 'Catalogue de missions non inséré : %', sqlerrm;
end;
$$;

-- ---------------------------------------------------------------------
-- Génération : 3 missions par jour et par joueur (une par difficulté)
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

  if v_have >= 3 then return; end if;

  if not exists (select 1 from mission_templates) then
    raise exception 'Catalogue de missions vide : exécutez 05_missions.sql';
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

-- Progression appelée par le moteur à la fin de chaque partie normale.
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

-- Rattrapage : profil absent -> missions impossibles.
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
      raise notice 'Profil % non créé : %', r.id, sqlerrm;
    end;
  end loop;
end;
$$;

revoke all on function ensure_daily_missions(uuid) from public, anon, authenticated;
revoke all on function progress_daily_missions(uuid, int, int, int, int, int, int, int)
  from public, anon, authenticated;
revoke all on function get_daily_missions() from public, anon, authenticated;

grant execute on function get_daily_missions() to authenticated;

notify pgrst, 'reload schema';

select
  (select count(*) from mission_templates) as modeles_missions,
  (select count(*) from mission_templates where difficulty = 'facile') as faciles,
  (select count(*) from mission_templates where difficulty = 'moyenne') as moyennes,
  (select count(*) from mission_templates where difficulty in ('difficile','tres_difficile')) as difficiles;
