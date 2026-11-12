select 'Correctif 13 — identifiants de manche (uuid)' as etape;

-- =====================================================================
-- CAPITAL CHALLENGE — 13_manches_uuid.sql
--
-- Cause racine définitive :
--   column "round_id" is of type uuid but expression is of type bigint
--
-- Dans cette base, la table `rounds` vient d'une ancienne version :
--   rounds.id                bigint   (au lieu de uuid)
--   answers.round_id         bigint   (au lieu de uuid)
--   round_secrets.round_id   bigint   (au lieu de uuid)
--
-- Or submit_pick(), submit_answer(), cc_finalize_round(uuid) et
-- answer_progress() travaillent avec des identifiants uuid. Résultat :
-- aucune manche ne peut être enregistrée, donc aucune partie ne peut
-- aller au bout.
--
-- Ce fichier :
--   • sauvegarde rounds / answers / round_secrets ;
--   • ferme les parties en cours et rembourse la mise ;
--   • reconstruit les 3 tables à l'identique du schéma officiel (uuid) ;
--   • reconstruit les politiques RLS et les droits.
--
-- Ré-exécutable : si tout est déjà en uuid, le script ne fait RIEN
-- (aucune donnée de partie en cours n'est supprimée).
-- =====================================================================

do $$
declare
  v_rounds   text;
  v_answers  text;
  v_secrets  text;
  v_room     record;
  v_player   record;
  v_fermees  int := 0;
  v_remb     int := 0;
  v_s        text := to_char(now(), 'YYYYMMDD_HH24MISS');
begin
  -- -------------------------------------------------------------------
  -- 0. Types actuels
  -- -------------------------------------------------------------------
  if to_regclass('public.rounds') is not null then
    select format_type(a.atttypid, a.atttypmod) into v_rounds
    from pg_attribute a
    where a.attrelid = to_regclass('public.rounds')
      and a.attname = 'id' and not a.attisdropped;
  end if;

  if to_regclass('public.answers') is not null then
    select format_type(a.atttypid, a.atttypmod) into v_answers
    from pg_attribute a
    where a.attrelid = to_regclass('public.answers')
      and a.attname = 'round_id' and not a.attisdropped;
  end if;

  if to_regclass('public.round_secrets') is not null then
    select format_type(a.atttypid, a.atttypmod) into v_secrets
    from pg_attribute a
    where a.attrelid = to_regclass('public.round_secrets')
      and a.attname = 'round_id' and not a.attisdropped;
  end if;

  raise notice 'Types actuels : rounds.id = %, answers.round_id = %, round_secrets.round_id = %',
    coalesce(v_rounds, 'absente'), coalesce(v_answers, 'absente'), coalesce(v_secrets, 'absente');

  if v_rounds = 'uuid' and v_answers = 'uuid' and v_secrets = 'uuid' then
    raise notice 'Rien à corriger : les identifiants de manche sont déjà en uuid.';
    return;
  end if;

  -- -------------------------------------------------------------------
  -- 1. Sauvegardes
  -- -------------------------------------------------------------------
  begin
    execute format(
      'create table if not exists public.%I as select * from public.rounds',
      'zz_rounds_backup_' || v_s);
    raise notice 'Sauvegarde : %', 'zz_rounds_backup_' || v_s;
  exception when others then
    raise notice 'Sauvegarde rounds impossible : %', sqlerrm;
  end;

  begin
    execute format(
      'create table if not exists public.%I as select * from public.answers',
      'zz_answers_backup_' || v_s);
    raise notice 'Sauvegarde : %', 'zz_answers_backup_' || v_s;
  exception when others then
    raise notice 'Sauvegarde answers impossible : %', sqlerrm;
  end;

  begin
    execute format(
      'create table if not exists public.%I as select * from public.round_secrets',
      'zz_round_secrets_backup_' || v_s);
    raise notice 'Sauvegarde : %', 'zz_round_secrets_backup_' || v_s;
  exception when others then
    raise notice 'Sauvegarde round_secrets impossible : %', sqlerrm;
  end;

  -- -------------------------------------------------------------------
  -- 2. Fermeture des parties en cours + remboursement de la mise
  --    (les manches vont être reconstruites : on ne laisse pas de salle
  --    bloquée derrière)
  -- -------------------------------------------------------------------
  for v_room in
    select * from public.rooms
    where phase in ('picking','answering','revealing')
    for update
  loop
    if v_room.started_at is not null then
      for v_player in
        select user_id from public.room_players where room_id = v_room.id
      loop
        perform public.wallet_apply(
          v_player.user_id,
          v_room.entry_fee,
          'refund',
          'refund:' || v_room.id::text || ':' || v_player.user_id::text,
          jsonb_build_object('room_id', v_room.id, 'reason', 'rounds_rebuild'));
        v_remb := v_remb + 1;
      end loop;
    end if;

    update public.room_players
       set is_forfeit = true, is_ready = false
     where room_id = v_room.id;

    update public.rooms
       set phase = 'cancelled',
           finished_at = coalesce(finished_at, now()),
           updated_at = now()
     where id = v_room.id;

    v_fermees := v_fermees + 1;
  end loop;

  raise notice 'Salles fermées : % — remboursements : %', v_fermees, v_remb;

  -- -------------------------------------------------------------------
  -- 3. Reconstruction des tables de manche (structure officielle)
  -- -------------------------------------------------------------------
  drop table if exists public.round_secrets cascade;
  drop table if exists public.answers cascade;
  drop table if exists public.rounds cascade;

  create table public.rounds (
    id               uuid primary key default gen_random_uuid(),
    room_id          uuid not null references public.rooms(id) on delete cascade,
    round_no         int not null,
    proposer_id      uuid not null references public.profiles(id) on delete cascade,
    country_id       smallint references public.countries(id),
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

  create table public.round_secrets (
    round_id   uuid primary key references public.rounds(id) on delete cascade,
    secret     text not null,
    created_at timestamptz not null default now()
  );

  create table public.answers (
    id             bigint generated always as identity primary key,
    round_id       uuid not null references public.rounds(id) on delete cascade,
    user_id        uuid not null references public.profiles(id) on delete cascade,
    text           text not null,
    grade          text,
    points         numeric(4,1) not null default 0,
    joker_consumed boolean not null default false,
    elapsed_ms     int,
    created_at     timestamptz not null default now(),
    unique (round_id, user_id)
  );

  create index if not exists rounds_room_idx     on public.rounds (room_id, round_no);
  create index if not exists answers_round_idx   on public.answers (round_id);

  -- -------------------------------------------------------------------
  -- 4. Sécurité : RLS + politiques + droits
  -- -------------------------------------------------------------------
  alter table public.rounds        enable row level security;
  alter table public.round_secrets enable row level security;
  alter table public.answers       enable row level security;

  drop policy if exists rounds_select on public.rounds;
  create policy rounds_select on public.rounds
    for select to authenticated using (public.is_room_member(room_id));

  drop policy if exists answers_select on public.answers;
  create policy answers_select on public.answers
    for select to authenticated using (
      exists (
        select 1 from public.rounds r
        where r.id = answers.round_id
          and public.is_room_member(r.room_id)
          and r.status = 'revealed'
      )
    );

  -- round_secrets : AUCUNE politique de lecture (capitale invisible).

  revoke all on table public.rounds, public.answers, public.round_secrets
    from public, anon, authenticated;
  grant select on table public.rounds, public.answers to authenticated;
end;
$$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 5. Contrôle final
-- ---------------------------------------------------------------------
select
  (select format_type(a.atttypid, a.atttypmod)
     from pg_attribute a
    where a.attrelid = 'public.rounds'::regclass
      and a.attname = 'id' and not a.attisdropped)                    as type_rounds_id,
  (select format_type(a.atttypid, a.atttypmod)
     from pg_attribute a
    where a.attrelid = 'public.answers'::regclass
      and a.attname = 'round_id' and not a.attisdropped)              as type_answers_round_id,
  (select format_type(a.atttypid, a.atttypmod)
     from pg_attribute a
    where a.attrelid = 'public.round_secrets'::regclass
      and a.attname = 'round_id' and not a.attisdropped)              as type_secrets_round_id,
  (select count(*) from public.rounds)                                as manches,
  (select count(*) from public.answers)                               as reponses,
  (select count(*) from public.rooms
    where phase in ('waiting','picking','answering','revealing'))     as salles_actives,
  (select count(*) from public.wallet_transactions where type = 'refund') as remboursements;
