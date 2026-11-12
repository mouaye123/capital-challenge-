select 'Correctif 12 — table round_secrets' as etape;

-- =====================================================================
-- CAPITAL CHALLENGE — 12_round_secrets.sql
--
-- Cause racine du blocage « Lancer le défi » :
--   Erreur : column "secret" of relation "round_secrets" does not exist
--
-- La table `round_secrets` existait déjà dans une ancienne version, avec
-- une autre structure. `create table if not exists` (01_schema.sql) ne
-- l'a donc pas recréée : la colonne `secret` n'a jamais été ajoutée.
--
-- Conséquence en cascade :
--   • submit_pick() échoue → le choix du pays n'est jamais enregistré ;
--   • le tirage automatique de secours échoue aussi (même insertion) ;
--   • la salle reste bloquée en phase « choix du pays » ;
--   • une salle bloquée empêche ensuite de créer une nouvelle salle.
--
-- Ce fichier sauvegarde l'ancienne table puis la reconstruit à
-- l'identique de ce qu'attend le moteur. Ré-exécutable.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Sauvegarde de l'ancienne table (quel que soit son contenu)
-- ---------------------------------------------------------------------
do $$
declare
  v_s text := to_char(now(), 'YYYYMMDD_HH24MISS');
begin
  if to_regclass('public.round_secrets') is not null then
    begin
      execute format(
        'create table if not exists public.%I as select * from public.round_secrets',
        'zz_round_secrets_backup_' || v_s
      );
      raise notice 'Ancienne table sauvegardée : %', 'zz_round_secrets_backup_' || v_s;
    exception when others then
      raise notice 'Sauvegarde de round_secrets impossible : %', sqlerrm;
    end;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Reconstruction avec la structure attendue par le moteur
--    (round_id en clé primaire : indispensable au ON CONFLICT du moteur)
-- ---------------------------------------------------------------------
drop table if exists public.round_secrets cascade;

do $$
begin
  begin
    create table public.round_secrets (
      round_id   uuid primary key references public.rounds(id) on delete cascade,
      secret     text not null,
      created_at timestamptz not null default now()
    );
  exception when others then
    raise notice 'Clé étrangère impossible (%), création sans clé étrangère', sqlerrm;
    create table public.round_secrets (
      round_id   uuid primary key,
      secret     text not null,
      created_at timestamptz not null default now()
    );
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Sécurité : aucune lecture possible depuis le site.
--    Seul le moteur (SECURITY DEFINER) lit la capitale secrète.
-- ---------------------------------------------------------------------
alter table public.round_secrets enable row level security;
revoke all on table public.round_secrets from public, anon, authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 4. Contrôle : colonnes de round_secrets + audit des autres tables
-- ---------------------------------------------------------------------
select
  (select string_agg(column_name, ', ' order by ordinal_position)
     from information_schema.columns
    where table_schema = 'public' and table_name = 'round_secrets')        as colonnes_round_secrets,
  (select count(*) from pg_indexes
    where schemaname = 'public' and tablename = 'round_secrets')           as index_round_secrets,
  (select coalesce(jsonb_agg(e.tbl || '.' || e.col order by e.tbl, e.col), '[]'::jsonb)
     from (values
       ('rooms','id'), ('rooms','code'), ('rooms','host_id'), ('rooms','phase'),
       ('rooms','target_rounds'), ('rooms','total_rounds'), ('rooms','current_round'),
       ('rooms','max_players'), ('rooms','entry_fee'), ('rooms','tiebreak_blocks'),
       ('rooms','ended_by_forfeit'), ('rooms','created_at'), ('rooms','started_at'),
       ('rooms','finished_at'), ('rooms','expires_at'), ('rooms','phase_ends_at'),
       ('rooms','updated_at'),
       ('room_players','room_id'), ('room_players','user_id'), ('room_players','seat'),
       ('room_players','score'), ('room_players','is_ready'), ('room_players','is_forfeit'),
       ('room_players','joker_used'), ('room_players','missed_turns'),
       ('room_players','final_rank'), ('room_players','reward'), ('room_players','last_seen_at'),
       ('room_players','joined_at'),
       ('rounds','id'), ('rounds','room_id'), ('rounds','round_no'), ('rounds','proposer_id'),
       ('rounds','country_id'), ('rounds','status'), ('rounds','auto_picked'), ('rounds','found'),
       ('rounds','correct_names'), ('rounds','reveal_note'), ('rounds','pick_ends_at'),
       ('rounds','answer_ends_at'), ('rounds','picked_at'), ('rounds','revealed_at'),
       ('answers','id'), ('answers','round_id'), ('answers','user_id'), ('answers','text'),
       ('answers','grade'), ('answers','points'), ('answers','joker_consumed'), ('answers','elapsed_ms'),
       ('countries','id'), ('countries','iso2'), ('countries','name_fr'),
       ('countries','name_en'), ('countries','capital_fr'), ('countries','note_fr'),
       ('profiles','id'), ('profiles','username'),
       ('wallets','user_id'), ('wallets','balance'), ('wallets','last_daily_bonus_on'),
       ('wallet_transactions','user_id'), ('wallet_transactions','amount'),
       ('wallet_transactions','type'), ('wallet_transactions','ref'),
       ('player_stats','user_id'), ('player_stats','games_played'),
       ('player_stats','capitals_found'), ('player_stats','answers_total'),
       ('game_config','key'), ('game_config','value')
     ) as e(tbl, col)
    where not exists (
      select 1 from information_schema.columns c
      where c.table_schema = 'public' and c.table_name = e.tbl and c.column_name = e.col
    ))                                                                    as colonnes_manquantes;
